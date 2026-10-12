#!/bin/bash
# Build PSE.app.   ./build.sh          -> build/PSE.app
#                  ./build.sh install  -> also copy to ~/Applications and launch
set -euo pipefail
cd "$(dirname "$0")"

BUNDLE_ID="com.viafirst.pse"
APP="build/PSE.app"

./scripts/check-strings.sh
swift build -c release
BIN="$(swift build -c release --show-bin-path)/PSE"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PSE"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/Localization/*.lproj "$APP/Contents/Resources/"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# Use a real signing identity if one exists (set PSE_SIGN_IDENTITY), otherwise ad-hoc.
# The explicit designated requirement (bundle id only) keeps the Screen Recording /
# Accessibility grants valid across rebuilds instead of tying them to one binary hash.
IDENTITY="${PSE_SIGN_IDENTITY:--}"
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" \
  -r="designated => identifier \"$BUNDLE_ID\"" "$APP"

echo "Built $APP"

if [ "${1:-}" = "install" ]; then
  pkill -x PSE 2>/dev/null || true
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/PSE.app"
  cp -R "$APP" "$HOME/Applications/"
  open "$HOME/Applications/PSE.app"
  echo "Installed to ~/Applications/PSE.app"
fi
