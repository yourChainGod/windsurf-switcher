# Windsurf Switcher

macOS 菜单栏小工具：在多个 Windsurf `devin-session-token` 之间一键切号，并展示弹性计费用量（每日 / 每周配额）。

```
┌────────────── 菜单栏 ──────────────┐
│   ≋  Windsurf Switcher              │
└──────────────┬───────────────────────┘
               ▼  点击图标弹出小窗
   ┌─────────────────────────────┐
   │ ≋ alice@example.com   [切号]│
   │   Pro · 日 87% / 周 64%     │
   ├─────────────────────────────┤
   │ ≋ work@org.dev        [切号]│
   │   Free · 日 12% / 周 28%    │
   └─────────────────────────────┘
```

## 工作原理

1. 后端 `Rust` 拼装一个最小 protobuf 请求：
   ```
   field 1 (string) = "devin-session-token$<JWT>"
   ```
   POST 到
   `https://windsurf.com/_backend/exa.seat_management_pb.SeatManagementService/GetOneTimeAuthToken`
   走 HTTP/2 + `application/proto`。
2. 解析响应里的 OTT 字符串。
3. 用系统 `open` 触发 deep link：
   ```
   windsurf://codeium.windsurf#state=switch&access_token=<URL_ENCODED_OTT>
   ```
   Windsurf IDE 会自动接管完成切号。
4. 用量信息走同域的 `GetUserStatus`（Connect-RPC JSON + cookie 认证）。

实测请求体与抓包样本字节级一致：
- 总长 192 字节
- 前 3 字节 `0a bd 01`（field 1 / wire type 2 / length 189）
- 单元测试 `ott_body_matches_sample_prefix` 已校验

## 依赖

- macOS 11+
- Node 20+ / pnpm（首次会通过 Corepack 自动拉 `pnpm@9.15.4`）
- Rust 1.77+
- Tauri v2

## 开发

首次执行：
```bash
COREPACK_ENABLE_DOWNLOAD_PROMPT=0 pnpm install
pnpm tauri:dev
```

> 第一次跑会编译 reqwest / tauri 依赖（约 2 分钟），之后增量编译秒级。

打包：
```bash
pnpm tauri:build
# 产物：src-tauri/target/release/bundle/macos/Windsurf Switcher.app
```

## 数据存储

```
~/Library/Application Support/com.windsurf.switcher/accounts.json
```

- 写入策略：`*.tmp` 写入完成后 `rename`，原子替换
- 不上传任何远端服务器；token 只走 windsurf.com 自家接口

## 怎么拿 `devin-session-token`

1. 浏览器登录 `https://windsurf.com`
2. F12 → Application → Cookies → `https://windsurf.com`
3. 复制 `devin-session-token` 整个 JWT 值
4. 在小窗里点 “+”，粘贴并保存

## 菜单栏交互

| 操作 | 动作 |
| --- | --- |
| 左键单击 Tray | 在图标下方弹出 / 收起小窗 |
| 右键 Tray | 原生菜单：打开窗口 / 刷新所有 / 关于 / 退出 |
| 窗口失焦 | 自动隐藏（macOS 标准 menubar app 行为） |
| 双击账号名 | 改备注 |

## 项目结构

```
.
├── src/                    React 前端
│   ├── App.tsx             主面板
│   ├── components/         AccountCard / AddTokenDialog / SettingsPanel / Toast
│   ├── lib/api.ts          invoke 封装
│   └── lib/format.ts       数字 / 时间格式化
├── src-tauri/              Rust 后端
│   ├── src/proto.rs        手搓 protobuf 编解码
│   ├── src/windsurf.rs     GetOneTimeAuthToken / GetUserStatus
│   ├── src/store.rs        accounts.json 原子持久化
│   ├── src/commands.rs     Tauri 暴露给前端的命令
│   └── src/lib.rs          Tray + 菜单栏窗口装配
└── tools/gen_icons.py      Tray 模板图标 + 应用图标生成脚本
```

## 参考

- [dwgx/WindsurfAPI](https://github.com/dwgx/WindsurfAPI) —— protobuf 手搓与 Windsurf 内部协议参考
