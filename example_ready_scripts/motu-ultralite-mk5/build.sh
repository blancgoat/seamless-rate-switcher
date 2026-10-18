#!/bin/zsh
# 빌드해서 이 폴더에 motu-ultralite-mk5 실행 파일을 만든다.
# 앱 메뉴 → Pause While Switching 아래 Choose Ready Script…에서 그 파일을 고르면 된다.
# (Command Line Tools만 있는 환경에서는 기본 빌드 시스템이 실패할 수 있어 native를 쓴다)
set -eu
set -o pipefail
HERE=${0:A:h}
swift build -c release --build-system native --package-path "$HERE" 2>&1 | grep -v "deprecated"
cp "$HERE/.build/release/motu-ultralite-mk5" "$HERE/motu-ultralite-mk5"
echo "created: $HERE/motu-ultralite-mk5"
