#!/usr/bin/env bash
unset CODEG_DATA_DIR CODEG_HOME CODEG_STATIC_DIR CODEG_ACP_TMP_ROOT CODEG_TOKEN CODEG_PORT CODEG_HOST
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/fork
fixture_json="$PWD/CodegiOSTests/LocalTLSFixture.json"
[[ ! -e "$fixture_json" ]] || { echo "Existing TLS fixture; refusing to overwrite" >&2; exit 1; }
fixture_dir="$(mktemp -d "$PWD/build/fork/tls.XXXXXX")"
fixture_pid=""
cleanup() {
  if [[ -n "$fixture_pid" ]]; then
    # Only stop the exact Python fixture process started below.
    if [[ "$(ps -p "$fixture_pid" -o command=)" == *"$PWD/scripts/pinning-test-server.py"* ]]; then
      kill "$fixture_pid"
      wait "$fixture_pid" 2>/dev/null || true
    fi
  fi
  rm -f "$fixture_json"
  # Xcode may otherwise keep a removed resource in an incremental test bundle.
  rm -f build/fork/simulator/Build/Products/Debug-iphonesimulator/Codeg.app/PlugIns/CodegiOSTests.xctest/LocalTLSFixture.json
  rm -f build/fork/simulator/Build/Products/Debug-iphonesimulator/CodegiOSTests.xctest/LocalTLSFixture.json
  rm -rf "$fixture_dir"
}
trap cleanup EXIT
export CODEG_DATA_DIR="$fixture_dir/data" CODEG_HOME="$fixture_dir/home"
mkdir -p "$CODEG_DATA_DIR" "$CODEG_HOME"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=localhost' \
  -addext 'subjectAltName=IP:127.0.0.1' -keyout "$fixture_dir/key.pem" -out "$fixture_dir/cert.pem" >/dev/null 2>&1
python3 - "$fixture_dir/cert.pem" "$fixture_json" <<'PY'
import hashlib, json, ssl, sys
with open(sys.argv[1]) as f:
    der = ssl.PEM_cert_to_DER_cert(f.read())
with open(sys.argv[2], 'w') as f:
    json.dump({'url': 'https://127.0.0.1:18455', 'fingerprint': hashlib.sha256(der).hexdigest()}, f)
PY
python3 "$PWD/scripts/pinning-test-server.py" 18455 "$fixture_dir/cert.pem" "$fixture_dir/key.pem" "$fixture_dir/ready" > "$fixture_dir/server.log" 2>&1 &
fixture_pid=$!
python3 - "$fixture_pid" "$fixture_dir/ready" <<'PY'
import os, pathlib, sys, time
for _ in range(50):
    os.kill(int(sys.argv[1]), 0)
    if pathlib.Path(sys.argv[2]).exists():
        break
    time.sleep(.1)
else:
    raise SystemExit('TLS fixture did not start')
PY
scripts/build-fork.sh test "$@"
