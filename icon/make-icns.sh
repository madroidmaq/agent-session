#!/bin/bash
# 由 AppIcon.svg 渲染出 macOS 所需的多分辨率 iconset，并打包成 AppIcon.icns。
# 依赖：rsvg-convert（brew install librsvg）、iconutil（系统自带）。
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
SVG="$DIR/AppIcon.svg"
SET="$DIR/AppIcon.iconset"
OUT="$DIR/../AppIcon.icns"

rm -rf "$SET"; mkdir -p "$SET"

# 文件名 → 像素尺寸（含 @2x），覆盖 16~512 全档
render() { rsvg-convert -w "$2" -h "$2" "$SVG" -o "$SET/$1"; }
render icon_16x16.png        16
render icon_16x16@2x.png      32
render icon_32x32.png        32
render icon_32x32@2x.png      64
render icon_128x128.png     128
render icon_128x128@2x.png  256
render icon_256x256.png     256
render icon_256x256@2x.png  512
render icon_512x512.png     512
render icon_512x512@2x.png 1024

iconutil -c icns "$SET" -o "$OUT"
rm -rf "$SET"
echo "✅ icns: $OUT"
