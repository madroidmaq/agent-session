#!/bin/bash
# 编译 AgentSession 并打包成可双击的 AgentSession.app
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/AgentSession.app"

echo "▸ swift build -c release"
swift build -c release --package-path "$DIR"

BIN="$(swift build -c release --package-path "$DIR" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN/AgentSession" "$APP/Contents/MacOS/AgentSession"

# SwiftPM 把资源放进 AgentSession_AgentSession.bundle —— 一并搬进 .app，
# 这样 Bundle.module 在运行时能定位到 template.html。
if [ -d "$BIN/AgentSession_AgentSession.bundle" ]; then
  cp -R "$BIN/AgentSession_AgentSession.bundle" "$APP/Contents/Resources/"
fi

# 应用图标：icns 缺失时由 SVG 现场生成（需 rsvg-convert），再放进 .app。
if [ ! -f "$DIR/AppIcon.icns" ] && command -v rsvg-convert >/dev/null 2>&1; then
  "$DIR/icon/make-icns.sh"
fi
if [ -f "$DIR/AppIcon.icns" ]; then
  cp "$DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>AgentSession</string>
  <key>CFBundleDisplayName</key><string>AgentSession</string>
  <key>CFBundleIdentifier</key><string>dev.madroid.agent-session</string>
  <key>CFBundleExecutable</key><string>AgentSession</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "✅ built: $APP"
echo "运行：open \"$APP\""
