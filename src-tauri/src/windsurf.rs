//! Windsurf 后端 API 客户端
//!
//! 涉及两个调用：
//!   1. GetOneTimeAuthToken
//!      - POST https://windsurf.com/_backend/.../GetOneTimeAuthToken
//!      - Content-Type: application/proto
//!      - Body: 手搓 protobuf，field 1 string = "devin-session-token$<JWT>"
//!      - 用 devin-session-token 作 cookie 认证（实际请求体里也带了一份，
//!        与抓包样本保持一致即可）
//!      - Response：protobuf，field 1 = OTT 字符串
//!
//!   2. GetPlanStatus（用量信息，protobuf）
//!      - POST https://web-backend.windsurf.com/.../GetPlanStatus
//!      - Content-Type: application/proto + connect-protocol-version: 1
//!      - Body: protobuf field 1 string = "devin-session-token$<JWT>"
//!      - Header 鉴权：x-auth-token + x-devin-session-token，值同 body 里的前缀串
//!      - Response：protobuf 嵌套消息（PlanStatus { PlanInfo info=1, Timestamp end=3,
//!        used_flow=5, used_prompt=6, used_flex=7, avail_prompt=8, avail_flow=9 }）

use anyhow::{anyhow, bail, Context, Result};
use base64::Engine;
use reqwest::Client;
use serde::{Deserialize, Serialize};
use std::time::Duration;

use crate::proto;

const UA: &str = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/147.0.0.0 Safari/537.36";
const BASE: &str = "https://windsurf.com/_backend";
/// GetPlanStatus 走的是直连子域，不是 windsurf.com 反代
const BASE_API: &str = "https://web-backend.windsurf.com";
const COOKIE_NAME: &str = "devin-session-token";

fn build_client() -> Result<Client> {
    Client::builder()
        .user_agent(UA)
        .http2_prior_knowledge() // 抓包样本是 --http2，强制走 h2
        .timeout(Duration::from_secs(30))
        .connect_timeout(Duration::from_secs(10))
        .gzip(true)
        .build()
        .context("build reqwest client")
}

/// 拼装 GetOneTimeAuthTokenRequest 的 protobuf body。
///
/// 抓包样本结构：单字段 string，内容形如
/// `devin-session-token$<JWT>`（前缀 + `$` + 真正的 JWT）。
fn build_ott_request_body(jwt: &str) -> Vec<u8> {
    let payload = format!("{}${}", COOKIE_NAME, jwt);
    let mut buf = Vec::with_capacity(3 + payload.len());
    proto::write_string_field(1, &payload, &mut buf);
    buf
}

/// 调 GetOneTimeAuthToken，拿一次性令牌。
///
/// `jwt` 即 devin-session-token cookie 值（一段 JWT）。
pub async fn get_one_time_auth_token(jwt: &str) -> Result<String> {
    let client = build_client()?;
    let body = build_ott_request_body(jwt);

    let resp = client
        .post(format!(
            "{}/exa.seat_management_pb.SeatManagementService/GetOneTimeAuthToken",
            BASE
        ))
        .header("content-type", "application/proto")
        .header("accept", "application/proto")
        .header("cookie", format!("{}={}", COOKIE_NAME, jwt))
        .body(body)
        .send()
        .await
        .context("POST GetOneTimeAuthToken")?;

    let status = resp.status();
    let bytes = resp.bytes().await.context("read OTT body")?;
    if !status.is_success() {
        bail!(
            "GetOneTimeAuthToken HTTP {} body={:?}",
            status,
            String::from_utf8_lossy(&bytes)
        );
    }

    // 实测响应形如：
    //   0a 2f /ott$jom8gQQ2vtcPhuhPRanBcCHuv-OTtiZWh5zZwoVPRpE [\n]
    // OTT 自带 `/ott$` 前缀，整段都是 access_token；末尾偶尔带换行，trim 干净。
    //
    // 兼容 grpc-web frame header（5 字节 0x00 + len32 前缀）的情况：
    // 第一次解析失败就再剥掉前 5 字节重试。
    let parse = proto::parse_fields(&bytes).or_else(|_| {
        if bytes.len() > 5 {
            proto::parse_fields(&bytes[5..])
        } else {
            Err(anyhow!("response too short ({} bytes)", bytes.len()))
        }
    });
    let fields = parse
        .with_context(|| format!("parse OTT response ({} bytes)", bytes.len()))?;
    let raw_ott = proto::first_string(&fields, 1)
        .ok_or_else(|| anyhow!("OTT field missing in response"))?;
    let ott = raw_ott.trim().to_string();
    if ott.is_empty() {
        bail!("OTT empty after trim (raw={:?})", raw_ott);
    }
    Ok(ott)
}

