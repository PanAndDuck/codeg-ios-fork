# Codeg-Fork for iOS

The fork installs alongside App Store Codeg (`app.codeg.ios`) and personal dev
builds such as `app.codeg.ios.devyourname`. It uses a separate app container,
UserDefaults domain and default Keychain access group.

| Build setting | Official default | `scripts/build-fork.sh` |
| --- | --- | --- |
| `CODEG_DISPLAY_NAME` | `Codeg` | `Codeg-Fork` |
| `CODEG_BUNDLE_ID` | `app.codeg.ios` | `app.codeg.ios.fork$(CODEG_BUNDLE_ID_SUFFIX)` |
| `CODEG_URL_SCHEME` | `codeg` | `codegfork` |
| `CODEG_FLAVOR` | `official` | `fork` |
| `CODEG_BUILD_COMMIT` | empty | `git rev-parse --short HEAD` |

`project.yml` supplies official defaults. XcodeGen writes build-setting
references to `Info.plist`; the fork script passes overrides only to its
`xcodebuild` invocation. Running the script does not change official defaults
or persist fork values in the generated project. `CodegFlavor` and
`CodegBuildCommit` identify the build at runtime; About displays
`Codeg-Fork · <short SHA>` for a fork. The SHA identifies HEAD at build time;
commit local changes before producing a build for review.

`PRODUCT_NAME` and the Swift module remain `Codeg`; the artifact is `Codeg.app`.
`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` remain single-sourced in
`project.yml`, so `scripts/release.sh` continues to produce official releases.
Do not use that release script to publish test builds.

## Setup

Install Xcode with the iOS simulator runtime, XcodeGen and Python 3. Simulator
builds need no signing account. For device signing, use an existing Xcode Apple
ID session and create the ignored local override:

```bash
cp Config/Signing.local.xcconfig.example Config/Signing.local.xcconfig
```

If the file already exists, edit it instead of replacing it. This machine uses:

```xcconfig
CODEG_DEVELOPMENT_TEAM = YOUR_TEAM_ID
CODEG_BUNDLE_ID_SUFFIX = .yourname
```

Other developers should use their own team and a unique dot-prefixed suffix.
Without a suffix, the fork bundle id is `app.codeg.ios.fork`. The suffix affects
only the fork script. Never commit `Config/Signing.local.xcconfig`, signing
certificates or provisioning profiles.

## Build, run and test

Run these commands from the repository (the script also works from other
directories):

```bash
scripts/build-fork.sh sim
scripts/build-fork.sh sim --name "iPhone 18 Pro"
scripts/build-fork.sh test
scripts/build-fork.sh test --name "iPhone 17"
scripts/build-fork.sh generic-device
```

Every build regenerates the project and passes `-skipMacroValidation`.
`sim` resolves an exact available simulator name, builds, boots, installs and
launches only the fork. `test` runs `CodegiOSTests` on that simulator without
parallel simulator clones. Both disable code signing. `generic-device` enables
signing and `-allowProvisioningUpdates` for `generic/platform=iOS`, verifies the
signature, and does not install anything. If signing fails, resolve the reported
team/provisioning or Apple ID issue before retrying.

For a later, explicitly authorized phone install:

```bash
scripts/build-fork.sh device --device "<device-name>"
```

This command checks physical-device availability, builds for that device with
automatic provisioning, installs via `devicectl` and launches the fork bundle
id. It fails with an actionable message if the device is missing, disconnected
or cannot be used. The default device name is `<device-name>`. I0 validation uses only
simulators and the generic-device build; it does not run a phone installation.

Builds print the actual `.app` path and bundle id. Outputs are kept separately:

- Simulator and XCTest: `build/fork/simulator/Build/Products/Debug-iphonesimulator/Codeg.app`
- Device and generic-device: `build/fork/device/Build/Products/Debug-iphoneos/Codeg.app`

For an official simulator build, do not supply flavor overrides and use a
different DerivedData directory:

```bash
xcodegen generate
xcodebuild -project CodegiOS.xcodeproj -scheme CodegiOS \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath build/official -skipMacroValidation build
```

The resulting display name, bundle id and URL scheme are `Codeg`, `app.codeg.ios`
and `codeg`. No official build is installed by `build-fork.sh`.

## Network errors and request timeouts

The client distinguishes cancellation, timeout, offline access, interrupted
connections, unreachable hosts and TLS failures. Common relay responses and
oversized attachments have English and Simplified Chinese guidance. Authentication
rate limits show `retry_after_secs`, falling back to the numeric `Retry-After`
header when needed. Rate limits are not retried by the short network retry loop.

