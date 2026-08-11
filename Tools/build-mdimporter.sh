#!/bin/bash
# Spotlight 임포터 빌드·설치.
#
# SwiftPM은 MH_DYLIB만 만들 수 있는데 CFPlugIn은 MH_BUNDLE을 요구하므로,
# HwpKit과 임포터를 한 모듈로 합쳐 swiftc로 직접 링크한다.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${1:-$HOME/Library/Spotlight}/HwpImporter.mdimporter"
TMP=$(mktemp -d)

cp "$ROOT"/Sources/HwpKit/*.swift "$TMP/"
sed 's/^import HwpKit$//' "$ROOT/Sources/HwpSpotlight/Importer.swift" > "$TMP/Importer.swift"

(cd "$TMP" && swiftc -O -whole-module-optimization -module-name HwpImporter \
    -emit-library -Xlinker -bundle -o HwpImporter *.swift)

rm -rf "$DEST"
mkdir -p "$DEST/Contents/MacOS"
cp "$TMP/HwpImporter" "$DEST/Contents/MacOS/HwpImporter"
cp "$ROOT/Sources/HwpSpotlight/Info.plist" "$DEST/Contents/Info.plist"
codesign --force -s - "$DEST"
rm -rf "$TMP"
echo "설치됨: $DEST"
