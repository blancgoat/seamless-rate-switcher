#!/bin/zsh
# 메뉴바 앱 .app 번들 생성 (Xcode 없이 Command Line Tools만으로).
# 사용: scripts/bundle.sh            → build/Seamless Rate Switcher.app
#       scripts/bundle.sh --install  → /Applications에 복사 후 실행 ("로그인 시 실행"은 /Applications에서 동작)
set -eu
ROOT=${0:A:h:h}
NAME=SeamlessRateSwitcher             # 실행 파일 / SwiftPM 타깃 이름
DISPLAY_NAME="Seamless Rate Switcher" # Finder·메뉴에 보이는 이름
APP="$ROOT/build/$DISPLAY_NAME.app"
VERSION=$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo 0.0.0)
BUILD=$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)

swift build -c release --build-system native --package-path "$ROOT" --product "$NAME" 2>&1 | grep -v "deprecated" || true
BIN="$ROOT/.build/release/$NAME"
[[ -x "$BIN" ]] || { echo "빌드 실패"; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$NAME"

# 앱 아이콘: iconmaker로 크기별 PNG를 그리고 iconutil로 .icns 생성
swift build -c release --build-system native --package-path "$ROOT" --product iconmaker 2>&1 | grep -iE "error" || true
ICONSET="$ROOT/build/AppIcon.iconset"
rm -rf "$ICONSET"
"$ROOT/.build/release/iconmaker" "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>dev.blancgoat.SeamlessRateSwitcher</string>
    <key>CFBundleName</key><string>$DISPLAY_NAME</string>
    <key>CFBundleDisplayName</key><string>$DISPLAY_NAME</string>
    <key>CFBundleExecutable</key><string>$NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
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
    # 이름을 바꾸기 전 버전(LikeLosslessSwitcher)도 같이 정리
    for old in "$NAME" LikeLosslessSwitcher; do pkill -x "$old" 2>/dev/null || true; done
    # 이전 앱이 완전히 끝나기 전에 open하면 -600 에러가 난다
    for _ in {1..50}; do pgrep -x "$NAME" >/dev/null || pgrep -x LikeLosslessSwitcher >/dev/null || break; sleep 0.1; done
    rm -rf "/Applications/$DISPLAY_NAME.app" /Applications/LikeLosslessSwitcher.app
    cp -R "$APP" /Applications/
    touch "/Applications/$DISPLAY_NAME.app"  # Finder 아이콘 캐시 갱신
    open "/Applications/$DISPLAY_NAME.app"
    echo "설치 후 실행: /Applications/$DISPLAY_NAME.app"
fi
