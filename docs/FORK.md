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

All sessions retain `waitsForConnectivity`. An exact “Waiting for network…”
indicator needs `URLSessionTaskDelegate`'s waiting callback; it is deferred to
the session-factory/TLS work rather than adding another delegate here. TLS
pinning can add `APIError.untrustedCertificate(fingerprint:)` beside `.tls`;
`fromTransport(_:)` preserves typed errors and `isTransient` defaults to false
for new cases.

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

The server QR scanner accepts version 1 pairing JSON (`v`, `mode`, `url`,
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
Changing editor fields clears stale probe results. Imported QR pins are staged
with the other fields and saved together.

`SessionFactory.sessions(for:)` caches a `Sessions` bundle by profile UUID and
URL/pin. `Sessions[.standard/.read/.probe/.install/.stream]` retains the existing
timeouts, with a `TrustEvaluator` for that origin. `ServerStore` invalidates the
bundle on URL/pin changes or deletion; `finishTasksAndInvalidate` drains active
tasks. Stateful views refresh on trust-policy changes. Editor probes use a
separate factory. Every HTTP request uses its own task evaluator so a rejected
fingerprint is attributed to that request; WebSockets use the session delegate.
Unpinned requests retain system trust. Matching pins accept self-signed leaf
certificates; mismatches always reject. Pinned redirects cannot leave the HTTPS
origin or downgrade to HTTP.

Run pure/migration/QR tests with `scripts/build-fork.sh test`. To exercise real
HTTPS, status checks, TOFU, replacement, and event/terminal WSS:

```bash
scripts/test-pinning.sh
```

This generates an ephemeral certificate under `build/fork`, starts a Python
TLS fixture on **127.0.0.1:18455**, and runs the fork Simulator tests. The EXIT
trap stops only its recorded Python process and removes the certificate, key,
fixture resource and temporary data directories. Integration cases skip when
the generated fixture resource is absent. No codeg server or physical device
is used.