// ─── GetPlanStatus（用量，protobuf） ────────────────────────────────

/// Windsurf 同时暴露两套度量：
///   1. **百分比配额**（PlanStatus.field 14/15）：daily / weekly 剩余百分比 0-100，
///      面向 Cascade chat / tab-to-jump 等高频能力，这是用户在 IDE 里最关心的。
///   2. **绝对 credits**（field 4-9）：prompt / flow / flex 月度计数，面向 Codex agent。
///
/// 字段编号来自 chaogei + zhouyoukang/wam 的实测整理（结合 web-backend 真实抓包验证）。
#[derive(Debug, Serialize, Deserialize, Clone, Default)]
#[serde(rename_all = "camelCase")]
pub struct PlanStatus {
    pub plan_name: Option<String>,
    pub plan_start: Option<i64>,
    pub plan_end: Option<i64>,

    /// 日配额剩余百分比（0-100）
    pub daily_percent: Option<u32>,
    /// 周配额剩余百分比（0-100）
    pub weekly_percent: Option<u32>,
    pub daily_reset_at: Option<i64>,
    pub weekly_reset_at: Option<i64>,

    pub prompt_used: Option<u64>,
    pub prompt_limit: Option<u64>,
    pub prompt_remaining: Option<u64>,

    pub flow_used: Option<u64>,
    pub flow_limit: Option<u64>,
    pub flow_remaining: Option<u64>,

    pub flex_used: Option<u64>,
    pub flex_remaining: Option<u64>,

    pub fetched_at: i64,
}

/// 解析 GetPlanStatus 的 protobuf 响应。
///
/// Wire layout（field 编号来自 chaogei + zhouyoukang/wam 的实测整理）：
///   GetPlanStatusResponse {
///     PlanStatus plan_status = 1 {
///       PlanInfo info = 1 {
///         int tier = 1, string plan_name = 2, ...
///         int monthly_prompt_credits = 12, int monthly_flow_credits = 13,
///       }
///       Timestamp plan_start = 2 { int seconds = 1 }
///       Timestamp plan_end   = 3 { int seconds = 1 }
///
///       // credit 计数（按月）
///       int available_flex_credits   = 4,
///       int used_flow_credits        = 5,
///       int used_prompt_credits      = 6,
///       int used_flex_credits        = 7,
///       int available_prompt_credits = 8,
///       int available_flow_credits   = 9,
///
///       // 短期百分比配额（0-100，剩余）
///       int daily_quota_remaining_percent  = 14,
///       int weekly_quota_remaining_percent = 15,
///       // 配额重置 unix
///       int daily_quota_reset_at_unix      = 17,
///       int weekly_quota_reset_at_unix     = 18,
///     }
///   }
fn parse_plan_status(buf: &[u8]) -> Result<PlanStatus> {
    let root = proto::parse_fields(buf)?;
    let plan_status_bytes = proto::first_bytes(&root, 1)
        .ok_or_else(|| anyhow!("plan_status root missing (field 1)"))?;
    let ps = proto::parse_fields(plan_status_bytes)?;

    // PlanInfo（field 1, sub-message）
    let (plan_name, prompt_limit, flow_limit) = match proto::first_bytes(&ps, 1) {
        Some(bytes) => {
            let pi = proto::parse_fields(bytes)?;
            (
                proto::first_string(&pi, 2).map(String::from),
                proto::first_varint(&pi, 12),
                proto::first_varint(&pi, 13),
            )
        }
        None => (None, None, None),
    };

    // Timestamp { int seconds = 1 } 嵌套
    let ts = |field: u32| -> Option<i64> {
        proto::first_bytes(&ps, field)
            .and_then(|b| proto::parse_fields(b).ok())
            .and_then(|f| proto::first_varint(&f, 1))
            .map(|v| v as i64)
    };
    let plan_start = ts(2);
    let plan_end = ts(3);

    // credit 计数（varint）：proto3 absent = 0，所以这里没有 used_xxx 时 None 即代表 0
    let avail_flex = proto::first_varint(&ps, 4);
    let used_flow = proto::first_varint(&ps, 5);
    let used_prompt = proto::first_varint(&ps, 6);
    let used_flex = proto::first_varint(&ps, 7);
    let avail_prompt = proto::first_varint(&ps, 8);
    let avail_flow = proto::first_varint(&ps, 9);

    // 重置 unix（必须 > 2023-11-14 的合理下界 1700000000，否则丢弃）
    let reset_ts = |field: u32| -> Option<i64> {
        proto::first_varint(&ps, field)
            .filter(|&v| v > 1_700_000_000)
            .map(|v| v as i64)
    };
    let daily_reset_at = reset_ts(17);
    let weekly_reset_at = reset_ts(18);

    // 百分比配额（0-100，剩余）。proto3 里 0 是默认值会被省略——
    // 也就是说"额度耗尽剩余 0%"在 wire 层等同于"字段缺失"。
    // 只要对应的 reset_at 存在（说明该度量启用了），percent 缺失就应当解释为 0。
    let pct = |field: u32, has_reset: bool| -> Option<u32> {
        match proto::first_varint(&ps, field) {
            Some(v) if v <= 100 => Some(v as u32),
            Some(_) => None, // 越界值，relay/wrapper 误读 → 丢弃
            None => has_reset.then_some(0),
        }
    };
    let daily_percent = pct(14, daily_reset_at.is_some());
    let weekly_percent = pct(15, weekly_reset_at.is_some());

    Ok(PlanStatus {
        plan_name,
        plan_start,
        plan_end,
        daily_percent,
        weekly_percent,
        daily_reset_at,
        weekly_reset_at,
        prompt_used: used_prompt,
        prompt_limit,
        prompt_remaining: avail_prompt,
        flow_used: used_flow,
        flow_limit,
        flow_remaining: avail_flow,
        flex_used: used_flex,
        flex_remaining: avail_flex,
        fetched_at: chrono::Utc::now().timestamp(),
    })
}

