
# Seamless Rate Switcher

[English](README.md) | **한국어**

<img width="97" height="110" alt="image" src="https://github.com/user-attachments/assets/70488b9b-4ba1-4839-a428-5697e95d04bb" />

**Bit-perfect sample rate switching for Apple Music on Mac.**

Mac의 Music 앱용 메뉴바 앱입니다.

1. **샘플레이트 자동 전환**: 곡이 바뀔 때마다 출력 장치의 샘플레이트를 그 곡에 맞춥니다.
2. **전환 시 무음 삽입**: 샘플레이트가 바뀔 때 DAC가 새 샘플레이트로 전환을 마칠 때까지 재생을 멈추고 기다린 뒤, 곡을 처음부터 재생합니다.

## 시작하기

Music 앱의 Apple Music 스트리밍과 보관함의 로컬 파일을 모두 지원합니다.
**Apple Silicon Mac 전용이며, macOS 27.0.1에서만 테스트했습니다.**

1. [Releases](https://github.com/blancgoat/seamless-rate-switcher/releases/latest)에서 `Seamless-Rate-Switcher-<버전>.zip`을 받아 압축을 풀고, `Seamless Rate Switcher.app`을 `/Applications`에 넣고 실행합니다.
   - 서명되지 않은 앱이라 처음 열 때 "Apple이 악성 코드가 없는지 확인할 수 없음" 경고가 뜹니다. **시스템 설정 → 개인정보 보호 및 보안**에서 **그래도 열기**를 누르면 됩니다. 또는 터미널에서 아래 명령을 실행한 뒤 다시 엽니다.

     ```bash
     xattr -dr com.apple.quarantine "/Applications/Seamless Rate Switcher.app"
     ```

2. 메뉴바에 **♫ 44.1k** 처럼 음표와 현재 출력 장치의 샘플레이트가 표시됩니다.
3. Music 앱에서 곡을 재생하면 곡마다 샘플레이트가 자동으로 맞춰집니다.
4. 처음 한 번 "Music을 제어하려고 합니다" 권한 창이 뜹니다. **허용**을 눌러 주세요. 전환 중 일시정지/재개와 로컬 파일의 샘플레이트 확인에 필요합니다.

## 기다리는 시간 정하기

샘플레이트가 바뀐 뒤 DAC가 실제로 소리를 낼 수 있게 되기까지의 시간은 장비마다 다릅니다. 두 가지 방법 중 하나로 정합니다.

### 고정 시간

<img width="296" height="258" alt="image" src="https://github.com/user-attachments/assets/8e52f98f-0eca-4c92-9c0e-278343a2ac76" />

메뉴바 아이콘 → **Pause While Switching** 아래 슬라이더로 0~20초 사이에서 정합니다 (기본 5초). 옆 칸에 숫자를 넣고 Enter를 눌러 10ms 단위로 맞출 수도 있습니다.

- 곡이 바뀔 때 **앞부분이 잘리면** 늘립니다.
- **멈춰 있는 시간이 길게 느껴지면** 줄입니다.

### 준비 확인 스크립트

<img width="334" height="235" alt="image" src="https://github.com/user-attachments/assets/2a7cfe7e-986d-4572-8908-0b8e52c5e820" />

고정 시간 대신, 재생 장치(DAC)가 실제로 준비되는 순간에 바로 재생할 수도 있습니다.

1. 재생 장치(DAC)가 새 샘플레이트로 준비를 마치면 **exit 0으로 끝나는** 스크립트를 준비합니다.
   - 앱은 스크립트가 끝나는 즉시 재생합니다. 0이 아닌 값으로 끝나면 실패로 기록하지만, 재생은 똑같이 바로 합니다.
   - 20초 안에 끝나지 않으면 스크립트를 중단하고 재생합니다.
2. 메뉴바 아이콘 → **Pause While Switching** 아래 **Choose Ready Script…** 에서 그 스크립트를 등록합니다.

MOTU UltraLite mk5용 스크립트가 예제로 준비되어 있습니다 (펌웨어 2.1.2 기준). 같은 모델을 쓰시는 분은 빌드해서 등록해 보세요.

```bash
example_ready_scripts/motu-ultralite-mk5/build.sh
```

## 알아둘 점

- **이 앱은 Music을 직접 제어합니다.** 샘플레이트가 바뀌는 곡에서는 Music이 몇 초간 일시정지되는데, DAC가 새 샘플레이트로 전환을 마칠 때까지 기다리는 정상 동작입니다. **재생 버튼을 누르지 말고 기다려 주세요.** 기다리는 동안 메뉴바 아이콘이 음표(♫)에서 쉼표(<img width="50" height="25" alt="image" src="https://github.com/user-attachments/assets/8fbe970e-9dab-426c-a7a4-7971d1e1f7e6" />)
로 바뀌고, 다시 재생되면 음표로 돌아옵니다.
- 앱을 켜기 전부터 재생 중이던 Apple Music 곡은 다음 곡부터 샘플레이트가 맞춰집니다. 로컬 파일은 바로 맞춰집니다.
- 출력 장치가 지원하지 않는 샘플레이트는 건너뜁니다.
- Music 앱의 내부 로그를 읽어서 동작하기 때문에, macOS나 Music 앱 업데이트 후 동작하지 않을 수 있습니다.

## 제거

`Seamless Rate Switcher.app`을 휴지통으로 옮깁니다. macOS는 앱을 지워도 설정을 남겨 두니, 설정까지 지우려면 아래 명령을 실행하세요.

```bash
defaults delete dev.blancgoat.SeamlessRateSwitcher
tccutil reset AppleEvents dev.blancgoat.SeamlessRateSwitcher
```

로그인 시 실행을 켜 두셨다면 **시스템 설정 → 일반 → 로그인 항목**에서도 지워 주세요.

## 라이선스

[GNU General Public License v3.0](LICENSE). 자유롭게 쓰고, 고치고, 판매할 수도 있지만, 배포하는 버전은 같은 라이선스로 소스를 공개해야 합니다.

## 빌드

Xcode 없이 Command Line Tools만으로 빌드할 수 있습니다.

```bash
scripts/bundle.sh            # build/Seamless Rate Switcher.app 생성
scripts/bundle.sh --install  # /Applications에 설치하고 실행
```

Command Line Tools 환경에서는 SwiftPM 기본 빌드 시스템이 실패할 수 있어서, 스크립트는 `--build-system native`로 빌드합니다.
