#!/bin/zsh
# build.sh — build, bundle, sign and deploy Luminos.app
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Luminos"
BUNDLE_ID="dev.luminos.daemon"
INSTALL_DIR="$HOME/Applications"
APP_PATH="$INSTALL_DIR/$APP_NAME.app"

echo "▸ swift build"
swift build -c release

echo "▸ bundle"
rm -rf ".build/$APP_NAME.app"
mkdir -p ".build/$APP_NAME.app/Contents/MacOS" ".build/$APP_NAME.app/Contents/Resources"
cp .build/release/luminos ".build/$APP_NAME.app/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist ".build/$APP_NAME.app/Contents/Info.plist"
cp Resources/AppIcon.icns ".build/$APP_NAME.app/Contents/Resources/AppIcon.icns"
cp Resources/StatusIcon*.png ".build/$APP_NAME.app/Contents/Resources/" 2>/dev/null || true

echo "▸ sign (ad-hoc)"
codesign --force --sign - ".build/$APP_NAME.app"

echo "▸ deploy"
launchctl bootout "gui/$(id -u)/$BUNDLE_ID" 2>/dev/null || true
pkill -f "$APP_PATH/Contents/MacOS/$APP_NAME" 2>/dev/null || true
# wait until the old process is fully gone before replacing the bundle —
# otherwise launchd can relaunch mid-copy → "Taskgated Invalid Signature"
for _ in {1..20}; do
    pgrep -f "$APP_PATH/Contents/MacOS/$APP_NAME" >/dev/null || break
    sleep 0.25
done
mkdir -p "$INSTALL_DIR"
# rm+cp (new inode): in-place overwrite breaks macOS signature provenance
rm -rf "$APP_PATH"
cp -R ".build/$APP_NAME.app" "$APP_PATH"

PLIST="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"
# (no sed: the plist is static; an over-broad sed once mangled Label and log paths)

launchctl bootstrap "gui/$(id -u)" "$PLIST"
sleep 2
tail -1 /tmp/luminos.log || true
echo "✓ $APP_PATH deployed and running"
