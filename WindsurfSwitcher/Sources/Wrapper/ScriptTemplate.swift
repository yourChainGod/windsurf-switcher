//
//  ScriptTemplate.swift
//  Wrapper
//
//  内嵌的 wrapper sh 脚本模板。原样翻译自
//  src-tauri/wrapper/language_server_macos_arm.sh，含 __RELAY_PORT__ /
//  __INFERENCE_PORT__ 占位符。
//
//  作用：
//    - 剔除调用方传入的所有 --api_server_url，强制改为本地 api relay
//    - 剔除调用方传入的所有 --inference_api_server_url，强制改为本地 inference relay
//    - clap last-wins，所以追加在末尾保险。
//

import Foundation

public enum WrapperScript {
    /// 模板原文。占位符 `__RELAY_PORT__` / `__INFERENCE_PORT__` 由调用方替换。
    public static let template = """
        #!/bin/sh
        # language_server_macos_arm — cascade-relay wrapper
        #
        # 由 windsurf-switcher.app 在用户授权下安装。
        # 真正的 LS binary 被改名为 .real。
        #
        # 行为：
        #   - 剔除调用方传入的所有 --api_server_url，强制改成本地 api relay 端口
        #   - 剔除调用方传入的所有 --inference_api_server_url，强制改成本地 inference relay 端口
        # clap last-wins，所以追加在末尾保险。
        ARGS=()
        SKIP=0
        for ARG in "$@"; do
          [ $SKIP -eq 1 ] && { SKIP=0; continue; }
          case "$ARG" in
            --api_server_url) SKIP=1 ;;
            --api_server_url=*) ;;
            --inference_api_server_url) SKIP=1 ;;
            --inference_api_server_url=*) ;;
            *) ARGS+=("$ARG") ;;
          esac
        done
        exec "$0.real" "${ARGS[@]}" \\
          --api_server_url "http://127.0.0.1:__RELAY_PORT__" \\
          --inference_api_server_url "http://127.0.0.1:__INFERENCE_PORT__"

        """

    /// 标记字符串：检测当前 LS 路径是否已被吾们替换。
    public static let signature = "cascade-relay wrapper"

    /// 把模板里的端口占位符替换成真实端口。
    public static func render(relayPort: UInt16, inferencePort: UInt16) -> String {
        template
            .replacingOccurrences(of: "__RELAY_PORT__", with: String(relayPort))
            .replacingOccurrences(of: "__INFERENCE_PORT__", with: String(inferencePort))
    }
}
