#!/bin/bash
# 앱 번들 빌드·설치. 번들 Info.plist가 레포 밖에만 있어서 재현이 안 되던 걸 고친 것.
#
# 바이너리를 번들에 넣은 뒤에는 반드시 재서명한다. 안 하면 SIGKILL(CODESIGNING)로
# 즉사하는데 크래시가 코드 버그처럼 보인다.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${1:-$HOME/Applications/도마도 HWP 뷰어.app}"

swift build -c release --product HwpViewer --package-path "$ROOT"
mkdir -p "$DEST/Contents/MacOS" "$DEST/Contents/Resources"
cp "$ROOT/.build/release/HwpViewer" "$DEST/Contents/MacOS/HwpViewer"
cp "$ROOT/Sources/HwpViewer/Resources/Info.plist" "$DEST/Contents/Info.plist"
codesign --force --sign - "$DEST"
# 서비스 메뉴는 등록된 앱을 다시 훑어야 나타난다.
/System/Library/CoreServices/pbs -flush 2>/dev/null || true
echo "설치됨: $DEST"
