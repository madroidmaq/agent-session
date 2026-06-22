#!/bin/bash
# 把 AgentSession.app 打包成可拖拽安装的 AgentSession.dmg。
# 依赖：hdiutil（系统自带）。先确保已 ./build.sh 生成最新 .app。
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/AgentSession.app"
DMG="$DIR/AgentSession.dmg"
VOL="AgentSession"

[ -d "$APP" ] || { echo "缺少 $APP，请先运行 ./build.sh"; exit 1; }

STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"   # 拖拽目标：把图标拖进去即安装

rm -f "$DMG"
hdiutil create -volname "$VOL" -srcfolder "$STAGE" \
  -fs HFS+ -format UDZO -ov "$DMG" >/dev/null

rm -rf "$STAGE"
echo "✅ dmg: $DMG"
