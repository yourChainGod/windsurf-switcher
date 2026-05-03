//
//  WindsurfApp.swift
//  Core
//
//  双 app 描述：Windsurf（stable）+ Windsurf - Next。
//  共享账号池但每号有 Account.lastUsedApp 标记。
//
//  路径与 scheme 实测来源（2026-05-02）：
//    Stable bundleId: com.exafunction.windsurf
//    Next   bundleId: com.exafunction.windsurfNext
//    Stable scheme:   windsurf://
//    Next   scheme:   windsurf-next://
//    LS path:         <App>/Contents/Resources/app/extensions/windsurf/bin/language_server_macos_arm
//

import Foundation

public enum WindsurfApp: String, Codable, CaseIterable, Sendable, Equatable, Hashable {
    case stable
    case next

    public var displayName: String {
        switch self {
        case .stable: return "Windsurf"
        case .next: return "Windsurf Next"
        }
    }

    public var bundleIdentifier: String {
        switch self {
        case .stable: return "com.exafunction.windsurf"
        case .next: return "com.exafunction.windsurfNext"
        }
    }

    /// macOS app bundle 主目录。注意 Next 的目录名带空格 + 短横线。
    public var appPath: URL {
        switch self {
        case .stable: return URL(fileURLWithPath: "/Applications/Windsurf.app")
        case .next: return URL(fileURLWithPath: "/Applications/Windsurf - Next.app")
        }
    }

    /// LS arm64 二进制路径（被 wrapper 替换的目标）。
    public var lsBinaryPath: URL {
        appPath
            .appendingPathComponent("Contents/Resources/app/extensions/windsurf/bin")
            .appendingPathComponent("language_server_macos_arm")
    }

    /// wrapper 安装时把原 binary 备份成 .real。
    public var lsBinaryRealBackupPath: URL {
        lsBinaryPath.appendingPathExtension("real")
    }

    /// `extension.js`（Electron 扩展），cascade 拦截路径调研用。
    public var extensionJsPath: URL {
        appPath.appendingPathComponent("Contents/Resources/app/extensions/windsurf/dist/extension.js")
    }

    /// `<scheme>://` 字符串（带 `://`）。
    public var deepLinkSchemePrefix: String {
        switch self {
        case .stable: return "windsurf://"
        case .next: return "windsurf-next://"
        }
    }

    /// 切号 deep link：`<scheme>://codeium.windsurf#state=switch&access_token=<URL_ENC_OTT>`。
    /// 旧 commands.rs::switch_account 的路径是固定的 `codeium.windsurf` host + state=switch fragment。
    public func switchURL(ott: String) -> URL? {
        // RFC 3986 unreserved 之外都转义。`url::form_urlencoded::byte_serialize` 等价。
        // CharacterSet.urlQueryAllowed 包含太多（含 +, =, &），不够严格；用自定义 set。
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let encoded = ott.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }
        let s = "\(deepLinkSchemePrefix)codeium.windsurf#state=switch&access_token=\(encoded)"
        return URL(string: s)
    }

    /// app bundle 是否实际安装。
    public var isInstalled: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: appPath.path, isDirectory: &isDir) && isDir.boolValue
    }
}
