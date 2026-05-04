# Windsurf Switcher

Windsurf Switcher 是一个原生 macOS 菜单栏应用，用来管理多个 Windsurf 账号，并让 Windsurf Stable / Windsurf Next 的本地 language server 尽量使用仍有额度的账号。

它做三件事：

- 管理账号池：保存 token、刷新 quota、记录冷却/封禁/最近使用状态。
- 接管 language server 出口：为 Stable 和 Next 分别安装 wrapper，把 `api_server_url` 和 `inference_api_server_url` 指向本机 relay。
- 无感触发换 JWT：通过本机 `StartCascade` 让 Windsurf LS 主动请求新的 `GetUserJwt`，触发后立即 cancel/delete，不继续生成聊天。

## 当前状态

- macOS 13+ 原生 SwiftUI `MenuBarExtra` 应用。
- 支持 Windsurf Stable 和 Windsurf Next，两个 app 使用不同端口，active JWT 状态互不覆盖。
- 账号数据只保存在本机。
- 默认不签名、不 notarize，适合本机自用或自行签名分发。

## 核心机制

### 账号池调度

Relay 只在 `GetUserJwt` 路径上真正选号。选号会过滤冷却、封禁、quota 耗尽和当前 active 账号，然后按 score 排序。`GetUserJwt` 成功后，该账号会成为对应 app 的 active 账号。

非 `GetUserJwt` 请求不会随便换号，而是复用对应 app 的 active token。这样 Stable 和 Next 的 language server 缓存 JWT 与 relay 侧记录保持一致。

### Quota 刷新

应用会持续刷新账号真实 quota：

- 全池刷新：约 1 分钟一轮，按最旧 `fetchedAt` 优先，批量并发但控制突发。
- Active 刷新：约 15 秒一次，刷新 Stable / Next 当前 active 账号。
- 事件刷新：`GetUserJwt` 成功、`GetChatMessage` 完成、active quota 耗尽时立即补刷。

注意：UI 展示类 RPC 会被改写为“满血”，但调度是否可用以后台 `GetPlanStatus` 拿到的真实 quota 为准。

### 软触发 GetUserJwt

Windsurf 自己大约 5 分钟会请求一次 `GetUserJwt`。本项目额外在中间用 `StartCascade` 触发一次，使节奏接近 2.5 分钟。

触发前会重新检查候选号 quota。只有候选号 daily / weekly quota 都已知且大于 0，才会对 LS 发起 `StartCascade`。如果候选号无额度或刷新失败，本轮触发会跳过，避免切到不可用账号。

`GetUserStatus` 返回 401 不能可靠触发重新认证，所以这里不依赖 401；统一使用 `StartCascade` 触发 LS 自己走 `GetUserJwt`。

### 限流处理

`GetChatMessage` 如果返回模型限流或 permission 相关 Connect 错误，relay 会排除当前账号后继续尝试有额度账号。耗尽时不会把原始限流帧直接回放给客户端，避免 IDE 进入错误状态。

## 环境要求

- macOS 13 或更新版本
- Swift 5.10 或更新版本
- Windsurf Stable：`/Applications/Windsurf.app`
- 可选 Windsurf Next：`/Applications/Windsurf - Next.app`

不需要 Node、pnpm 或前端构建工具。

## 快速开始

构建并安装到 `/Applications`：

```bash
bash scripts/build-app.sh release
rm -rf /Applications/WindsurfSwitcher.app
ditto build/WindsurfSwitcher.app /Applications/WindsurfSwitcher.app
open /Applications/WindsurfSwitcher.app
```

首次打开如果被 macOS 拦截，可以在 Finder 里右键 `WindsurfSwitcher.app`，选择“打开”。

启动后它不会出现在 Dock，只会出现在菜单栏。点菜单栏的 wind 图标打开窗口。

首次使用流程：

1. 在账号管理页添加 `devin-session-token`。
2. 等待 quota 刷新完成，确认账号不是无额度或鉴权失败。
3. 打开设置页，点击“一键安装两个 app”。
4. 输入管理员密码，允许替换 Windsurf language server binary。
5. 重启 Windsurf Stable / Windsurf Next。

Wrapper 安装后，原 language server binary 会备份为同目录 `.real` 文件；设置页可随时卸载并还原。

## 构建、测试、打包

```bash
swift test
swift build --product WindsurfSwitcher
```

构建 app bundle：

```bash
bash scripts/build-app.sh release
open build/WindsurfSwitcher.app
```

打包 DMG：

