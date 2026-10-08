#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'EOF'
Usage: scripts/build-fork.sh <command> [options]
  sim [--name "iPhone 17"]     Build, boot, install and launch on a simulator
  test [--name "iPhone 17"]    Run CodegiOSTests on a simulator
  generic-device              Build and sign for generic/platform=iOS; no install
  device [--device "<device-name>"]     Build, install and launch on the named physical device

Signing and the optional CODEG_BUNDLE_ID_SUFFIX come from
Config/Signing.local.xcconfig. See docs/FORK.md.
EOF
}

COMMAND="${1:-}"
case "$COMMAND" in
  -h|--help) usage; exit 0 ;;
  sim|test|device|generic-device) shift ;;
  *) usage; die "choose sim, test, device, or generic-device" ;;
esac
SIM_NAME="iPhone 17"
DEVICE_NAME="<device-name>"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)
      [[ "$COMMAND" == sim || "$COMMAND" == test ]] || die "--name requires sim or test"
      [[ $# -ge 2 && -n "$2" ]] || die "--name requires a simulator name"
      SIM_NAME="$2"; shift 2 ;;
    --device)
      [[ "$COMMAND" == device ]] || die "--device requires device"
      [[ $# -ge 2 && -n "$2" ]] || die "--device requires a device name or identifier"
      DEVICE_NAME="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
for tool in xcodegen xcodebuild xcrun python3 git; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
done

mkdir -p "$ROOT/build/fork"
WORK_DIR="$(mktemp -d "$ROOT/build/fork/tmp.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

BUILD_ARGS=(-project CodegiOS.xcodeproj -scheme CodegiOS -configuration Debug
  -skipMacroValidation
  CODEG_DISPLAY_NAME=Codeg-Fork
  'CODEG_BUNDLE_ID=app.codeg.ios.fork$(CODEG_BUNDLE_ID_SUFFIX)'
  CODEG_URL_SCHEME=codegfork CODEG_FLAVOR=fork
  "CODEG_BUILD_COMMIT=$(git rev-parse --short HEAD)")
ACTION=build

case "$COMMAND" in
  sim|test)
    xcrun simctl list devices available --json > "$WORK_DIR/simulators.json"
    SIM_ID="$(python3 - "$WORK_DIR/simulators.json" "$SIM_NAME" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    devices = json.load(f)["devices"]
matches = [d for group in devices.values() for d in group
           if d.get("isAvailable") and d["name"] == sys.argv[2]]
if len(matches) != 1:
    sys.exit(f"error: expected one available simulator named {sys.argv[2]!r}, found {len(matches)}. Check xcrun simctl list devices available.")
print(matches[0]["udid"])
PY
)"
    DERIVED_DATA="$ROOT/build/fork/simulator"
    SDK=iphonesimulator
    BUILD_ARGS+=(-destination "platform=iOS Simulator,id=$SIM_ID" CODE_SIGNING_ALLOWED=NO)
    if [[ "$COMMAND" == test ]]; then
      ACTION=test
      BUILD_ARGS+=(-parallel-testing-enabled NO)
    fi
    ;;
  device|generic-device)
    DERIVED_DATA="$ROOT/build/fork/device"
    SDK=iphoneos
    BUILD_ARGS+=(-allowProvisioningUpdates CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES)
    if [[ "$COMMAND" == device ]]; then
      xcrun devicectl list devices --timeout 15 --json-output "$WORK_DIR/devices.json" >/dev/null \
        || die "could not list devices; connect/unlock '$DEVICE_NAME' and check Xcode Devices and Simulators"
      DEVICE_ID="$(python3 - "$WORK_DIR/devices.json" "$DEVICE_NAME" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    devices = json.load(f).get("result", {}).get("devices", [])
matches = []
for d in devices:
    hardware = d.get("hardwareProperties", {})
    properties = d.get("deviceProperties", {})
    if hardware.get("reality") == "simulated":
        continue
    if sys.argv[2] in (properties.get("name"), hardware.get("udid"), d.get("identifier")):
        matches.append(d)
if len(matches) != 1 or matches[0].get("connectionProperties", {}).get("tunnelState") == "unavailable":
    sys.exit(f"error: device {sys.argv[2]!r} is unavailable or ambiguous. Connect/unlock it, enable Developer Mode and check Xcode Devices and Simulators.")
device = matches[0]
udid = device.get("hardwareProperties", {}).get("udid")
if not udid:
    sys.exit("error: device has no iOS UDID; check pairing in Xcode Devices and Simulators")
print(udid)
PY
)"
      xcrun devicectl device info details --device "$DEVICE_ID" --timeout 15 >/dev/null \
        || die "device '$DEVICE_NAME' is unavailable; connect/unlock it and check pairing in Xcode"
      BUILD_ARGS+=(-destination "platform=iOS,id=$DEVICE_ID" -destination-timeout 15)
    else
      BUILD_ARGS+=(-destination 'generic/platform=iOS')
    fi
    ;;
esac

xcodegen generate
xcodebuild "${BUILD_ARGS[@]}" -derivedDataPath "$DERIVED_DATA" "$ACTION" \
  || die "fork $COMMAND failed; see xcodebuild output above (for signing, check Signing.local.xcconfig and the existing Apple ID session in Xcode)"

APP_PATH="$DERIVED_DATA/Build/Products/Debug-$SDK/Codeg.app"
# Validate the actual artifact before any explicit install or launch. A stale
# official build must never be installed by this script.
BUNDLE_ID="$(python3 - "$APP_PATH/Info.plist" <<'PY'
import plistlib, re, sys
with open(sys.argv[1], "rb") as f:
    info = plistlib.load(f)
bundle_id = info["CFBundleIdentifier"]
schemes = [s for t in info.get("CFBundleURLTypes", []) for s in t.get("CFBundleURLSchemes", [])]
if (not re.fullmatch(r"app\.codeg\.ios\.fork(?:\.[A-Za-z0-9-]+)*", bundle_id)
        or info.get("CFBundleDisplayName") != "Codeg-Fork"
        or info.get("CodegFlavor") != "fork" or schemes != ["codegfork"]
        or not info.get("CodegBuildCommit")):
    sys.exit("error: built app does not have the expected isolated fork identity; refusing install/launch")
print(bundle_id)
PY
)"
printf '\nApp: %s\nBundle ID: %s\n' "$APP_PATH" "$BUNDLE_ID"

case "$COMMAND" in
  sim)
    # bootstatus -b boots a shut-down simulator and waits until it is ready.
    xcrun simctl bootstatus "$SIM_ID" -b
    xcrun simctl install "$SIM_ID" "$APP_PATH"
    xcrun simctl launch "$SIM_ID" "$BUNDLE_ID"
    ;;
  device)
    xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH" \
      || die "could not install on '$DEVICE_NAME'; confirm the device is connected and unlocked"
    xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID" \
      || die "installed fork but could not launch it on '$DEVICE_NAME'; check Developer Mode and device trust"
    ;;
  generic-device)
    codesign --verify --deep --strict "$APP_PATH"
    printf 'Signed generic-device build verified; no device installation performed.\n'
    ;;
esac
