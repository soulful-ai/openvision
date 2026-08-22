#!/usr/bin/env bash
# AUR-818b — ship the iOS client in the mode the moment calls for (Anton's ruling 2026-08-21:
# "two modes — if I'm home, update over Wi-Fi; if away, OTA link in Telegram"):
#   HOME mode  — Anton's iPhone is on the Mini's network (devicectl tunnel connected) → build for the
#                device + `devicectl device install app` over Wi-Fi. No link, no Safari, no tap.
#   AWAY mode  — phone not reachable (away / locked / unavailable) or the install fails → fall back to
#                scripts/ota-release.sh (archive → GCS signed URLs → Telegram link, runbook §11).
# Usage: scripts/ship-client.sh [--wifi | --ota]     (no flag = auto-detect; --wifi/--ota force a mode)
# Env: SHIP_UDID (default Anton's iPhone; set it explicitly to target Margo's) · SHIP_DD (.dd) ·
#      SHIP_SKIP_BUILD=1 (reuse .dd app)
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
UDID=${SHIP_UDID:-00008140-000535203682801C}     # default: Anton's iPhone 16e. Margo's phone is never the
# DEFAULT, but SHIP_UDID targets it deliberately when asked (2026-08-21, 2026-08-22). Name the phone we
# are ACTUALLY shipping to: the messages used to say "Anton's iPhone" whatever SHIP_UDID said, which
# reads as a wrong-device install in the log long after the fact.
case $UDID in
  00008140-000535203682801C) WHO="Anton's iPhone" ;;
  00008120-000268AE22EBC01E) WHO="Margo's iPhone" ;;
  *)                         WHO="$UDID" ;;
esac
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

# AUR-845b — portal auth for `-allowProvisioningUpdates`. The app signs against the EXPLICIT App ID
# (app.soulless.openvision, 4DUB6L4475) now that it carries entitlements, and fetching that profile
# needs the developer portal. xcodebuild has no way in: with no Apple ID in Xcode's Accounts it
# fails with "error: No Accounts: Add a new account in Accounts settings" and then falls back to a
# CACHED profile — which is the wildcard, which carries no capabilities, so the build dies on the
# wifi-info key and the error reads as if the portal work was never done. The App Store Connect API
# key is the headless way in. Absent (fresh machine) we simply do not pass the flags: a cached
# explicit profile can still satisfy the build, and if it cannot, the build error says so plainly.
ASC_KEY=${ASC_KEY:-$HOME/.private_keys/AuthKey_6MU7DYSFH7.p8}
ASC_KEY_ID=${ASC_KEY_ID:-6MU7DYSFH7}
ASC_ISSUER_ID=${ASC_ISSUER_ID:-be177da0-1e8f-46af-bd33-f243f86f793a}
AUTH=()
if [[ -f $ASC_KEY ]]; then
  AUTH=(-authenticationKeyPath "$ASC_KEY" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
else
  echo "  note: no ASC API key at $ASC_KEY — provisioning updates will use cached profiles only"
fi

# Reachability, two steps: (1) devicectl's JSON says the phone is listed + paired (its tunnelState
# reads "disconnected" between commands — the tunnel is established on demand, so it is NOT the
# reachability truth; measured 2026-08-21: "disconnected" in the list, then `install app` landed);
# (2) a cheap real round-trip (`device info details`, 45 s cap) — that IS the truth.
reachable() {
  local j=$OTA/devices.json
  timeout 60 xcrun devicectl list devices --json-output "$j" >/dev/null 2>&1 || return 1
  UDID="$UDID" python3 - "$j" <<'PY' || return 1
import json, os, sys
want = os.environ["UDID"]
for d in json.load(open(sys.argv[1]))["result"]["devices"]:
    if d.get("hardwareProperties", {}).get("udid") == want:
        cp = d.get("connectionProperties", {})
        print(f"  {d.get('deviceProperties',{}).get('name','?')} listed: tunnel={cp.get('tunnelState')} pairing={cp.get('pairingState')} transport={cp.get('transportType')}")
        sys.exit(0 if cp.get("pairingState") == "paired" else 1)
print("  device not listed"); sys.exit(1)
PY
  if timeout 45 xcrun devicectl device info details --device "$UDID" >"$OTA/ship-probe.log" 2>&1; then
    echo "  round-trip ok (device info details)"; return 0
  fi
  echo "  round-trip failed (away / asleep off-network / locked) — see $OTA/ship-probe.log"; return 1
}

away() { log "AWAY mode: OTA link via scripts/ota-release.sh ($1)"; exec bash "$ROOT/scripts/ota-release.sh"; }

if [[ $MODE == ota ]]; then away "--ota forced"; fi

log "probe $UDID ($WHO)"
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
    -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"} -skipPackagePluginValidation -skipMacroValidation 2>&1 \
    | tee "$OTA/ship-build.log" | grep -E 'error:|Provisioning Profile:|\*\* BUILD'
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
  log "HOME mode: installed over Wi-Fi ($SHA → $WHO)"
  exit 0
fi
echo "✗ install failed (rc=$rc; locked / unreachable / trust) — see $OTA/ship-install.log"
[[ $MODE == wifi ]] && exit 1
away "install failed"
