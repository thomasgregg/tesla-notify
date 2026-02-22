#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_SUPPORT_DIR="$HOME/Library/Application Support/TeslaNotifier"
APP_INSTALL_DIR="${APP_INSTALL_DIR:-/Applications}"
APP_BUNDLE_NAME="tesla-notifier-forwarder.app"
APP_BUNDLE="$APP_INSTALL_DIR/$APP_BUNDLE_NAME"
STAGING_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/tesla-notifier-build.XXXXXX")"
STAGING_BUNDLE="$STAGING_ROOT/$APP_BUNDLE_NAME"
LEGACY_BUILD_ROOT="$APP_SUPPORT_DIR/.build"
LEGACY_APP_BUNDLE_APP_SUPPORT="$APP_SUPPORT_DIR/$APP_BUNDLE_NAME"
LEGACY_APP_BUNDLE_OLD_NAME="$APP_SUPPORT_DIR/TeslaNotifierForwarder.app"

APP_CONTENTS="$STAGING_BUNDLE/Contents"
APP_MACOS_DIR="$APP_CONTENTS/MacOS"
APP_RESOURCES_DIR="$APP_CONTENTS/Resources"
APP_PLIST="$APP_CONTENTS/Info.plist"

MENU_EXEC="$APP_MACOS_DIR/tesla-notifier-forwarder"
DAEMON_EXEC="$APP_RESOURCES_DIR/forwarder-daemon"

LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST_PATH="$LAUNCH_AGENTS_DIR/com.tesla.notifier.forwarder.plist"
MENU_PLIST_PATH="$LAUNCH_AGENTS_DIR/com.tesla.notifier.menu.plist"

FORWARDER_SRC="$REPO_DIR/src/forwarder.swift"
MENU_APP_SRC="$REPO_DIR/src/menu_app.swift"
VERIFY_SCRIPT_SRC="$REPO_DIR/scripts/verify_tesla_setup.sh"
VERIFY_SCRIPT_DST="$APP_SUPPORT_DIR/verify_tesla_setup.sh"

ICON_SOURCE_SVG="$REPO_DIR/assets/tesla.svg"
ICON_RENDERED_PNG="$STAGING_ROOT/tesla-icon-1024.png"
ICONSET_DIR="$STAGING_ROOT/AppIcon.iconset"
ICON_ICNS="$APP_RESOURCES_DIR/AppIcon.icns"

CONFIG_PATH="$APP_SUPPORT_DIR/config.json"
LOG_PATH="$APP_SUPPORT_DIR/forwarder.log"
ERR_PATH="$APP_SUPPORT_DIR/forwarder.err.log"
STATE_PATH="$APP_SUPPORT_DIR/state.json"

cleanup() {
  rm -rf "$STAGING_ROOT"
}
trap cleanup EXIT

mkdir -p "$APP_SUPPORT_DIR" "$APP_INSTALL_DIR" "$LAUNCH_AGENTS_DIR"
mkdir -p "$APP_MACOS_DIR" "$APP_RESOURCES_DIR"

if [[ -d "$LEGACY_BUILD_ROOT" ]]; then
  rm -rf "$LEGACY_BUILD_ROOT" 2>/dev/null || true
  if [[ -d "$LEGACY_BUILD_ROOT" ]] && command -v sudo >/dev/null 2>&1; then
    sudo -n rm -rf "$LEGACY_BUILD_ROOT" 2>/dev/null || true
  fi
  if [[ -d "$LEGACY_BUILD_ROOT" ]]; then
    echo "Warning: could not fully remove legacy build cache at $LEGACY_BUILD_ROOT"
    echo "Run once to clean old root-owned cache: sudo rm -rf \"$LEGACY_BUILD_ROOT\""
  fi
fi

if [[ -d "$LEGACY_APP_BUNDLE_APP_SUPPORT" ]]; then
  rm -rf "$LEGACY_APP_BUNDLE_APP_SUPPORT"
fi
if [[ -d "$LEGACY_APP_BUNDLE_OLD_NAME" ]]; then
  rm -rf "$LEGACY_APP_BUNDLE_OLD_NAME"
fi

cp "$VERIFY_SCRIPT_SRC" "$VERIFY_SCRIPT_DST"
chmod +x "$VERIFY_SCRIPT_DST"

/usr/bin/swiftc -O "$FORWARDER_SRC" -o "$DAEMON_EXEC"
/usr/bin/swiftc -O -framework AppKit "$MENU_APP_SRC" -o "$MENU_EXEC"

if [[ -f "$ICON_SOURCE_SVG" ]]; then
  sips -z 1024 1024 -s format png "$ICON_SOURCE_SVG" --out "$ICON_RENDERED_PNG" >/dev/null 2>&1 || true
fi

if [[ -f "$ICON_RENDERED_PNG" ]]; then
  rm -rf "$ICONSET_DIR"
  mkdir -p "$ICONSET_DIR"
  sips -z 16 16     "$ICON_RENDERED_PNG" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
  sips -z 32 32     "$ICON_RENDERED_PNG" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
  sips -z 32 32     "$ICON_RENDERED_PNG" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
  sips -z 64 64     "$ICON_RENDERED_PNG" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
  sips -z 128 128   "$ICON_RENDERED_PNG" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
  sips -z 256 256   "$ICON_RENDERED_PNG" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
  sips -z 256 256   "$ICON_RENDERED_PNG" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
  sips -z 512 512   "$ICON_RENDERED_PNG" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
  sips -z 512 512   "$ICON_RENDERED_PNG" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
  sips -z 1024 1024 "$ICON_RENDERED_PNG" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null
  iconutil -c icns "$ICONSET_DIR" -o "$ICON_ICNS"
