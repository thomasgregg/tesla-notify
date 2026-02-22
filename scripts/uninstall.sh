#!/usr/bin/env bash
set -euo pipefail

APP_SUPPORT_DIR="$HOME/Library/Application Support/TeslaNotifier"
APP_INSTALL_DIR="${APP_INSTALL_DIR:-/Applications}"
APP_BUNDLE="$APP_INSTALL_DIR/tesla-notifier-forwarder.app"
LEGACY_APP_BUNDLE_APP_SUPPORT="$APP_SUPPORT_DIR/tesla-notifier-forwarder.app"
LEGACY_APP_BUNDLE_OLD_NAME="$APP_SUPPORT_DIR/TeslaNotifierForwarder.app"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST_PATH="$LAUNCH_AGENTS_DIR/com.tesla.notifier.forwarder.plist"
MENU_PLIST_PATH="$LAUNCH_AGENTS_DIR/com.tesla.notifier.menu.plist"

launchctl bootout "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null || true
launchctl bootout "gui/$(id -u)" "$MENU_PLIST_PATH" 2>/dev/null || true

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

echo "Uninstalled launch agents and app bundle."
echo "Config/log/state kept in: $APP_SUPPORT_DIR"
