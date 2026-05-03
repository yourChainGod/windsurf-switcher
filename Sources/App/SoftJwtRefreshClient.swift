//
//  SoftJwtRefreshClient.swift
//  App
//
//  通过本机 LanguageServerService/StartCascade 软触发 Windsurf LS 重新
//  调 AuthService/GetUserJwt；拿到 cascadeId 后立即 cancel + delete，避免
//  打断当前 LS 会话或继续生成聊天请求。
//

import Foundation

struct SoftJwtRefreshReport: Sendable {
    let pid: Int32
    let serverPort: UInt16
}

enum SoftJwtRefreshError: Error, CustomStringConvertible, Sendable {
    case processFailed(String)
    case invalidProcessLine(String)
    case missingServerPort(Int32)
    case missingCSRFToken(Int32)
    case invalidURL(String)
    case httpStatus(path: String, status: Int, body: String)
    case missingCascadeId

    var description: String {
        switch self {
        case .processFailed(let message):
            return message
        case .invalidProcessLine(let line):
            return "invalid language server process line: \(line)"
        case .missingServerPort(let pid):
            return "language server \(pid) has no --server_port"
        case .missingCSRFToken(let pid):
            return "language server \(pid) has no WINDSURF_CSRF_TOKEN"
        case .invalidURL(let url):
            return "invalid URL: \(url)"
        case .httpStatus(let path, let status, let body):
            return "\(path) returned HTTP \(status): \(body.prefix(240))"
        case .missingCascadeId:
            return "StartCascade response has no cascadeId"
        }
    }
}

struct SoftJwtRefreshClient {
    private let session: URLSession

