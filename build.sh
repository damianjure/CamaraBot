#!/bin/zsh
# Builds CueVideo.app (release) next to this script.
set -e
cd "$(dirname "$0")"
MODE=${1:-release}
swift build -c $MODE
BIN="$(swift build -c $MODE --show-bin-path)/CueVideo"
APP="CueVideo.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CueVideo"
cp "$(dirname "$BIN")/cuevideo-mcp" "$APP/Contents/MacOS/cuevideo-mcp"
# Figtree and the colours come from CueKit's resource bundle.
cp -R "$(dirname "$BIN")/CueKit_CueDesign.bundle" "$APP/Contents/Resources/"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>CueVideo</string>
  <key>CFBundleDisplayName</key><string>CueVideo</string>
  <key>CFBundleIdentifier</key><string>com.churchfront.cuevideo</string>
  <key>CFBundleExecutable</key><string>CueVideo</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSLocalNetworkUsageDescription</key><string>CueVideo controls your ATEM switcher and PTZ cameras and shows NDI video from your network.</string>
  <key>NSBonjourServices</key><array><string>_ndi._tcp</string></array>
</dict>
</plist>
PLIST
codesign --force --deep --sign - "$APP"
echo "Built $(pwd)/$APP"
