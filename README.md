# Codeg iOS 分支 / Codeg iOS Fork

`codeg-ios-fork` 基于 [xintaofei/codeg-ios](https://github.com/xintaofei/codeg-ios)，由 **PanAndDuck** 修改，遵循 [Apache-2.0](LICENSE)。
This fork is based on **xintaofei/codeg-ios**, with modifications by **PanAndDuck**, under **Apache-2.0**; upstream attribution is retained in [NOTICE](NOTICE).

- **远程中继 / Remote relay:** QR/paste pairing, TLS certificate pinning and trust on first use (TOFU), fast LAN → relay failover, and custom headers.
- **稳定流式回复 / Resilient streaming:** large snapshots, liveness checks and NWPathMonitor, unlimited reconnect attempts, sequence-based recovery, and finish-during-gap reconciliation.
- **长对话 / Long transcripts:** transcript windows and older-page loading with a stable reading anchor.
- **错误提示 / Error mapping:** actionable English and Simplified Chinese network, relay, authentication, and attachment errors.
- **智能体兼容 / Agent compatibility:** custom and unknown agent types retain their server identities.
- **无文件夹聊天 / Folderless chat:** start and manage chats without selecting a project folder.
- **并行安装与测试 / Side-by-side builds and tests:** isolated Codeg-Fork flavor, XCTest suite, and optional UI-test target.

**服务端兼容 / Server compatibility:** 标准 codeg 支持局域网与基础功能；中继配对需要带内置 relay client、支持 `/__codeg_relay/v1` 协议的 codeg 服务端，例如 [codeg-fork](https://github.com/PanAndDuck/codeg-fork)（提供各平台安装包和 `codeg-relay` 中继服务端）。
Stock codeg works for LAN/basic features. Relay pairing requires a codeg server with the built-in relay client implementing the `/__codeg_relay/v1` protocol, such as [codeg-fork](https://github.com/PanAndDuck/codeg-fork) (desktop/server packages plus the `codeg-relay` server). Optional features depend on the server's API support.

**构建 / Build:** 使用 Xcode 26、iOS 26 SDK、[XcodeGen](https://github.com/yonaskolb/XcodeGen) 与 Python 3。签名配置从示例复制并填写自己的 Team ID；已有本地配置时保留它。
Use Xcode 26, the iOS 26 SDK, XcodeGen, and Python 3. Copy the signing example if no local override exists, then enter your own team ID for signed device builds. Simulator builds do not require signing.

```bash
cp Config/Signing.local.xcconfig.example Config/Signing.local.xcconfig
xcodegen generate
scripts/build-fork.sh sim --name "iPhone 17"
scripts/build-fork.sh test --name "iPhone 17"
scripts/build-fork.sh generic-device
# Optional physical-device build, installation, and launch:
scripts/build-fork.sh device --device "<device-name>"
```

`sim` 会构建、启动模拟器并安装运行；`generic-device` 只构建和验证签名。请使用本机已有的模拟器名称。
`sim` builds, boots, installs, and launches; `generic-device` builds and verifies signing without installation. Use an available simulator name. See the [fork user/developer guide](docs/FORK.md) for setup, pairing, tests, and troubleshooting.

---

以下保留上游 README / Original upstream README follows.

# Codeg for iOS

A native, universal (iPhone + iPad) SwiftUI client for the [codeg](https://github.com/xintaofei/codeg)
multi-agent coding server. Manage your codeg servers, browse their sessions, read
the full transcript, and reply to the agent with the response streaming back in
real time. Built for iOS 26 with Apple's **Liquid Glass** design language and a
dark, developer-focused aesthetic.

The app is a **pure API client** — all agent and conversation logic lives on the
codeg backend; the app only calls its HTTP + WebSocket API.

## Phase 1 features

- **Server management** — add / edit / delete codeg servers (URL + token), with a
  live connection-status check (`/api/health`). Tokens are stored in the Keychain.
- **Session list** — conversations for a server with folder filter chips, search,
  agent-type and status badges, model, and message counts.
- **Session detail** — the full transcript: user/assistant/system turns, markdown,
  reasoning, tool calls + results, images, and token-usage stats.
- **Compose + live streaming** — send a prompt and watch the agent reply stream in
  token-by-token over the WebSocket, with live tool-call status.

## Requirements

- Xcode 26 / iOS 26 SDK
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) — the
  Xcode project is generated from `project.yml`

## Build & run

Simulator builds do not require an Apple Developer account:

```bash
xcodegen generate            # regenerate CodegiOS.xcodeproj from project.yml
open CodegiOS.xcodeproj
```

For a physical device or archive, create the ignored local signing override
before generating the project:

```bash
cp Config/Signing.local.xcconfig.example Config/Signing.local.xcconfig
# Edit Signing.local.xcconfig and replace YOUR_TEAM_ID.
xcodegen generate
```

Or from the command line (simulator):

```bash
xcodebuild -project CodegiOS.xcodeproj -scheme CodegiOS \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' \
  -skipMacroValidation build
```

> Run the app in Xcode with your development team selected so it is code-signed —
> the Keychain (used for tokens) requires the app's `application-identifier`
> entitlement. Unsigned CLI/simulator builds transparently fall back to a
> UserDefaults token store (simulator only) so the app stays usable.

## Releasing

Cutting a release is one command:

```bash
scripts/release.sh patch          # 1.0.0 -> 1.0.1 (build auto-increments)
scripts/release.sh minor          # 1.0.0 -> 1.1.0
scripts/release.sh 1.2.0          # set an explicit version
```

It bumps `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `project.yml` (the
single source of truth for the version), regenerates the project, commits, tags
`vX.Y.Z`, pushes, and creates a GitHub Release.

**Version notes** live in [`CHANGELOG.md`](CHANGELOG.md): jot changes under
`## [Unreleased]` as you work. On release, that section is promoted to a
`## [X.Y.Z]` heading and reused verbatim as the git tag message and the GitHub
Release notes. Override the notes ad hoc with `--notes "…"`; if both are empty
the script opens `$EDITOR`.

Useful flags:

```bash
scripts/release.sh patch --dry-run   # print every step, change nothing
scripts/release.sh patch --yes       # skip the confirmation prompt
scripts/release.sh minor --archive   # also archive + upload to App Store Connect
```

`--archive` runs `xcodebuild archive`/`-exportArchive` (via
[`scripts/ExportOptions.plist`](scripts/ExportOptions.plist)) and, when an App
Store Connect API key is present, uploads the `.ipa`. This happens **before** the
tag and GitHub Release are published, so a signing/export/upload failure aborts
with nothing committed or pushed (the script prints how to discard the bump).
Provide the key via environment variables:

```bash
export CODEG_DEVELOPMENT_TEAM=XXXXXXXXXX # optional if local signing config exists
export ASC_KEY_ID=XXXXXXXXXX          # the App Store Connect API Key ID
export ASC_ISSUER_ID=xxxxxxxx-xxxx-…  # the Issuer ID
export ASC_KEY_PATH=~/AuthKey_XXXXXXXXXX.p8
```

Without them the archive step still exports a local `.ipa` (upload it via
Transporter.app). `altool` uploads only the binary — the App Store "What's New"
text is saved to `build/release-notes-vX.Y.Z.txt` for you to paste into App
Store Connect. To automate that text too, graduate `--archive` to Fastlane
[`deliver`](https://docs.fastlane.tools/actions/deliver/).

## Connecting to a server

1. Start a codeg server (`CODEG_PORT` default `3080`). It prints a `CODEG_TOKEN`
   to stderr on startup.
2. In the app, tap **+**, enter a name, the server URL (e.g. `http://192.168.1.10:3080`),
   and the token. Use **Test Connection** to validate, then **Save**.

## Architecture

```
CodegiOS/
  App/            App entry, AppModel (selection state), RootView (NavigationSplitView)
  Models/         Codable wire models (AgentType, Conversation, Message, AcpEvent)
  Networking/     CodegClient (HTTP), EventStream (WebSocket), JSON coding, errors
  Persistence/    ServerProfile, Keychain, ServerStore (Observable)
  DesignSystem/   Liquid Glass components, theme tokens, badges, state views
  Features/       Servers, Sessions, SessionDetail (each: View + @Observable model)
```

Key contract details handled by the networking layer:

- **Mixed JSON casing** — requests are camelCase, responses are snake_case
  (`JSONDecoder.keyDecodingStrategy = .convertFromSnakeCase`; encoder keeps keys).
- **Auth** — HTTP `Authorization: Bearer <token>`; WebSocket auth via the
  `codeg-token.<base64url-no-pad>` subprotocol.
- **Streaming** — `acp_connect` → WS attach (awaiting snapshot confirmation) →
  `acp_prompt` → consume `content_delta` / `tool_call` / `turn_complete` events.

The three-column `NavigationSplitView` (servers | sessions | detail) collapses to
a navigation stack on iPhone.

## License

Codeg for iOS is licensed under the [Apache License 2.0](LICENSE). Third-party
license notices are collected in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Product and service names used by the app identify compatible integrations.
Their trademarks belong to their respective owners; no endorsement or
affiliation is implied.
