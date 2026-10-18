<img width="296" height="259" alt="image" src="https://github.com/user-attachments/assets/d67ec747-009d-4be0-b7e9-c771995f6a94" />

# Seamless Rate Switcher

**Bit-perfect sample rate switching for Apple Music on Mac.**

Mac의 Music 앱용 메뉴바 앱입니다.

1. **샘플레이트 자동 전환**: 곡이 바뀔 때마다 출력 장치의 샘플레이트를 그 곡에 맞춥니다.
2. **전환 시 무음 삽입**: 샘플레이트가 바뀔 때 DAC가 새 샘플레이트로 전환을 마칠 때까지 재생을 멈추고 기다린 뒤, 곡을 처음부터 재생합니다.

## 시작하기

Music 앱의 Apple Music 스트리밍과 보관함의 로컬 파일을 모두 지원합니다.
**macOS 27.0.1에서만 테스트했습니다.**

1. `Seamless Rate Switcher.app`을 `/Applications`에 넣고 실행합니다.
2. 메뉴바에 **♫ 44.1k** 처럼 음표와 현재 출력 장치의 샘플레이트가 표시됩니다.
3. Music 앱에서 곡을 재생하면 곡마다 샘플레이트가 자동으로 맞춰집니다.
4. 처음 한 번 "Music을 제어하려고 합니다" 권한 창이 뜹니다. **허용**을 눌러 주세요. 전환 중 일시정지/재개와 로컬 파일의 샘플레이트 확인에 필요합니다.

## 알아둘 점

- **이 앱은 Music을 직접 제어합니다.** 샘플레이트가 바뀌는 곡에서는 Music이 몇 초간 일시정지되는데, DAC가 새 샘플레이트로 전환을 마칠 때까지 기다리는 정상 동작입니다. **재생 버튼을 누르지 말고 기다려 주세요.** 잠시 후 자동으로 다시 재생됩니다. 기다리는 시간은 메뉴바 아이콘 → **Pause While Switching**에서 조절할 수 있습니다 (기본 5초).
- 앱을 켜기 전부터 재생 중이던 Apple Music 곡은 다음 곡부터 샘플레이트가 맞춰집니다. 로컬 파일은 바로 맞춰집니다.
- 출력 장치가 지원하지 않는 샘플레이트는 건너뜁니다.
- Music 앱의 내부 로그를 읽어서 동작하기 때문에, macOS나 Music 앱 업데이트 후 동작하지 않을 수 있습니다.

## 빌드

Xcode 없이 Command Line Tools만으로 빌드할 수 있습니다.

```bash
scripts/bundle.sh            # build/Seamless Rate Switcher.app 생성
scripts/bundle.sh --install  # /Applications에 설치하고 실행
```

Command Line Tools 환경에서는 SwiftPM 기본 빌드 시스템이 실패할 수 있어서, 스크립트는 `--build-system native`로 빌드합니다.
