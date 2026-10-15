#!/bin/bash
# Build Inkshot.app.   ./build.sh          -> build/Inkshot.app
#                  ./build.sh install  -> also copy to ~/Applications and launch
set -euo pipefail
cd "$(dirname "$0")"

BUNDLE_ID="com.viafirst.inkshot"
APP="build/Inkshot.app"

./scripts/check-strings.sh
swift build -c release
BIN="$(swift build -c release --show-bin-path)/Inkshot"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Inkshot"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/Localization/*.lproj "$APP/Contents/Resources/"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# Use a real signing identity if one exists (set INKSHOT_SIGN_IDENTITY), otherwise ad-hoc.
# The explicit designated requirement (bundle id only) keeps the Screen Recording /
# Accessibility grants valid across rebuilds instead of tying them to one binary hash.
IDENTITY="${INKSHOT_SIGN_IDENTITY:--}"
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" \
  -r="designated => identifier \"$BUNDLE_ID\"" "$APP"

echo "Built $APP"

if [ "${1:-}" = "install" ]; then
  pkill -x Inkshot 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Inkshot >/dev/null || break; sleep 0.3; done
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/Inkshot.app"
  # Move, not copy: a second .app left in build/ shows up in Spotlight and "Open With".
  mv "$APP" "$HOME/Applications/"
  open "$HOME/Applications/Inkshot.app"
  echo "Installed to ~/Applications/Inkshot.app"
fi