```bash
bash scripts/build-dmg.sh
```

产物：

- `build/WindsurfSwitcher.app`
- `build/WindsurfSwitcher-0.2.0.dmg`

## 本机端口

| App | API relay | Inference relay |
| --- | ---: | ---: |
| Windsurf Stable | `127.0.0.1:42199` | `127.0.0.1:42200` |
| Windsurf Next | `127.0.0.1:42201` | `127.0.0.1:42202` |

诊断：

```bash
curl -fsS http://127.0.0.1:42199/__relay/health
curl -fsS http://127.0.0.1:42199/__relay/pool
curl -fsS http://127.0.0.1:42201/__relay/health
```

账号导入 API 只挂在 Stable API relay：

```bash
curl -s -X POST http://127.0.0.1:42199/__relay/accounts \
  -H 'content-type: application/json' \
  -d '{"session_token":"<devin-session-token-or-jwt>","label":"backup"}'
```

## 数据目录

当前数据：

```text
~/Library/Application Support/com.windsurfswitcher.native/accounts.json
```

旧版数据迁移源：

```text
~/Library/Application Support/com.windsurf.switcher/accounts.json
```

迁移只复制并转换账号数据，不删除旧文件。应用启动时如果新数据为空，会自动尝试迁移；也可以用 CLI 手动执行。

## 持久化日志（早期调试用，后期稳定会移除）

> **注意**：当前版本会把所有 `print` / `Logger` / stdout / stderr 输出落盘，方便复现偶发账号冷却 / relay 异常时回看现场。等行为稳定后这个文件会被默认禁用。

日志路径：

```text
~/Library/Logs/com.windsurfswitcher.native/wss.log
```

特点：

- 启动时打印 banner（pid + version + 时间戳），跨重启可对应进程
- 单文件 10 MB 自动滚动到 `wss.log.1`，最多两份
- 关键事件：账号冷却 / 解封、`GetUserJwt` 5 次重试链路、`GetChatMessage` 限流退避、proto 改写错误、池快照（total/cooled/banned/quota_exhausted）

排障常用：

```bash
tail -f ~/Library/Logs/com.windsurfswitcher.native/wss.log
grep -E "Pool|recordFailure|allExcluded" ~/Library/Logs/com.windsurfswitcher.native/wss.log | tail -50
grep "WSS log opened" ~/Library/Logs/com.windsurfswitcher.native/wss.log    # 看本机所有启动记录
```

## 命令行工具

Swift package 内置 `wss-cli`：

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

## 目录结构

```text
.
├── Package.swift
├── Sources
│   ├── App              菜单栏应用、UI 状态、软触发 GetUserJwt
│   ├── Core             账号模型、存储、迁移、protobuf wire 工具
│   ├── External         旧版进程与已废 daemon 清理
│   ├── Relay            本机 HTTP relay、账号池、响应改写、统计
│   ├── WindsurfClient   GetOTT、GetPlanStatus、JWT 解码
│   ├── Wrapper          language server wrapper 安装器
│   └── WSSCLI           命令行维护工具
├── Tests
└── scripts
    ├── build-app.sh
    └── build-dmg.sh
```

## 故障排查

第一步：看日志（早期调试默认开启，后期稳定会移除）：

```bash
tail -200 ~/Library/Logs/com.windsurfswitcher.native/wss.log
```

看不到菜单栏图标：

- 确认 app 已启动：`pgrep -fl WindsurfSwitcher`
- 从终端打开看日志：`/Applications/WindsurfSwitcher.app/Contents/MacOS/WindsurfSwitcher`

Relay 不通：

```bash
curl -v http://127.0.0.1:42199/__relay/health
lsof -nP -iTCP:42199 -sTCP:LISTEN
```

Windsurf 没走 relay：

- 在设置页重新检测 wrapper。
- 如果显示端口陈旧，重新安装 wrapper。
- 重启 Windsurf。

需要还原 Windsurf：

- 在设置页对对应 app 点击“卸载”。
- 或重新安装 Windsurf，恢复原 language server binary。

旧版 daemon 占用端口：

- 设置页的“旧版本清理”会检测 `cascade-port-forward`。
- 如果仍在运行，点击卸载已废 daemon，并输入管理员密码。

## 安全说明

- token 只写入本机 `accounts.json`。
- relay 只监听 `127.0.0.1`。
- 本项目不会把 token 上传到第三方服务；它只会按 Windsurf 原协议访问 Windsurf 上游。
- 默认构建不签名。需要分发时请自行 codesign 和 notarize。