`APIError.userMessage(_:)` returns no message for cancellation. Error screens,
notices and settings editors use that rule while keeping their rollback and
loading cleanup. `APIError.debugDescription` retains transport codes and server
status/code/message for diagnosis; it is not automatically logged.

`acp_connect` uses `probeSession` (90s request / 150s resource timeout), allowing
the server's agent resume to take up to 60s. Agent option probes and repository
clones already use this session; installs use 120s / 900s. Normal reads keep
their existing 15s / 60s or 30s / 120s limits.

Single-endpoint HTTP sessions retain `waitsForConnectivity` for ordinary/long
operations. Health/status/editor checks use a separate 5s request/resource
budget with `waitsForConnectivity = false`, so an unreachable server cannot
leave its status spinner waiting silently for 60s. Dual-endpoint sessions
disable connectivity waiting for every kind. Their initial connection budget
is 1.5s for LAN and 5s for Relay; once HTTP body bytes have been sent, the
original response/operation budgets above apply. WebSocket connection budgets
end at `__ready__`; established sockets retain their seven-day session limits
and the existing heartbeat/attach watchdogs. TLS pinning reports
`APIError.untrustedCertificate(fingerprint:)` before general transport mapping;
the fingerprint error is non-transient and localized in English and Chinese.

Active turns keep retrying after a socket closes, including keepalive timeouts.
`EventStream.CloseReason.networkChanged` skips backoff immediately. Recovery
shows typed HTTP failure messages alongside the retry status, including relay
offline responses from discovery or the quiet-turn snapshot probe. Cancellation
does not produce an error message. Explicit HTTP 413/429 prompt rejections
restore the draft instead of entering ambiguous-acceptance recovery.

The error tests use an in-process `URLProtocol` fixture, never a running codeg
server. For parallel tasks, select a dedicated simulator with
`scripts/build-fork.sh test --name <simulator-name>` and use the same name for
`sim`, avoiding concurrent installation of the fork into one simulator.

## Transcript windows

Session detail opens with `get_folder_conversation` and `tailTurns: 60`.
Foreground and post-turn reconciliation refresh from the loaded `fromIndex`.
The server can expand a tail or older page backward to a user-round boundary;
the client uses the returned offsets, never a guessed 60-turn offset.

“Load earlier messages” fetches `get_folder_conversation_turns` with
`beforeIndex` set to the loaded offset and `limit: 60`. A page's
`prefix_hash_before_index` must match the current `prefix_hash`; refreshes
require the same offset and prefix hash. A mismatch refetches the tail.
Servers without window metadata are treated as returning complete history.
Folder lookup runs independently, so a slow or failed folder list cannot
prevent the transcript from appearing.

Reconciliation captures the global turn count and last assistant identity/content
before send or reattach. An idle response with no `in_flight_user_turn_id` can
replace the live reply when the count grows or that assistant row changes, even
at the same count. Unchanged reads retry; after five reads an idle persisted
reply is adopted only if it matches the streamed blocks or no live content needs
preserving. Otherwise the local reply is retained. A running response or empty
assistant placeholder never replaces a nonempty streamed reply. Both post-turn
refresh and missing-connection recovery use the same decision and keep the
window continuity checks.

`ConversationWindowTests`, `SessionWindowLoadTests`, and `TranscriptPagingTests`
cover the wire contract, merge/reset behavior, request sequence, transient
retry, folder failure/stall, late-page rejection, and local-to-network paging.
They use synthetic transcripts and an intercepted `.invalid` host; no live
Codeg account or official server is required.

## Isolation and links

Fork OS links use `codegfork://`, for example `codegfork://tab/settings`.
Official OS links continue to use `codeg://`. In-app content links using
`codeg://` retain their existing meaning; the fork does not register that OS
scheme. The URL type name follows the bundle id as well.

