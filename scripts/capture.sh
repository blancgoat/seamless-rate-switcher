#!/bin/zsh
# 재현 세션 캡처: Music 로그(log stream) + ratewatch 이벤트를 같은 폴더에 저장.
# 사용: scripts/capture.sh [--as]
#   - 실행 중 터미널에 메모를 치고 Enter → mark 이벤트로 기록 (예: "96k 곡 중간에 떨어짐")
#   - q + Enter 또는 Ctrl-C로 종료
# 로그 범위를 바꾸려면 PREDICATE 환경변수로 덮어쓰기.
set -eu
ROOT=${0:A:h:h}
OUT="$ROOT/captures/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"

PREDICATE=${PREDICATE:-'process == "Music" OR eventMessage CONTAINS[c] "samplerate" OR eventMessage CONTAINS[c] "sample rate"'}
echo "$PREDICATE" > "$OUT/predicate.txt"

swift build -c release --build-system native --package-path "$ROOT" >/dev/null 2>&1
RATEWATCH="$ROOT/.build/release/ratewatch"

/usr/bin/log stream --predicate "$PREDICATE" --info --debug --style ndjson > "$OUT/music.ndjson" &
LOG_PID=$!
trap 'kill $LOG_PID 2>/dev/null; echo "\n저장됨: $OUT"' EXIT INT TERM

echo "캡처 중 → $OUT  (메모 + Enter = 마커, q + Enter = 종료)"
"$RATEWATCH" "$@" | tee "$OUT/events.ndjson"
