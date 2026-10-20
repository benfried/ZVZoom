#!/bin/bash
# Build a release binary and wrap it in a minimal .app bundle so it can be a Login Item.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN=".build/release/ZVZoom"
APP="ZVZoom.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/ZVZoom"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>      <string>ZVZoom</string>
    <key>CFBundleIdentifier</key>      <string>local.zvzoom</string>
    <key>CFBundleName</key>            <string>ZVZoom</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>0.1</string>
    <key>CFBundleVersion</key>         <string>1</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHumanReadableCopyright</key> <string></string>
</dict>
</plist>
EOF

# Ad-hoc signature so macOS does not complain about an unsigned bundle.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "built $APP"
echo "run:  open $APP"
echo "login item: System Settings > General > Login Items > + > $PWD/$APP"