`Keychain.swift` uses service `com.codeg.ios.server-token` without an explicit
shared access group. iOS scopes those items to the app's default signed access
group (team + bundle id); a shared service string alone does not grant another
bundle access ([Apple's access-group documentation](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps)).
There are no Keychain Sharing or App Group entitlements. The
unsigned simulator fallback uses the app's own `UserDefaults.standard` domain.

## Uninstall

Use the **exact fork bundle id printed by the script**, adjusting the suffix for
your machine. To remove only the fork from the selected simulator:

```bash
xcrun simctl uninstall booted app.codeg.ios.fork.yourname
```

If several simulators are booted, replace `booted` with the intended simulator
UDID from `xcrun simctl list devices`. For an authorized physical-device removal:

```bash
xcrun devicectl device uninstall app --device "<device-name>" app.codeg.ios.fork.yourname
```

Deleting Codeg-Fork removes its app container. iOS may retain Keychain items
after uninstall; delete server profiles inside Codeg-Fork first if their saved
tokens should also be removed. Leave `app.codeg.ios` and existing personal dev
bundle ids untouched. Local fork build artifacts can be removed by deleting
this checkout's `build/fork` directory.

## Relay pairing and certificate trust

**Paste pairing code** is available on the welcome screen and in every Add/Edit
Server sheet. Expand it to type a code or tap the system **Paste** button.
SwiftUI `PasteButton` delivers text after the user's tap, without a separate
paste-permission alert or a direct `UIPasteboard` read. The code field hides
credentials. Clipboard import fills the
editor immediately; typed input uses **Import pairing code**. Review the fields
and tap **Save** to persist them; Cancel discards the draft.

Paste, typed input and the server QR scanner share one import path. It accepts
version 1 pairing JSON (`v`, `mode`, `url`,
`token`, optional `fp` and `name`), legacy JSON (`url`/`address`/`server`),
plain URLs and URLs with `?token=`. `fp` is the SHA-256 of the **leaf certificate
DER**, not its public key. Prefixes `sha256/` and `SHA256:`, colons and whitespace
are normalized to 64 lowercase hex characters. Invalid fingerprints reject
the entire import without changing the editor fields. A pin requires HTTPS.

For a self-signed endpoint, **Test Connection** shows the certificate's SHA-256
fingerprint in uppercase colon-separated pairs. After checking it against a
trusted source, tap **Trust this certificate** to stage the pin and retry.
**Save** persists it with the profile. Existing pins appear in a collapsed
disclosure. A different certificate is rejected even if system-trusted;
**Replace pin** displays a separate confirmation before staging the replacement.
Changing editor fields clears stale probe results. Imported pairing pins are staged
with the other fields and saved together.

`SessionFactory.Sessions[.standard/.read/.probe/.install/.stream]` retains the
existing timeouts, with a `TrustEvaluator` for that origin. Editor probes use a
separate factory. Saved servers use a shared `ConnectionTransport` with an
immutable URL/token/headers/session snapshot for each generation. Every HTTP
request uses its own task evaluator so a rejected fingerprint is attributed to
that request; WebSockets use the session delegate. Unpinned requests retain
system trust. Matching pins accept self-signed leaf certificates; mismatches
always reject. Authenticated redirects, including unpinned HTTP, stay on the
same scheme, host and port so proxy credentials cannot leave their origin.

## Custom headers and LAN / Relay failover

Edit Server supports name/value headers such as `CF-Access-Client-Id` and
`CF-Access-Client-Secret`. All values use secure fields and are stored with the
token in one atomic Keychain credentials item. The editor rejects invalid
names, CR/LF/control characters, duplicate names (case insensitive), and
reserved `Authorization`, `Sec-WebSocket-*`, `Host`, `Connection`, `Upgrade`,
and `Content-Length`. The request layer also filters forbidden entries. Headers
apply to every server HTTP command, health probe, and both EventStream and
TerminalSocket upgrade requests. The WebSocket auth subprotocol remains
`codeg-events, codeg-token.<base64url-token>`.

The original `urlString` / `pinnedCertSHA256` remain the primary endpoint.
Optional `secondaryEndpoint` contains its own `urlString` / `pinnedCertSHA256`.
Each pin has the same strict trust and explicit TOFU behavior. Test Connection
has a primary/relay selector, and certificate results belong to that selection.
The primary's LAN/Relay type is editable (legacy profiles default to LAN; relay
pairing sets Relay). A relay code scanned, pasted or typed into an existing LAN
profile first offers to keep LAN and add/replace the secondary, replace primary,
or cancel. Nothing
is changed before that choice; Save persists the draft. Both endpoints must
represent the same codeg server and share its token/custom headers.

`EndpointSelector` is a pure policy core. On startup, an I1 meaningful network
change (regained connectivity or active interface change), the first connectivity
failure, or two consecutive other transport/server failures, `ServerStore`
concurrently probes `POST /api/health`
on both candidates. LAN has a 1.5s total/request budget; Relay has 5s. Probe
sessions do not wait for connectivity. HTTP and WebSocket failure streaks are
separate so a successful HTTP touch cannot mask failed socket upgrades.

Connectivity failures include `cannotConnectToHost`, `cannotFindHost`,
`dnsLookupFailed`, `timedOut`, `networkConnectionLost`, and
`notConnectedToInternet`. Concurrent failures join one selection. A failure
prefers the healthy alternative even if the failing endpoint's health probe
has recovered; a cached Wi-Fi preference cannot send the retry back to the
same failed endpoint. The request awaits selection and transparently retries
once on the selected alternative. Reads may retry after sending; mutations
only retry when no request-body bytes were sent. Already-sent mutations keep
their existing reconciliation/ambiguity handling, preventing duplicate prompts
or agent processes. Caller cancellation and TLS errors never trigger this
retry. Old requests canceled by that specific failover can join it; stale
responses, edits, deletions, and unrelated generation changes cannot authorize
a replay. Initial event-stream attach retries once after `endpoint changed`
before allowing a prompt to be sent.

Healthy primary wins on Wi-Fi. Otherwise healthy secondary wins; primary is
the fallback if it is the only healthy endpoint. When neither is healthy, the
last choice is retained. The result is cached until another trigger; stale
probes from a prior network/configuration cannot overwrite it. Ordinary
401/403/429/validation errors do not cause repeated failover. TLS rejection is
never an implicit trust action. Server rows show the active URL and LAN/Relay
badge; the session navigation header shows the same subtle badge.

Runtime selection does not change profile/view identity. On a switch, the
shared handle publishes fresh clients' connection state and sessions, closes
old event/terminal sockets with `endpoint changed`, then cancels old session
tasks. HTTP task creation is serialized with session invalidation, and removed
server handles reject new requests/sockets. Temporary editor clients do not
invalidate sessions still owned by the editor cache. I2 consumes `.closed` and immediately reconnects with the existing live
turn/cursor. Terminal reconnect keeps the server PTY. In-flight old HTTP
successful results become `connectionLost`; already-sent mutating commands
are never automatically replayed (I2 retains its ambiguous-prompt handling). Terminal
output produced during disconnection still has no replay, as before.

Metadata stays at `codeg.servers.v1`. New optional fields decode safely when
absent: `secondaryEndpoint`, `customHeaders` (names + empty values in JSON),
and `credentialsRevision` (nonsecret view identity revision for secret edits).
Runtime endpoint choice is not persisted. Keychain reads legacy token-only
accounts and migrates them on the next save to `<UUID>.credentials`, then
removes the legacy item. The existing unsigned-Simulator-only fallback remains;
device builds never store these secrets in UserDefaults. Downgrading to a
pre-I6 binary after migration requires re-entering the token; keep current
Keychain items for a later upgrade. No server/database migration is needed.

Run pure/migration/QR tests with `scripts/build-fork.sh test`. To exercise real
HTTPS, status checks, TOFU, replacement, custom headers, redirects, real endpoint
switching, and event/terminal WSS:

```bash
scripts/test-pinning.sh
```

This generates an ephemeral certificate under `build/fork`, starts a Python
TLS fixture on **127.0.0.1:18455** (override with `FORK_TLS_TEST_PORT`), and runs
the fork Simulator tests. The EXIT
trap stops only its recorded Python process and removes the certificate, key,
fixture resource and temporary data directories. Integration cases skip when
the generated fixture resource is absent. No codeg server or physical device
is used.

The clipboard/text adapter (`PairingCodeInput`) takes an import closure and
has no UIKit dependency. Its unit tests exercise the shared QR import path,
relay/direct and legacy formats, atomic fingerprint errors, empty/multiple
paste values and the existing-LAN merge offer. Run them with the regular suite:

```bash
scripts/test-pairing-paste.sh --name F4
```

This helper only runs unit tests and limits console output. For manual smoke,
build with `scripts/build-fork.sh sim --name F4 2>&1 | tail -n 40`, put a synthetic
relay JSON (fake token and 64-hex fingerprint) on the dedicated simulator's
pasteboard using `xcrun simctl pbcopy F4`, open **Paste pairing code**, and capture
the editor with `xcrun simctl io F4 screenshot <path>`. Do not save the synthetic
profile or test its connection. Shut down F4 afterward. Shared UI automation is
owned by E1b/E1c; this task adds no UI-test target.

English and Simplified Chinese pairing strings are in the string catalog,
including shared parser errors rendered with the app's selected display locale.
The Paste button uses the system-provided localized label.
