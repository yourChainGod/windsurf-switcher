# Windsurf Switcher

Windsurf Switcher 是一个原生 macOS 菜单栏应用，用来管理多个 Windsurf
账号，在 Windsurf Stable 和 Windsurf Next 之间切号，并让本地语言服务器 relay
尽量使用仍有额度的账号。

当前仓库已经切换为 Swift 原生实现。旧的 Tauri / React / Rust 根项目已经移除。

## 功能

- 本地保存多个 `devin-session-token` 账号。
- 在菜单栏弹窗里显示每日 / 每周额度、冷却、封禁和 relay 健康状态。
- 通过 Windsurf 的 one-time-auth-token deep link 完成切号。
- 为 Windsurf Stable 和 Windsurf Next 安装轻量 language-server wrapper。
- Stable 和 Next 使用独立本地端口，两个 app 的 active 账号状态互不干扰。
- 通过账号池重写 `GetUserJwt` 响应，并跳过额度已耗尽的账号。
- 使用 `StartCascade` 软触发 Windsurf language server 重新请求 `GetUserJwt`，
  包括 2.5 分钟一次的中间刷新节奏。
- 提供本地账号导入 API，方便脚本批量入号。

## 环境要求

- macOS 13 或更新版本
- Swift 5.10 或更新版本
- Windsurf Stable：`/Applications/Windsurf.app`
- 可选 Windsurf Next：`/Applications/Windsurf - Next.app`

现在不再需要 Node、pnpm、Rust 或 Tauri 工具链。

## 构建与测试

```bash
swift test
swift build --product WindsurfSwitcher
```

构建 release app：

```bash
bash scripts/build-app.sh release
open build/WindsurfSwitcher.app
```

打 DMG：

```bash
bash scripts/build-dmg.sh
```

产物位置：

- app：`build/WindsurfSwitcher.app`
- DMG：`build/WindsurfSwitcher-<version>.dmg`

## 本机安装

```bash
bash scripts/build-app.sh release
rm -rf /Applications/WindsurfSwitcher.app
ditto build/WindsurfSwitcher.app /Applications/WindsurfSwitcher.app
open /Applications/WindsurfSwitcher.app
```

这是一个 `LSUIElement` 菜单栏应用，没有 Dock 图标。启动后请在 macOS 菜单栏里找
wind 图标。

## 首次使用

1. 从 `/Applications` 打开 Windsurf Switcher。
2. 在账号管理页添加账号，或通过本地 API 导入账号。
3. 打开设置页，点击 `一键安装两个 app`。
4. 按 macOS 提示输入管理员密码。应用会把每个 Windsurf 的 language-server
   binary 替换成 shell wrapper，并把原 binary 备份为 `.real`。
5. 如果 Windsurf / Windsurf Next 已经在运行，重启它们。

wrapper 可以在设置页卸载。卸载时会把 `.real` 备份还原成原 language-server
binary。

## 本地端口

| App | API relay | Inference relay |
| --- | ---: | ---: |
| Windsurf Stable | `127.0.0.1:42199` | `127.0.0.1:42200` |
| Windsurf Next | `127.0.0.1:42201` | `127.0.0.1:42202` |

常用诊断命令：

```bash
curl -fsS http://127.0.0.1:42199/__relay/health
curl -fsS http://127.0.0.1:42201/__relay/health
```

## 通过 API 导入账号

```bash
curl -s -X POST http://127.0.0.1:42199/__relay/accounts \
  -H 'content-type: application/json' \
  -d '{"session_token":"<devin-session-token-or-jwt>","label":"backup"}'
```

token 只保存在本机，数据文件路径：

```text
~/Library/Application Support/com.windsurfswitcher.native/accounts.json
```

旧 Tauri 版本的数据可以从这里迁移：

```text
~/Library/Application Support/com.windsurf.switcher/accounts.json
```

迁移不会删除旧文件，只会复制并转换到新的 native 数据目录。

## 命令行工具

Swift package 里也包含 `wss-cli`：

```bash
swift run wss-cli check
swift run wss-cli migrate --force
swift run wss-cli list
swift run wss-cli add '<token>' 'label'
swift run wss-cli refresh <uuid>
swift run wss-cli switch <uuid> stable
swift run wss-cli switch <uuid> next
swift run wss-cli kill-legacy
```

## 项目结构

```text
.
├── Package.swift
├── Sources
│   ├── App              SwiftUI MenuBarExtra 应用和 UI 状态
│   ├── Core             账号模型、持久化、protobuf wire 工具
│   ├── External         旧版本清理辅助
│   ├── Relay            本地 HTTP relay、账号池调度、响应重写
│   ├── WindsurfClient   GetOTT、GetPlanStatus、JWT 解码
│   ├── Wrapper          language-server wrapper 安装器
│   └── WSSCLI           命令行维护工具
├── Tests
└── scripts
    ├── build-app.sh
    └── build-dmg.sh
```

## 说明

- `GetUserStatus` 返回 401 不能可靠触发 Windsurf 重新认证，所以本项目使用
  `StartCascade` 软触发新的 `GetUserJwt` 请求。
- Stable 和 Next 在 relay manager 里独立分组，某个 app 的切号或额度事件不会覆盖
  另一个 app 的 active JWT。
- 额度刷新是保守策略：切换到新的 JWT candidate 前，会再次刷新该账号并确认它仍有可用额度。