fi

cat > "$APP_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>tesla-notifier-forwarder</string>
  <key>CFBundleIdentifier</key>
  <string>com.tesla.notifier.forwarder</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>tesla-notifier-forwarder</string>
  <key>CFBundleDisplayName</key>
  <string>tesla-notifier-forwarder</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.1.0</string>
  <key>CFBundleVersion</key>
  <string>110</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>LSUIElement</key>
  <true/>
</dict>
</plist>
EOF

SIGN_MODE="ad-hoc"
SIGN_IDENTITY_EFFECTIVE="${SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY_EFFECTIVE" ]]; then
  SIGN_IDENTITY_EFFECTIVE="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(.*\)"/\1/p' | head -n 1 || true)"
fi

if [[ -n "$SIGN_IDENTITY_EFFECTIVE" ]]; then
  codesign --force --deep --sign "$SIGN_IDENTITY_EFFECTIVE" "$STAGING_BUNDLE"
  SIGN_MODE="developer-id"
else
  codesign --force --deep --sign - "$STAGING_BUNDLE"
fi

if [[ ! -f "$CONFIG_PATH" ]]; then
  cat > "$CONFIG_PATH" <<EOF
{
  "targetRecipient": "+15555555555",
  "messagePrefix": "[WA->Tesla]",
  "includeSenderInMessage": true,
  "forwardingGateMode": "always",
  "forwardingGateFailOpen": true,
  "senderAllowlist": [],
  "dedupeWindowSeconds": 90,
  "maxMessageLength": 500,
  "logPath": "$LOG_PATH",
  "statePath": "$STATE_PATH",
  "debugNotificationDump": false,
  "whatsappDBPath": "$HOME/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite",
  "pollIntervalSeconds": 5,
  "teslaFleetVehicleDataURL": "",
  "teslaFleetBearerToken": "",
  "teslaFleetRefreshToken": "",
  "teslaOAuthClientID": "",
  "teslaOAuthClientSecret": "",
  "teslaOAuthTokenURL": "https://fleet-auth.prd.vn.cloud.tesla.com/oauth2/v3/token",
  "teslaFleetCacheSeconds": 20,
  "teslaFleetAllowWhenUserPresent": true
}
EOF
  echo "Created config template at $CONFIG_PATH"
else
  echo "Config already exists at $CONFIG_PATH"
fi

if [[ -d "$APP_BUNDLE" ]]; then
  rm -rf "$APP_BUNDLE"
fi
cp -R "$STAGING_BUNDLE" "$APP_BUNDLE"

# Refresh LaunchServices registration for better icon association in macOS settings panes.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f "$APP_BUNDLE" >/dev/null 2>&1 || true
fi

cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.tesla.notifier.forwarder</string>
  <key>ProgramArguments</key>
  <array>
    <string>$APP_BUNDLE/Contents/Resources/forwarder-daemon</string>
    <string>$CONFIG_PATH</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$LOG_PATH</string>
  <key>StandardErrorPath</key>
  <string>$ERR_PATH</string>
</dict>
</plist>
EOF

cat > "$MENU_PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.tesla.notifier.menu</string>
  <key>ProgramArguments</key>
  <array>
    <string>$APP_BUNDLE/Contents/MacOS/tesla-notifier-forwarder</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null || true
launchctl bootout "gui/$(id -u)" "$MENU_PLIST_PATH" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
launchctl bootstrap "gui/$(id -u)" "$MENU_PLIST_PATH"
launchctl kickstart -k "gui/$(id -u)/com.tesla.notifier.forwarder" || true
launchctl kickstart -k "gui/$(id -u)/com.tesla.notifier.menu" || true

echo "Installed and started com.tesla.notifier.forwarder"
echo "Installed and started com.tesla.notifier.menu"
echo "App bundle path: $APP_BUNDLE"
echo "Signing mode: $SIGN_MODE"
if [[ "$SIGN_MODE" = "developer-id" ]]; then
  echo "Signing identity: $SIGN_IDENTITY_EFFECTIVE"
else
  echo "No Developer ID identity found; ad-hoc signature was used."
fi

TARGET_RECIPIENT="$(/usr/bin/python3 - <<PY 2>/dev/null || true
import json
path = r'''$CONFIG_PATH'''
try:
    with open(path, 'r', encoding='utf-8') as f:
        cfg = json.load(f)
    print((cfg.get('targetRecipient') or '').strip())
except Exception:
    print('')
PY
)"

if [[ -z "$TARGET_RECIPIENT" || "$TARGET_RECIPIENT" == "+15555555555" || "$TARGET_RECIPIENT" == "+1YOUR_NUMBER" ]]; then
  echo "Edit $CONFIG_PATH and set targetRecipient to your real iMessage number."
else
  echo "Configured targetRecipient: $TARGET_RECIPIENT"
fi
