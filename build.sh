#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
RES="$ROOT/Resources"
OUT="${OUT:-$(dirname "$ROOT")/Legend Remake.app}"
BUILD="$ROOT/.build"

fail() {
  echo "erro: $*" >&2
  exit 1
}

import_engine() {
  [ -f "$RES/engine/Engine.swf" ] && return
  [ -n "${LEGEND_DIR:-}" ] || fail "falta Resources/engine/Engine.swf; rode com LEGEND_DIR=<pasta do launcher oficial do Legend Remake>"
  cp "$LEGEND_DIR/engine/Engine.swf" "$RES/engine/"
  mkdir -p "$RES/engine/icons"
  cp "$LEGEND_DIR"/engine/icons/*.png "$RES/engine/icons/"
}

import_icon() {
  [ -f "$RES/AppIcon.icns" ] && return
  local set="$BUILD/AppIcon.iconset" src="$RES/engine/icons/icon128.png"
  mkdir -p "$set"
  for size in 16 32 128; do
    sips -z "$size" "$size" "$src" --out "$set/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$src" --out "$set/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$set" -o "$RES/AppIcon.icns"
}

import_runtime() {
  [ -x "$RES/AIRSDK/bin/adl" ] && return
  [ -n "${AIR_SDK:-}" ] || fail "falta o runtime AIR; rode com AIR_SDK=<AIR SDK 51.4 ou mais novo para macOS>"
  mkdir -p "$RES/AIRSDK/bin" "$RES/AIRSDK/runtimes/air"
  ditto "$AIR_SDK/bin/adl" "$RES/AIRSDK/bin/adl"
  ditto "$AIR_SDK/runtimes/air/mac" "$RES/AIRSDK/runtimes/air/mac"
  cp "$AIR_SDK/air-sdk-description.xml" "$RES/AIRSDK/"
}

commit() {
  local sha
  sha="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null)" || { echo dev; return; }
  [ -z "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ] || sha="$sha-dirty"
  echo "$sha"
}

rm -rf "$BUILD"
mkdir -p "$BUILD"
import_engine
import_icon
import_runtime

for arch in arm64 x86_64; do
  swiftc -O -wmo -parse-as-library -swift-version 5 \
    -target "$arch-apple-macos14.0" \
    -o "$BUILD/LegendRemake-$arch" "$ROOT"/Sources/*.swift
done

STAGE="$BUILD/Legend Remake.app"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
lipo -create -output "$STAGE/Contents/MacOS/LegendRemake" "$BUILD"/LegendRemake-arm64 "$BUILD"/LegendRemake-x86_64
cp "$RES/Info.plist" "$STAGE/Contents/"
/usr/libexec/PlistBuddy -c "Add :LRCommit string $(commit)" "$STAGE/Contents/Info.plist"
cp "$RES/AppIcon.icns" "$STAGE/Contents/Resources/"
ditto "$RES/engine" "$STAGE/Contents/Resources/engine"
python3 -I "$ROOT/Tools/patch_engine.py" "$RES/engine/Engine.swf" "$STAGE/Contents/Resources/engine/Engine.swf"
ditto "$RES/AIRSDK" "$STAGE/Contents/Resources/AIRSDK"
codesign --force --sign - --timestamp=none "$STAGE"

rm -rf "$OUT"
mv "$STAGE" "$OUT"
rm -rf "$BUILD"
echo "$OUT"
