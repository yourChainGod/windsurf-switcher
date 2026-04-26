//! 极简 protobuf wire-format 编解码
//!
//! 仅实现本工具用到的两种字段：
//!   - varint（wire type 0）
//!   - length-delimited（wire type 2）：string / bytes / embedded message
//!
//! 不依赖 protoc / prost，方便单文件维护。

#![allow(dead_code)]

use anyhow::{anyhow, Result};

/// 编码 varint（最大 64-bit）
pub fn encode_varint(mut value: u64, out: &mut Vec<u8>) {
    loop {
        let byte = (value & 0x7f) as u8;
        value >>= 7;
        if value == 0 {
            out.push(byte);
            return;
        }
        out.push(byte | 0x80);
    }
}

/// 解码 varint，返回 (值, 字节数)
pub fn decode_varint(buf: &[u8], offset: usize) -> Result<(u64, usize)> {
    let mut result: u64 = 0;
    let mut shift: u32 = 0;
    let mut pos = offset;
    while pos < buf.len() {
        let byte = buf[pos];
        pos += 1;
        result |= ((byte & 0x7f) as u64) << shift;
        if byte & 0x80 == 0 {
            return Ok((result, pos - offset));
        }
        shift += 7;
        if shift >= 64 {
            return Err(anyhow!("varint overflow"));
        }
    }
    Err(anyhow!("truncated varint at offset {}", offset))
}

/// 写入 tag（field_number << 3 | wire_type）
pub fn write_tag(field: u32, wire_type: u32, out: &mut Vec<u8>) {
    encode_varint(((field << 3) | (wire_type & 0x7)) as u64, out);
}

/// 写一个 string field（wire type 2）
pub fn write_string_field(field: u32, value: &str, out: &mut Vec<u8>) {
    write_tag(field, 2, out);
    encode_varint(value.len() as u64, out);
    out.extend_from_slice(value.as_bytes());
}

/// 写一个 bytes field（wire type 2）
pub fn write_bytes_field(field: u32, value: &[u8], out: &mut Vec<u8>) {
    write_tag(field, 2, out);
    encode_varint(value.len() as u64, out);
    out.extend_from_slice(value);
}

/// 写一个 embedded message field（wire type 2）
pub fn write_message_field(field: u32, msg: &[u8], out: &mut Vec<u8>) {
    write_tag(field, 2, out);
    encode_varint(msg.len() as u64, out);
    out.extend_from_slice(msg);
}

/// 写一个 varint field（wire type 0）
pub fn write_varint_field(field: u32, value: u64, out: &mut Vec<u8>) {
    write_tag(field, 0, out);
    encode_varint(value, out);
}

/// 解析后的字段
#[derive(Debug)]
pub enum FieldValue<'a> {
    Varint(u64),
    LenDelim(&'a [u8]),
    Fixed64(&'a [u8]),
    Fixed32(&'a [u8]),
}

#[derive(Debug)]
pub struct Field<'a> {
    pub number: u32,
    pub wire_type: u32,
    pub value: FieldValue<'a>,
}

/// 把整个 buffer 拆解成字段列表
pub fn parse_fields(buf: &[u8]) -> Result<Vec<Field<'_>>> {
    let mut fields = Vec::new();
    let mut pos = 0;
    while pos < buf.len() {
        let (tag, n) = decode_varint(buf, pos)?;
        pos += n;
        let field_num = (tag >> 3) as u32;
        let wire_type = (tag & 0x7) as u32;

        let value = match wire_type {
            0 => {
                let (v, n) = decode_varint(buf, pos)?;
                pos += n;
                FieldValue::Varint(v)
            }
            2 => {
                let (len, n) = decode_varint(buf, pos)?;
                pos += n;
                let len = len as usize;
                if pos + len > buf.len() {
                    return Err(anyhow!(
                        "truncated len-delim field {} at offset {}",
                        field_num,
                        pos
                    ));
                }
                let slice = &buf[pos..pos + len];
                pos += len;
                FieldValue::LenDelim(slice)
            }
            1 => {
                if pos + 8 > buf.len() {
                    return Err(anyhow!("truncated fixed64"));
                }
                let s = &buf[pos..pos + 8];
                pos += 8;
                FieldValue::Fixed64(s)
            }
            5 => {
                if pos + 4 > buf.len() {
                    return Err(anyhow!("truncated fixed32"));
                }
                let s = &buf[pos..pos + 4];
                pos += 4;
                FieldValue::Fixed32(s)
            }
            _ => return Err(anyhow!("unknown wire type {} at offset {}", wire_type, pos)),
        };

        fields.push(Field {
            number: field_num,
            wire_type,
            value,
        });
    }
    Ok(fields)
}

/// 取出第一个匹配的 string 字段
pub fn first_string<'a>(fields: &'a [Field<'a>], number: u32) -> Option<&'a str> {
    for f in fields {
        if f.number == number {
            if let FieldValue::LenDelim(s) = &f.value {
                return std::str::from_utf8(s).ok();
            }
        }
    }
    None
}

/// 取出第一个匹配的 bytes 字段
pub fn first_bytes<'a>(fields: &'a [Field<'a>], number: u32) -> Option<&'a [u8]> {
    for f in fields {
        if f.number == number {
            if let FieldValue::LenDelim(s) = &f.value {
                return Some(*s);
            }
        }
    }
    None
}

/// 取出第一个匹配的 varint 字段
pub fn first_varint(fields: &[Field<'_>], number: u32) -> Option<u64> {
    for f in fields {
        if f.number == number {
            if let FieldValue::Varint(v) = f.value {
                return Some(v);
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn varint_roundtrip() {
        for v in [0u64, 1, 127, 128, 189, 16383, 16384, 1 << 32] {
            let mut buf = Vec::new();
            encode_varint(v, &mut buf);
            let (decoded, n) = decode_varint(&buf, 0).unwrap();
            assert_eq!(decoded, v);
            assert_eq!(n, buf.len());
        }
    }

    #[test]
    fn string_field_matches_sample() {
        // 用户给的 GetOneTimeAuthToken 文件前 3 字节为 0a bd 01（field 1, length 189）
        let mut out = Vec::new();
        let payload = "x".repeat(189);
        write_string_field(1, &payload, &mut out);
        assert_eq!(out[0], 0x0a);
        assert_eq!(out[1], 0xbd);
        assert_eq!(out[2], 0x01);
        assert_eq!(out.len(), 3 + 189);
    }
}
