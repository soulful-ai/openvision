#!/usr/bin/env bash
# AUR-818b — ship the iOS client in the mode the moment calls for (Anton's ruling 2026-08-21:
# "two modes — if I'm home, update over Wi-Fi; if away, OTA link in Telegram"):
#   HOME mode  — Anton's iPhone is on the Mini's network (devicectl tunnel connected) → build for the
#                device + `devicectl device install app` over Wi-Fi. No link, no Safari, no tap.
#   AWAY mode  — phone not reachable (away / locked / unavailable) or the install fails → fall back to
#                scripts/ota-release.sh (archive → GCS signed URLs → Telegram link, runbook §11).
# Usage: scripts/ship-client.sh [--wifi | --ota]     (no flag = auto-detect; --wifi/--ota force a mode)
# Env: SHIP_UDID (default Anton's iPhone — NEVER Margo's) · SHIP_DD (.dd) · SHIP_SKIP_BUILD=1 (reuse .dd app)
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
UDID=${SHIP_UDID:-00008140-000535203682801C}     # Anton's iPhone 16e; Margo's phone is never a target here
DD=${SHIP_DD:-$ROOT/.dd}
APP=$DD/Build/Products/Debug-iphoneos/OpenVision.app
OTA=$ROOT/.ota; mkdir -p "$OTA"
MODE=auto
case ${1:-} in
  --wifi) MODE=wifi ;;
  --ota)  MODE=ota ;;
  "") ;;
  *) echo "usage: $0 [--wifi|--ota]"; exit 2 ;;
esac
log() { printf '\n▸ %s\n' "$*"; }
SHA=$(git rev-parse --short HEAD)

# Reachability: devicectl's JSON, the one field that means "I can push bytes now" = tunnelState=connected.
reachable() {
  local j=$OTA/devices.json
  timeout 60 xcrun devicectl list devices --json-output "$j" >/dev/null 2>&1 || return 1
  UDID="$UDID" python3 - "$j" <<'PY'
import json, os, sys
want = os.environ["UDID"]
for d in json.load(open(sys.argv[1]))["result"]["devices"]:
    if d.get("hardwareProperties", {}).get("udid") == want:
        cp = d.get("connectionProperties", {})
        ok = cp.get("tunnelState") == "connected" and cp.get("pairingState") == "paired"
        print(f"  {d.get('deviceProperties',{}).get('name','?')} tunnel={cp.get('tunnelState')} pairing={cp.get('pairingState')} transport={cp.get('transportType')}")
        sys.exit(0 if ok else 1)
print("  device not listed"); sys.exit(1)
PY
}

away() { log "AWAY mode: OTA link via scripts/ota-release.sh ($1)"; exec bash "$ROOT/scripts/ota-release.sh"; }

if [[ $MODE == ota ]]; then away "--ota forced"; fi

log "probe $UDID (Anton's iPhone)"
if reachable; then REACH=1; else REACH=0; fi
if (( ! REACH )); then
  [[ $MODE == wifi ]] && { echo "✗ --wifi forced but the phone is not reachable (away / locked / not on this network)"; exit 1; }
  away "phone not reachable"
fi

# 1. build for the device (Debug, dev-signed) — the same build the device tests use
if [[ ${SHIP_SKIP_BUILD:-0} == 1 && -d $APP ]]; then
  log "skip build — reusing $APP"
else
  log "xcodebuild build → id=$UDID (derivedData $DD)"
  set +e
  xcodebuild build -project OpenVision.xcodeproj -scheme OpenVision -destination "id=$UDID" -derivedDataPath "$DD" \
    -allowProvisioningUpdates -skipPackagePluginValidation -skipMacroValidation 2>&1 | tee "$OTA/ship-build.log" | grep -E 'error:|\*\* BUILD'
  rc=${PIPESTATUS[0]}; set -e
  if (( rc != 0 )); then
    echo "✗ device build failed (rc=$rc) — see $OTA/ship-build.log"
    [[ $MODE == wifi ]] && exit "$rc"
    away "device build failed"
  fi
fi

# 2. install over Wi-Fi (phone awake + unlocked; devicectl says "App installed:" on success)
log "devicectl install → $UDID"
set +e
timeout 180 xcrun devicectl device install app --device "$UDID" "$APP" 2>&1 | tee "$OTA/ship-install.log" | grep -E 'App installed:|ERROR|error'
rc=${PIPESTATUS[0]}; set -e
if (( rc == 0 )) && grep -q 'App installed:' "$OTA/ship-install.log"; then
  log "HOME mode: installed over Wi-Fi ($SHA → Anton's iPhone)"
  exit 0
fi
echo "✗ install failed (rc=$rc; locked / unreachable / trust) — see $OTA/ship-install.log"
[[ $MODE == wifi ]] && exit 1
away "install failed"
