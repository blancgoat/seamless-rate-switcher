# 로그 분석 결과

## 캡처 20261018-130641 (macOS 27, Music, MOTU UltraLite-mk5, LosslessSwitcher 실행 중)

재생 순서: Suki de Ite (ALAC 24/96, 245.26초) → Bye Bye My Blue (ALAC 16/44.1)

### 타임라인 (메인 플레이어 `P/WX`)

| 시각 | 곡 위치 | 로그 | 장치 |
|---|---|---|---|
| 13:06:56.240 | 0 | `updating current item from (null) to I/LUM.01` | |
| 13:06:56.794 | | `RP/WX.25 Creating AudioQueue ... sampleRate:96000` (직전 item 로그: `I/LUM.01`) | 13:06:58.715 → 96k |
| 13:10:09.045 | 190.3 | `I/LUM.01: At end of all streams` (현재 곡 버퍼링 완료) | |
| 13:10:09.047 | | `will not commit to gapless transition to next item I/XKF.01` | |
| 13:10:09.048 | | `RP/WX.26 Creating AudioQueue ... sampleRate:44100` (직전 item 로그: `I/XKF.01`, **다음 곡 prefetch**) | 13:10:12.127 → **44.1k (버그)** |
| 13:11:04.195 | 243.6 | 사용자 일시정지 → `RP/WX.27 ... 96000` (`I/LUM.01` 재생성) | 13:11:06.918 → 96k |
| 13:12:57.414 | 226.6 | 시크 → `RP/WX.28`, `RP/WX.29 ... 96000` (`I/LUM.01`) | |
| 13:13:17.919 | | `updating current item from I/LUM.01 to I/XKF.01` (실제 곡 전환) | **변화 없음 (96k 유지, 버그)** |

### 결론

1. **곡 중간에 떨어지는 버그 = prefetch 오인 (가설 1 확정).** 현재 곡의 다운로드가 끝나면 Music이 다음 곡의 AudioQueue를 미리 생성한다. `Creating AudioQueue` 로그 자체에는 곡 식별자가 없어서, 이 로그만 보면 다음 곡 포맷이 현재 곡 포맷처럼 보인다. 떨어지는 시점은 "버퍼링 완료" 시점이라 네트워크가 빠를수록 더 이르다.
2. **포맷을 놓치는 버그도 같은 원인.** 실제 곡 전환(13:13:17) 시점에는 AudioQueue 생성 로그가 없다. prefetch 때 이미 만들어 둔 것을 쓰기 때문이다. 그래서 "최신 AudioQueue 로그 = 현재 포맷"으로 읽는 방식은 전환 시점에 아무것도 바꾸지 못한다.
3. **AudioQueue는 일시정지·시크 때도 재생성된다.** 생성 로그는 곡 시작 신호가 아니다.
4. **AppleScript `sample rate`는 지연된다.** 곡 시작 직후 조회하면 이전 곡 값이 나오고, 3초 뒤에야 맞는 값이 나온다(카탈로그 값일 가능성도 있음). 보조 신호로만 쓴다.
5. **메인 플레이어를 골라야 한다.** `P/UH`, `P/IA`, `P/UU` 등 timescale 30인 플레이어는 애니메이션 아트워크 같은 영상 플레이어라 무시한다.

### 설계에 반영

- `Creating AudioQueue ... sampleRate:N` 바로 직전의 같은 플레이어 `<...|I/xxx>` 로그로 **곡 ID → 포맷 맵**을 만든다.
- `currentItem KVO: updating current item from X to Y`가 오면 맵에서 Y의 포맷을 찾아 **그때만** 장치 rate를 바꾼다.
- Y가 맵에 없으면 Y에 대한 첫 AudioQueue 로그를 기다렸다가 적용한다.

## 로컬 파일 (2026-10-18 추가)

- AppleScript로 구분된다. 스트리밍 곡은 `shared track` / cloud status `subscription`이고 `sample rate`가 틀리다(재생 중이 아니면 96k 곡도 44100). 로컬 파일은 `file track`이고 `location`이 있으며 `sample rate`가 정확하다.
- 로컬 파일 재생 때도 `Creating AudioQueue ... format:'.mp3' sampleRate:44100`은 찍히지만 **앞에 item 로그가 없다**. 그래서 이전 곡 ID에 잘못 붙지 않도록, 곡 전환 시 "직전 item"을 지운다.
- 처리: playerInfo의 곡 전환 → AppleScript로 current track 조회(persistent ID가 맞을 때까지 재시도) → 로컬 파일이면 그 sample rate로 맞춘다.

## 실기 테스트 결과 (switcher, 13:22–13:25)

| 전환 | 결과 |
|---|---|
| 로컬 MP3 44.1 → 스트리밍 96k | 96k로 변경 |
| 스트리밍 96k → 로컬 MP3 44.1 | 44.1k로 변경 (AppleScript, 약 0.5초) |
| 로컬 MP3 → 스트리밍 96k | 곡 전환 후 0.46초에 96k로 변경 |
| 스트리밍 96k 재생 중 다음 곡(44.1) prefetch | 포맷만 기록하고 96k 유지 |
| 스트리밍 96k → 스트리밍 44.1 (자연 전환) | 전환 순간 44.1k로 변경 |
