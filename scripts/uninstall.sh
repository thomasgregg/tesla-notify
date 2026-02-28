#!/usr/bin/env bash
set -euo pipefail

APP_SUPPORT_DIR="$HOME/Library/Application Support/TeslaNotifier"
APP_INSTALL_DIR="${APP_INSTALL_DIR:-/Applications}"
APP_BUNDLE="$APP_INSTALL_DIR/tesla-notifier-forwarder.app"
LEGACY_APP_BUNDLE_APP_SUPPORT="$APP_SUPPORT_DIR/tesla-notifier-forwarder.app"
LEGACY_APP_BUNDLE_OLD_NAME="$APP_SUPPORT_DIR/TeslaNotifierForwarder.app"
LEGACY_BUILD_ROOT="$APP_SUPPORT_DIR/.build"
LEGACY_SOURCE_FORWARDER="$APP_SUPPORT_DIR/forwarder.swift"
LEGACY_SOURCE_MENU="$APP_SUPPORT_DIR/menu_app.swift"
LEGACY_ICONSET="$APP_SUPPORT_DIR/AppIcon.iconset"
LEGACY_EXTRACTED_ICONSET="$APP_SUPPORT_DIR/Extracted.iconset"
LEGACY_ICON_PNG="$APP_SUPPORT_DIR/tesla-icon-1024.png"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST_PATH="$LAUNCH_AGENTS_DIR/com.tesla.notifier.forwarder.plist"
MENU_PLIST_PATH="$LAUNCH_AGENTS_DIR/com.tesla.notifier.menu.plist"

launchctl bootout "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null || true
launchctl bootout "gui/$(id -u)" "$MENU_PLIST_PATH" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.tesla.notifier.forwarder" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.tesla.notifier.menu" 2>/dev/null || true
launchctl remove "com.tesla.notifier.forwarder" 2>/dev/null || true
launchctl remove "com.tesla.notifier.menu" 2>/dev/null || true

# Kill any lingering binaries (e.g., if manually launched outside launchd).
pkill -f '/Applications/tesla-notifier-forwarder.app/Contents/Resources/forwarder-daemon' 2>/dev/null || true
pkill -f '/Applications/tesla-notifier-forwarder.app/Contents/MacOS/tesla-notifier-forwarder' 2>/dev/null || true
pkill -f 'tesla-notifier-forwarder.app/Contents/Resources/forwarder-daemon' 2>/dev/null || true
pkill -f 'tesla-notifier-forwarder.app/Contents/MacOS/tesla-notifier-forwarder' 2>/dev/null || true

if [[ -f "$PLIST_PATH" ]]; then
  rm -f "$PLIST_PATH"
  echo "Removed $PLIST_PATH"
fi

if [[ -f "$MENU_PLIST_PATH" ]]; then
  rm -f "$MENU_PLIST_PATH"
  echo "Removed $MENU_PLIST_PATH"
fi

if [[ -d "$APP_BUNDLE" ]]; then
  rm -rf "$APP_BUNDLE"
  echo "Removed $APP_BUNDLE"
fi

if [[ -d "$LEGACY_APP_BUNDLE_APP_SUPPORT" ]]; then
  rm -rf "$LEGACY_APP_BUNDLE_APP_SUPPORT"
  echo "Removed $LEGACY_APP_BUNDLE_APP_SUPPORT"
fi

if [[ -d "$LEGACY_APP_BUNDLE_OLD_NAME" ]]; then
  rm -rf "$LEGACY_APP_BUNDLE_OLD_NAME"
  echo "Removed $LEGACY_APP_BUNDLE_OLD_NAME"
fi

if [[ -d "$LEGACY_BUILD_ROOT" ]]; then
  rm -rf "$LEGACY_BUILD_ROOT" 2>/dev/null || true
  if [[ -d "$LEGACY_BUILD_ROOT" ]] && command -v sudo >/dev/null 2>&1; then
    sudo -n rm -rf "$LEGACY_BUILD_ROOT" 2>/dev/null || true
  fi
  if [[ -d "$LEGACY_BUILD_ROOT" ]]; then
    echo "Warning: could not fully remove $LEGACY_BUILD_ROOT"
    echo "Run once to clean old root-owned cache: sudo rm -rf \"$LEGACY_BUILD_ROOT\""
  else
    echo "Removed $LEGACY_BUILD_ROOT"
  fi
fi

for legacy_file in \
  "$LEGACY_SOURCE_FORWARDER" \
  "$LEGACY_SOURCE_MENU" \
  "$LEGACY_ICON_PNG"
do
  if [[ -f "$legacy_file" ]]; then
    rm -f "$legacy_file"
    echo "Removed $legacy_file"
  fi
done

for legacy_dir in \
  "$LEGACY_ICONSET" \
  "$LEGACY_EXTRACTED_ICONSET"
do
  if [[ -d "$legacy_dir" ]]; then
    rm -rf "$legacy_dir"
    echo "Removed $legacy_dir"
  fi
done

echo "Uninstalled launch agents and app bundle."
echo "Config/log/state kept in: $APP_SUPPORT_DIR"
echo "Post-check: run 'pmset -g assertions' and verify no Tesla Notifier process holds sleep assertions."