/// 调 GetPlanStatus 拿用量。protobuf body + 双 header 鉴权（x-auth-token + x-devin-session-token），
/// 二者值都为 `devin-session-token$<JWT>`，与 Windsurf web 前端 createDevinAuth1TokenInterceptor 一致。
pub async fn get_plan_status(jwt: &str) -> Result<PlanStatus> {
    // 网络抖动 / 单 host TLS 复位偶发 → 单次重试足以兜住绝大多数场景。
    // 5xx / timeout 重试，4xx（鉴权失败之类）直接返回别浪费时间。
    const MAX_ATTEMPTS: u32 = 2;
    let mut last_err: Option<anyhow::Error> = None;
    for attempt in 1..=MAX_ATTEMPTS {
        match try_get_plan_status_once(jwt).await {
            Ok(ps) => return Ok(ps),
            Err(e) => {
                let msg = format!("{:#}", e);
                let retryable = msg.contains("timed out")
                    || msg.contains("connection")
                    || msg.contains("HTTP 5")
                    || msg.contains("error sending request");
                if attempt < MAX_ATTEMPTS && retryable {
                    tokio::time::sleep(Duration::from_millis(500)).await;
                    last_err = Some(e);
                    continue;
                }
                return Err(e);
            }
        }
    }
    Err(last_err.unwrap_or_else(|| anyhow!("get_plan_status: exhausted retries")))
}

async fn try_get_plan_status_once(jwt: &str) -> Result<PlanStatus> {
    let client = build_client()?;
    let prefixed = format!("{}${}", COOKIE_NAME, jwt);

    let mut body = Vec::new();
    proto::write_string_field(1, &prefixed, &mut body);

    let resp = client
        .post(format!(
            "{}/exa.seat_management_pb.SeatManagementService/GetPlanStatus",
            BASE_API
        ))
        .header("content-type", "application/proto")
        .header("accept", "*/*")
        .header("connect-protocol-version", "1")
        .header("x-auth-token", &prefixed)
        .header("x-devin-session-token", &prefixed)
        .header("x-debug-email", "")
        .header("x-debug-team-name", "")
        .header("referer", "https://windsurf.com/")
        .body(body)
        .send()
        .await
        .context("POST GetPlanStatus")?;

    let status = resp.status();
    let bytes = resp.bytes().await.context("read GetPlanStatus body")?;
    if !status.is_success() {
        bail!(
            "GetPlanStatus HTTP {} body={:?}",
            status,
            String::from_utf8_lossy(&bytes)
        );
    }

    parse_plan_status(&bytes).with_context(|| {
        format!(
            "parse GetPlanStatus response ({} bytes)",
            bytes.len()
        )
    })
}

// ─── JWT 元信息（不验签，仅展示） ──────────────────────────

