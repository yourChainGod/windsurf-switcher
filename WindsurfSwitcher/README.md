# WindsurfSwitcher (Native)

原生 Swift 重铸的 windsurf-switcher，替代旧 `src-tauri/` 工程。

## 工程拓扑

- `Sources/Core/` — Account / 持久化 / protobuf wire codec / 双 app 描述 / 数据迁移
- `Sources/WindsurfClient/` — GetOneTimeAuthToken / GetPlanStatus / JWT decode
- `Sources/External/` — 旧 binary 清理 / 调起辅助脚本
- `Sources/WSSCLI/` — 命令行工具，跑迁移 dry-run、切号验证等
- App target（NSStatusItem + SwiftUI popover）后续 phase 用 Xcode 工程承载

## 构建

```bash
cd WindsurfSwitcher
swift build
swift test
```

要求：Swift 5.10+ / macOS 13+。

## 路线

详见 `/Users/zhangshijie/.claude/plans/calm-rolling-quiche.md`。
