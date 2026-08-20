#!/usr/bin/env bash
# AUR-818 — OTA install rail: archive → export (development, Xcode-generated manifest)
# → private GCS upload → V4 signed URLs (7 d) → itms-services link + install.html → Telegram push.
# Be water: Apple's own itms-services OTA + xcodebuild's manifest, gcloud's signer; no 3rd-party service.
# Usage: scripts/ota-release.sh [--skip-build]   (reuses .ota/export from the last run for the same SHA)
# Env knobs: OTA_BUCKET (gs://soulless-modules) · OTA_URL_DURATION (7d) · OTA_TELEGRAM_CHAT_ID (fallback 5332687097 = Anton)
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD; OTA=$ROOT/.ota; EXPORT=$OTA/export; ARCHIVE=$OTA/OpenVision.xcarchive
SHA=$(git rev-parse --short HEAD); DATE=$(date +%Y-%m-%d)
# --skip-build re-mints links for the build that IS in .ota/export → label it with that build's SHA, not HEAD
[[ ${1:-} == --skip-build && -f $EXPORT/OpenVision.ipa && -s $OTA/.sha ]] && SHA=$(cat "$OTA/.sha")
BUCKET=${OTA_BUCKET:-gs://soulless-modules}; PREFIX=$BUCKET/ota/openvision/$SHA
DURATION=${OTA_URL_DURATION:-7d}
TEAM=$(sed -nE 's/^DEVELOPMENT_TEAM *= *([A-Z0-9]+).*/\1/p' Config.xcconfig)
BUNDLE=$(sed -nE 's/^PRODUCT_BUNDLE_IDENTIFIER *= *([A-Za-z0-9.-]+).*/\1/p' Config.xcconfig)
[[ -n $TEAM && -n $BUNDLE ]] || { echo "✗ DEVELOPMENT_TEAM / PRODUCT_BUNDLE_IDENTIFIER missing in Config.xcconfig"; exit 1; }
SKIP_BUILD=0; [[ ${1:-} == --skip-build ]] && SKIP_BUILD=1
log() { printf '\n▸ %s\n' "$*"; }
t0=$(date +%s); lap() { local n=$(date +%s); echo "  ⏱ $1: $((n - t0))s"; t0=$n; }
# xcb <log> <grep-pattern> <xcodebuild args…> — full output to log, filtered echo, returns xcodebuild's own status
xcb() { local l=$1 p=$2; shift 2; set +e; xcodebuild "$@" 2>&1 | tee "$l" | grep -E "$p"; local rc=${PIPESTATUS[0]}; set -e; return "$rc"; }

# 0. preflight — bucket reachable (never create buckets), signer works with the active gcloud account
gsutil ls "$BUCKET/" >/dev/null 2>&1 || { echo "✗ $BUCKET not accessible with the active gcloud account — STOP"; exit 1; }
mkdir -p "$OTA"

# 1. archive (generic iOS, automatic dev signing; team + bundle come from Config.xcconfig via the pbxproj)
if (( SKIP_BUILD )) && [[ -f $EXPORT/OpenVision.ipa && -f $EXPORT/manifest.plist && $(cat "$OTA/.sha" 2>/dev/null) == "$SHA" ]]; then
  log "skip build — reusing $EXPORT for $SHA"
else
  log "xcodebuild archive → $ARCHIVE"
  rm -rf "$ARCHIVE" "$EXPORT"
  xcb "$OTA/archive.log" '^\*\* |error:|warning: .*signing' archive -scheme OpenVision -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE" -derivedDataPath "$ROOT/.dd" -allowProvisioningUpdates -skipPackagePluginValidation -skipMacroValidation \
    || { echo "✗ archive failed — see $OTA/archive.log"; exit 1; }
  lap archive

  # 2. export — method=development + manifest dict ⇒ Xcode writes manifest.plist itself (URLs patched below)
  log "xcodebuild -exportArchive (development, manifest) → $EXPORT"
  cat >"$OTA/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>development</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$TEAM</string>
  <key>compileBitcode</key><false/>
  <key>thinning</key><string>&lt;none&gt;</string>
  <key>destination</key><string>export</string>
  <key>manifest</key><dict>
    <key>appURL</key><string>https://PLACEHOLDER/OpenVision.ipa</string>
    <key>displayImageURL</key><string>https://PLACEHOLDER/icon57.png</string>
    <key>fullSizeImageURL</key><string>https://PLACEHOLDER/icon512.png</string>
  </dict>
</dict></plist>
EOF
  xcb "$OTA/export.log" 'EXPORT|error:' -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OTA/ExportOptions.plist" \
    -exportPath "$EXPORT" -allowProvisioningUpdates \
    && [[ -f $EXPORT/OpenVision.ipa && -f $EXPORT/manifest.plist ]] || { echo "✗ export failed — see $OTA/export.log"; exit 1; }
  echo "$SHA" >"$OTA/.sha"; lap export
fi
echo "  ipa: $(du -h "$EXPORT/OpenVision.ipa" | cut -f1)"

# 3. icons for the install sheet (sips from the 1024 app icon; tiny, uploaded alongside)
ICON=OpenVision/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
sips -z 57 57 "$ICON" --out "$EXPORT/icon57.png" >/dev/null && sips -z 512 512 "$ICON" --out "$EXPORT/icon512.png" >/dev/null

# 4. upload private objects (no public ACL) + sign. ORDER MATTERS: ipa URL signed first → patched into manifest → manifest signed.
sign() { gcloud storage sign-url "$1" --duration="$DURATION" --format='value(signed_url)' 2>/dev/null; }
log "upload → $PREFIX (private) + V4 signed URLs ($DURATION, account: $(gcloud config get-value account 2>/dev/null))"
gsutil -q -h "Content-Type:application/octet-stream" cp "$EXPORT/OpenVision.ipa" "$PREFIX/OpenVision.ipa"
gsutil -q -h "Content-Type:image/png" cp "$EXPORT/icon57.png" "$EXPORT/icon512.png" "$PREFIX/"
IPA_URL=$(sign "$PREFIX/OpenVision.ipa"); I57_URL=$(sign "$PREFIX/icon57.png"); I512_URL=$(sign "$PREFIX/icon512.png")
[[ $IPA_URL == https://* ]] || { echo "✗ sign-url failed (needs a service-account credential or --impersonate-service-account)"; exit 1; }
IPA_URL="$IPA_URL" I57_URL="$I57_URL" I512_URL="$I512_URL" BUNDLE="$BUNDLE" python3 - "$EXPORT/manifest.plist" <<'PY'
import os, plistlib, sys
p = sys.argv[1]; m = plistlib.load(open(p, 'rb'))
urls = {'software-package': os.environ['IPA_URL'], 'display-image': os.environ['I57_URL'], 'full-size-image': os.environ['I512_URL']}
for item in m['items']:
    for a in item['assets']: a['url'] = urls.get(a['kind'], a['url'])
    assert item['metadata']['bundle-identifier'] == os.environ['BUNDLE'], item['metadata']
plistlib.dump(m, open(p, 'wb'))
PY
plutil -lint "$EXPORT/manifest.plist" >/dev/null || { echo "✗ manifest.plist invalid"; exit 1; }
gsutil -q -h "Content-Type:application/xml" cp "$EXPORT/manifest.plist" "$PREFIX/manifest.plist"
MANIFEST_URL=$(sign "$PREFIX/manifest.plist")
ITMS="itms-services://?action=download-manifest&url=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$MANIFEST_URL")"

# 5. install.html (the robust path — Safari opens the https page, the button fires itms-services)
cat >"$OTA/install.html" <<EOF
<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>OpenVision OTA $SHA</title>
<body style="font:22px -apple-system,sans-serif;text-align:center;padding:12vh 6vw;background:#0b0b0f;color:#eee">
<p><img src="$I512_URL" width="96" height="96" style="border-radius:22px"></p>
<h1>OpenVision <small style="opacity:.6">$SHA · $DATE</small></h1>
<p><a href="$ITMS" style="display:inline-block;background:#4f8cff;color:#fff;text-decoration:none;padding:22px 44px;border-radius:18px;font-weight:600;font-size:28px">Install OpenVision</a></p>
<p style="opacity:.6;font-size:16px">Tap Install on the sheet; if iOS says "Untrusted Developer" → Settings → General → VPN &amp; Device Management → trust. Link valid $DURATION.</p>
</body>
EOF
gsutil -q -h "Content-Type:text/html; charset=utf-8" cp "$OTA/install.html" "$PREFIX/install.html"
PAGE_URL=$(sign "$PREFIX/install.html"); lap upload+sign
printf '%s\n%s\n' "$ITMS" "$PAGE_URL" >"$OTA/latest-link.txt"
HEAD=$(curl -s -o /dev/null -w '%{http_code} %{content_type}' -r 0-0 "$MANIFEST_URL")
log "manifest probe: $HEAD"; [[ $HEAD == 206* || $HEAD == 200* ]] || { echo "✗ manifest URL not fetchable"; exit 1; }
log "install page: $PAGE_URL"; log "itms link:     $ITMS"

# 6. Telegram push (token from AGENT_PUSH_ENV_FILE; chat id from the same file, else OTA_TELEGRAM_CHAT_ID, else Anton)
PENV=$(grep -E '^export AGENT_PUSH_ENV_FILE=' "$HOME/Workspace/aurelia/agent.env" | sed -E 's/^export AGENT_PUSH_ENV_FILE="?([^"#]+)"?.*/\1/' | sed "s|\$HOME|$HOME|")
TOK=$(grep '^TELEGRAM_BOT_TOKEN=' "$PENV" 2>/dev/null | cut -d= -f2- | tr -d '"' || true)
CHAT=$(grep '^TELEGRAM_CHAT_ID=' "$PENV" 2>/dev/null | cut -d= -f2- | tr -d '"' || true); CHAT=${CHAT:-${OTA_TELEGRAM_CHAT_ID:-5332687097}}
[[ -n $TOK ]] || { echo "⚠ no TELEGRAM_BOT_TOKEN in $PENV — link not pushed (it is in $OTA/latest-link.txt)"; exit 0; }
TEXT="📲 <b>OpenVision OTA</b> <code>$SHA</code> · $DATE
<a href=\"$PAGE_URL\">Install OpenVision</a> (valid 7 days — opens in Safari, tap Install)"
KB=$(python3 -c 'import json,sys;print(json.dumps({"inline_keyboard":[[{"text":"📲 Install OpenVision","url":sys.argv[1]}]]}))' "$PAGE_URL")
RES=$(curl -s -X POST "https://api.telegram.org/bot$TOK/sendMessage" -d chat_id="$CHAT" -d parse_mode=HTML -d disable_web_page_preview=true \
  --data-urlencode "text=$TEXT" --data-urlencode "reply_markup=$KB")
log "telegram → chat $CHAT: $(printf '%s' "$RES" | python3 -c 'import json,sys;d=json.load(sys.stdin);print("ok:true msg",d["result"]["message_id"]) if d.get("ok") else print("ok:false",d)')"