#[derive(Debug, Serialize, Deserialize, Clone, Default)]
#[serde(rename_all = "camelCase")]
pub struct JwtInfo {
    pub session_id: Option<String>,
    pub email: Option<String>,
    pub user_id: Option<String>,
    pub expires_at: Option<i64>,
    pub issued_at: Option<i64>,
}

#[derive(Debug, Deserialize, Default)]
#[serde(default)]
struct JwtPayload {
    session_id: Option<String>,
    email: Option<String>,
    user_id: Option<String>,
    sub: Option<String>,
    exp: Option<i64>,
    iat: Option<i64>,
}

/// 不做签名校验，只是把 JWT payload 解出来给 UI 展示。
pub fn decode_jwt_info(jwt: &str) -> JwtInfo {
    let parts: Vec<&str> = jwt.split('.').collect();
    if parts.len() < 2 {
        return JwtInfo::default();
    }
    let engine = base64::engine::general_purpose::URL_SAFE_NO_PAD;
    let bytes = match engine.decode(parts[1]) {
        Ok(b) => b,
        Err(_) => return JwtInfo::default(),
    };
    let payload: JwtPayload = match serde_json::from_slice(&bytes) {
        Ok(p) => p,
        Err(_) => return JwtInfo::default(),
    };
    JwtInfo {
        session_id: payload.session_id,
        email: payload.email,
        user_id: payload.user_id.or(payload.sub),
        expires_at: payload.exp,
        issued_at: payload.iat,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 模拟 GetOneTimeAuthToken 的响应 buffer，方便复用解析逻辑。
    fn fake_ott_response(payload: &str) -> Vec<u8> {
        let mut buf = Vec::new();
        proto::write_string_field(1, payload, &mut buf);
        buf
    }

    fn parse_ott_buf(bytes: &[u8]) -> anyhow::Result<String> {
        let parse = proto::parse_fields(bytes).or_else(|_| {
            if bytes.len() > 5 {
                proto::parse_fields(&bytes[5..])
            } else {
                Err(anyhow::anyhow!("too short"))
            }
        });
        let fields = parse?;
        let s = proto::first_string(&fields, 1).ok_or_else(|| anyhow::anyhow!("no field 1"))?;
        Ok(s.trim().to_string())
    }

    #[test]
    fn parse_real_world_ott_payload() {
        // 用户实测样本：响应 = field 1 string = "/ott$jom8...PRpE"
        let sample = "/ott$jom8gQQ2vtcPhuhPRanBcCHuv-OTtiZWh5zZwoVPRpE";
        assert_eq!(sample.len(), 48); // 0x30
        let buf = fake_ott_response(sample);
        assert_eq!(buf[0], 0x0a);
        assert_eq!(buf[1] as usize, sample.len());
        assert_eq!(buf.len(), 2 + sample.len());
        assert_eq!(parse_ott_buf(&buf).unwrap(), sample);
    }

    #[test]
    fn ott_with_trailing_newline_is_trimmed() {
        let buf = fake_ott_response("/ott$abcDEF123\n");
        assert_eq!(parse_ott_buf(&buf).unwrap(), "/ott$abcDEF123");
    }

    #[test]
    fn ott_with_grpc_web_frame_prefix() {
        // 假设响应前面被加了 5 字节 grpc-web frame header
        let mut buf = vec![0u8, 0, 0, 0, 49];
        buf.extend(fake_ott_response("/ott$xyz123"));
        assert_eq!(parse_ott_buf(&buf).unwrap(), "/ott$xyz123");
    }

    #[test]
    fn ott_body_matches_sample_prefix() {
        let jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzZXNzaW9uX2lkIjoid2luZHN1cmYtc2Vzc2lvbi1jYWRjZDVlZmVkNGE0MThmYTQyNjIyNWQ5Y2MxNmU5YiJ9.OLNgeJwjDUVHLd1t_M8I2vKGBwSFaxRhSOS8zqcU_iU";
        let body = build_ott_request_body(jwt);
        // 0a bd 01 = field 1, length 189
        assert_eq!(body[0], 0x0a);
        assert_eq!(body[1], 0xbd);
        assert_eq!(body[2], 0x01);
        assert_eq!(body.len(), 192);
        // 检查内部内容前缀
        assert_eq!(&body[3..3 + COOKIE_NAME.len()], COOKIE_NAME.as_bytes());
        assert_eq!(body[3 + COOKIE_NAME.len()], b'$');
    }
}
