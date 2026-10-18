#!/bin/zsh
# 메뉴바 앱 .app 번들 생성 (Xcode 없이 Command Line Tools만으로).
# 사용: scripts/bundle.sh            → build/LikeLosslessSwitcher.app
#       scripts/bundle.sh --install  → /Applications에 복사 후 실행 ("로그인 시 실행"은 /Applications에서 동작)
set -eu
ROOT=${0:A:h:h}
NAME=LikeLosslessSwitcher
APP="$ROOT/build/$NAME.app"
VERSION=$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo 0.0.0)
BUILD=$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)

swift build -c release --build-system native --package-path "$ROOT" --product "$NAME" 2>&1 | grep -v "deprecated" || true
BIN="$ROOT/.build/release/$NAME"
[[ -x "$BIN" ]] || { echo "빌드 실패"; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/$NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>dev.blancgoat.LikeLosslessSwitcher</string>
    <key>CFBundleName</key><string>Like LosslessSwitcher</string>
    <key>CFBundleExecutable</key><string>$NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSAppleEventsUsageDescription</key><string>로컬 파일 곡의 샘플레이트를 Music 앱에서 읽기 위해 필요합니다.</string>
</dict>
</plist>
PLIST

# ad-hoc 서명 (로컬 실행용)
codesign --force --sign - "$APP"
echo "생성됨: $APP (v$VERSION build $BUILD)"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x "$NAME" 2>/dev/null || true
    # 이전 앱이 완전히 끝나기 전에 open하면 -600 에러가 난다
    for _ in {1..50}; do pgrep -x "$NAME" >/dev/null || break; sleep 0.1; done
    rm -rf "/Applications/$NAME.app"
    cp -R "$APP" /Applications/
    open "/Applications/$NAME.app"
    echo "설치 후 실행: /Applications/$NAME.app"
fi
