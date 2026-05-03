# Windsurf Switcher

Native macOS menu-bar app for managing multiple Windsurf accounts, switching
accounts between Windsurf Stable and Windsurf Next, and keeping the local
language-server relay pointed at accounts with quota.

This repository is now the Swift native implementation. The old Tauri / React /
Rust project has been removed from the root tree.

## What It Does

- Stores multiple `devin-session-token` accounts locally.
- Shows daily / weekly quota, cooldown, ban, and relay health in a compact
  menu-bar popover.
- Switches accounts through Windsurf's one-time-auth-token deep link.
- Installs a small language-server wrapper for Windsurf Stable and Windsurf Next.
- Runs local relays for Stable and Next on separate ports so their active
  account state does not collide.
- Rewrites `GetUserJwt` responses through the account pool and skips accounts
  with exhausted quota.
- Soft-triggers Windsurf language servers to request fresh JWTs by using
  `StartCascade`, including the periodic 2.5-minute refresh path.
- Exposes a local account-import API for scripts and automation.

## Requirements

- macOS 13 or newer
- Swift 5.10 or newer
- Windsurf installed at `/Applications/Windsurf.app`
- Optional: Windsurf Next installed at `/Applications/Windsurf - Next.app`

No Node, pnpm, Rust, or Tauri toolchain is required anymore.

## Build And Test

```bash
swift test
swift build --product WindsurfSwitcher
```

Release app bundle:

```bash
bash scripts/build-app.sh release
open build/WindsurfSwitcher.app
```

DMG:

```bash
bash scripts/build-dmg.sh
```

The release bundle is written to `build/WindsurfSwitcher.app`. The DMG is
written to `build/WindsurfSwitcher-<version>.dmg`.

## Install Locally

```bash
bash scripts/build-app.sh release
rm -rf /Applications/WindsurfSwitcher.app
ditto build/WindsurfSwitcher.app /Applications/WindsurfSwitcher.app
open /Applications/WindsurfSwitcher.app
```

The app is an `LSUIElement` menu-bar app, so it has no Dock icon. Look for the
wind icon in the macOS menu bar.

## First Run

1. Open Windsurf Switcher from `/Applications`.
2. Add accounts from the account-management page, or import them through the
   local API.
3. Open Settings and run `一键安装两个 app`.
4. Approve the macOS administrator prompt. The app replaces each Windsurf
   language-server binary with a shell wrapper and keeps the original binary as
   `.real`.
5. Restart Windsurf / Windsurf Next if they were already running.

The wrapper is reversible from Settings. Uninstalling restores the original
language-server binary from the `.real` backup.

## Local Ports

| App | API relay | Inference relay |
| --- | ---: | ---: |
| Windsurf Stable | `127.0.0.1:42199` | `127.0.0.1:42200` |
| Windsurf Next | `127.0.0.1:42201` | `127.0.0.1:42202` |

Useful diagnostics:

```bash
curl -fsS http://127.0.0.1:42199/__relay/health
curl -fsS http://127.0.0.1:42201/__relay/health
```

## Import Accounts By API

```bash
curl -s -X POST http://127.0.0.1:42199/__relay/accounts \
  -H 'content-type: application/json' \
  -d '{"session_token":"<devin-session-token-or-jwt>","label":"backup"}'
```

The token stays on this Mac. It is stored in:

```text
~/Library/Application Support/com.windsurfswitcher.native/accounts.json
```

Legacy Tauri data can be imported from:

```text
~/Library/Application Support/com.windsurf.switcher/accounts.json
```

## CLI

The package also builds `wss-cli`:

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

## Project Layout

```text
.
├── Package.swift
├── Sources
│   ├── App              SwiftUI MenuBarExtra app and UI state
│   ├── Core             Account model, persistence, protobuf wire helpers
│   ├── External         Legacy cleanup helpers
│   ├── Relay            Local HTTP relays, pool scheduler, response rewriting
│   ├── WindsurfClient   GetOTT, GetPlanStatus, JWT decoding
│   ├── Wrapper          Language-server wrapper installer
│   └── WSSCLI           Command-line maintenance tool
├── Tests
└── scripts
    ├── build-app.sh
    └── build-dmg.sh
```

## Notes

- `GetUserStatus` 401 does not reliably cause Windsurf to re-auth. This app uses
  `StartCascade` as a soft trigger for fresh `GetUserJwt` requests.
- Stable and Next are intentionally scoped separately in the relay manager, so
  switching or quota events in one app do not overwrite the other's active JWT.
- Quota refresh is defensive: before rotating to a new JWT candidate, the app
  refreshes that account and requires usable quota.
