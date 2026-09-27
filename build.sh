#!/bin/zsh
# Builds Snip.app into ./build and optionally installs it to /Applications.
set -e
cd "$(dirname "$0")"

swift build -c release 2>&1 | grep -E "error|warning: unre|Compiling|Build complete" || true

APP=build/Snip.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Snip "$APP/Contents/MacOS/Snip"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>Snip</string>
    <key>CFBundleDisplayName</key>     <string>Snip</string>
    <key>CFBundleIdentifier</key>      <string>com.sharryy.snip</string>
    <key>CFBundleExecutable</key>      <string>Snip</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>1.0</string>
    <key>CFBundleVersion</key>         <string>1</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHighResolutionCapable</key> <true/>
</dict>
</plist>
PLIST

# Sign with the self-signed "Snip Dev" certificate when present, so macOS keeps treating
# rebuilds as the same app and the Screen Recording permission survives. Falls back to ad-hoc.
IDENTITY=$(security find-identity -p codesigning 2>/dev/null | grep '"Snip Dev"' | head -1 | awk '{print $2}')
codesign --force --sign "${IDENTITY:--}" "$APP" 2>/dev/null
echo "Signed with: ${IDENTITY:-ad-hoc}"
echo "Built $APP"

if [[ "$1" == "--install" ]]; then
    pkill -x Snip 2>/dev/null || true
    sleep 1
    rm -rf /Applications/Snip.app
    cp -R "$APP" /Applications/Snip.app
    open /Applications/Snip.app
    echo "Installed and launched /Applications/Snip.app"
fi