    init(timeout: TimeInterval = 8) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        self.session = URLSession(configuration: config)
    }

    func triggerAll(apiPort: UInt16, apiKey: String) async throws -> [SoftJwtRefreshReport] {
        let servers = try await findLanguageServers(apiPort: apiPort)
        var reports: [SoftJwtRefreshReport] = []
        reports.reserveCapacity(servers.count)
        var lastFailure: Error?

        for server in servers {
            do {
                let report = try await trigger(server: server, apiKey: apiKey)
                reports.append(report)
            } catch {
                lastFailure = error
                FileHandle.standardError.write(Data("[wss] soft-jwt trigger failed pid=\(server.pid): \(error)\n".utf8))
            }
        }
        if reports.isEmpty, !servers.isEmpty, let lastFailure {
            throw lastFailure
        }
        return reports
    }

    private func trigger(server: LanguageServerProcess, apiKey: String) async throws -> SoftJwtRefreshReport {
        let csrf = try await csrfToken(pid: server.pid)
        let metadata = server.metadata(apiKey: apiKey)
        let startBody: [String: Any] = [
            "metadata": metadata,
            "source": "CORTEX_TRAJECTORY_SOURCE_CASCADE_CLIENT",
        ]
        let start = try await postJSON(
            serverPort: server.serverPort,
            path: "/exa.language_server_pb.LanguageServerService/StartCascade",
            csrf: csrf,
            body: startBody
        )
        guard let cascadeId = start["cascadeId"] as? String, !cascadeId.isEmpty else {
            throw SoftJwtRefreshError.missingCascadeId
        }

        let cascadeBody: [String: Any] = ["cascadeId": cascadeId]
        _ = try? await postJSON(
            serverPort: server.serverPort,
            path: "/exa.language_server_pb.LanguageServerService/CancelCascadeInvocationAndWait",
            csrf: csrf,
            body: cascadeBody
        )
        _ = try? await postJSON(
            serverPort: server.serverPort,
            path: "/exa.language_server_pb.LanguageServerService/DeleteCascadeTrajectory",
            csrf: csrf,
            body: cascadeBody
        )

        return SoftJwtRefreshReport(
            pid: server.pid,
            serverPort: server.serverPort
        )
    }

    @discardableResult
    private func postJSON(
        serverPort: UInt16,
        path: String,
        csrf: String,
        body: [String: Any]
    ) async throws -> [String: Any] {
        let urlString = "http://127.0.0.1:\(serverPort)\(path)"
        guard let url = URL(string: urlString) else {
            throw SoftJwtRefreshError.invalidURL(urlString)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.addValue(csrf, forHTTPHeaderField: "x-codeium-csrf-token")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw SoftJwtRefreshError.httpStatus(path: path, status: status, body: text)
        }
        if data.isEmpty { return [:] }
        let json = try JSONSerialization.jsonObject(with: data, options: [])
        return (json as? [String: Any]) ?? [:]
    }

    private func findLanguageServers(apiPort: UInt16) async throws -> [LanguageServerProcess] {
        let output = try await runProcess("/bin/ps", ["axww", "-o", "pid=", "-o", "command="])
        let apiURL = "http://127.0.0.1:\(apiPort)"
        var servers: [LanguageServerProcess] = []

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard line.contains("language_server"),
                  line.contains("--api_server_url"),
                  line.contains(apiURL) else {
                continue
            }
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 2, let pid = Int32(parts[0]) else {
                throw SoftJwtRefreshError.invalidProcessLine(line)
            }
            let command = String(parts[1])
            guard let serverPort = UInt16(argumentValue("--server_port", in: command) ?? "") else {
                throw SoftJwtRefreshError.missingServerPort(pid)
            }
            servers.append(LanguageServerProcess(pid: pid, command: command, serverPort: serverPort))
        }

        return servers
    }

    private func csrfToken(pid: Int32) async throws -> String {
        let output = try await runProcess("/bin/ps", ["eww", "-p", String(pid)])
        let marker = "WINDSURF_CSRF_TOKEN="
        guard let range = output.range(of: marker) else {
            throw SoftJwtRefreshError.missingCSRFToken(pid)
        }
        let tail = output[range.upperBound...]
        let token = tail.prefix { !$0.isWhitespace }
        guard !token.isEmpty else {
            throw SoftJwtRefreshError.missingCSRFToken(pid)
        }
        return String(token)
    }

    private func runProcess(_ executable: String, _ arguments: [String]) async throws -> String {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            try process.run()
            process.waitUntilExit()

            let outData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            let out = String(data: outData, encoding: .utf8) ?? ""
            let err = String(data: errData, encoding: .utf8) ?? ""

            guard process.terminationStatus == 0 else {
                throw SoftJwtRefreshError.processFailed("\(executable) \(arguments.joined(separator: " ")) failed: \(err)")
            }
            return out
        }.value
    }
}

private struct LanguageServerProcess: Sendable, Equatable {
    let pid: Int32
    let command: String
    let serverPort: UInt16

    func metadata(apiKey: String) -> [String: String] {
        [
            "ideName": argumentValue("--ide_name", in: command) ?? "windsurf",
            "ideVersion": argumentValue("--ide_version", in: command) ?? "2.1.32",
            "extensionName": argumentValue("--extension_name", in: command) ?? "windsurf",
            "extensionVersion": argumentValue("--extension_version", in: command) ?? "0.2.0",
            "apiKey": apiKey,
            "locale": argumentValue("--locale", in: command) ?? Locale.current.identifier.lowercased().replacingOccurrences(of: "_", with: "-"),
            "os": "darwin",
            "hardware": localHardwareName(),
        ]
    }
}

private func argumentValue(_ name: String, in command: String) -> String? {
    let args = command.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    for idx in args.indices {
        let arg = args[idx]
        if arg == name, args.indices.contains(idx + 1) {
            return args[idx + 1]
        }
        let prefix = name + "="
        if arg.hasPrefix(prefix) {
            return String(arg.dropFirst(prefix.count))
        }
    }
    return nil
}

private func localHardwareName() -> String {
    #if arch(arm64)
    return "arm64"
    #elseif arch(x86_64)
    return "x86_64"
    #else
    return "unknown"
    #endif
}
