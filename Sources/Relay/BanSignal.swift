//
//  BanSignal.swift
//  Relay
//
//  封号信号检测器，参考 Windsurf 常见 auth/ban 文案。
//
//  用途：上游 401/403 或 200+应用层错误中，body 文本若匹配下列任一模式，
//  视为"账号被封"信号——单次不下结论，30min 窗内连续 ≥2 次升级到永久 disable。
//
//  设计要点：
//    - 全部 regex 用 bounded `[^.\n]{0,40}` 间隔，避免 `.*` ReDoS 风险。
//    - 中英双语：英文专业术语 + 中文 zh 错误页常见用词。
//    - 顺序按"最具体在前"。
//
//  注意：NSRegularExpression 默认大小写敏感，所以英文模式都包了 `(?i)` 前缀。
//

import Foundation

public enum BanSignal {
    /// 11 条封号信号 regex（中英）。延迟编译 + 缓存。
    private static let patterns: [NSRegularExpression] = {
        let raw: [String] = [
            // account_suspended / account-disabled / user_banned / api_key_revoked 等错误码
            #"(?i)\b(?:account|user|email|api[_-]?key)[_-](?:suspend(?:ed)?|disabled|banned|revoked|terminated|deactivated|locked|closed)\b"#,
            // "Your account has been suspended" / "Account banned by upstream"
            #"(?i)\baccount\b[^.\n]{0,40}\b(?:suspend(?:ed)?|disabled|banned|terminated|deactivated|locked|closed)\b"#,
            // "User suspended due to abuse"
            #"(?i)\b(?:user|email)\b[^.\n]{0,40}\b(?:suspend(?:ed)?|disabled|banned|terminated)\b"#,
            // "subscription cancelled / terminated / expired"
            #"(?i)\bsubscription\b[^.\n]{0,40}\b(?:cancel(?:led|ed)?|terminated|expired|invalid)\b"#,
            // "Authentication failed / invalid / denied"
            #"(?i)\bauthentication\b[^.\n]{0,40}\b(?:failed|invalid|denied|revoked)\b"#,
            // "Invalid API key"
            #"(?i)\binvalid\s+api[_\s-]?key\b"#,
            // "API key revoked / disabled / expired"
            #"(?i)\bapi[_\s-]?key\b[^.\n]{0,40}\b(?:revoked|disabled|expired|invalid)\b"#,
            // "Unauthorized account/key/credential"
            #"(?i)\bunauthorized\b[^.\n]{0,40}\b(?:account|key|credential|exist)\b"#,
            // 中文：账号停用/封禁/禁用/冻结/注销/关闭
            #"账号(?:已|被|已被)?(?:停用|封禁|禁用|冻结|注销|关闭)"#,
            // 中文：用户/邮箱 停用/封禁/禁用
            #"(?:用户|邮箱)(?:已|被|已被)?(?:停用|封禁|禁用)"#,
            // 中文：订阅 取消/过期/失效
            #"订阅(?:已)?(?:取消|过期|失效)"#,
        ]
        return raw.compactMap { p in
            do {
                return try NSRegularExpression(pattern: p, options: [])
            } catch {
                FileHandle.standardError.write(Data("[BanSignal] regex compile failed: \(p) - \(error)\n".utf8))
                return nil
            }
        }
    }()

    /// `bodyText` 命中任一 ban 信号模式 → 返回 true。
    /// 调用方：server 在 401/403 或 200+app_error 路径上抓 body 前若干 KB
    /// 转 utf8（用 `extractText`），传入此函数。
    public static func matches(_ bodyText: String) -> Bool {
        guard !bodyText.isEmpty else { return false }
        let range = NSRange(bodyText.startIndex..<bodyText.endIndex, in: bodyText)
        for r in patterns {
            if r.firstMatch(in: bodyText, options: [], range: range) != nil {
                return true
            }
        }
        return false
    }

    /// 安全地从字节流构造 utf8 lossy 字符串，截到前 N 字节避免大 body 拖慢正则。
    /// proto 帧里少量二进制也无碍——非法 utf8 字节会被忽略（无效字节序列截断）。
    public static func extractText(_ body: [UInt8], maxBytes: Int) -> String {
        let n = min(body.count, maxBytes)
        guard n > 0 else { return "" }
        let slice = body[0..<n]
        return String(decoding: Array(slice), as: UTF8.self)
    }
}
