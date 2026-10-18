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

## 기다리는 시간 정하기

샘플레이트가 바뀐 뒤 DAC가 실제로 소리를 낼 수 있게 되기까지의 시간은 장비마다 다릅니다. 두 가지 방법 중 하나로 정합니다.

### 고정 시간

메뉴바 아이콘 → **Pause While Switching** 아래 슬라이더로 0~20초 사이에서 정합니다 (기본 5초). 옆 칸에 숫자를 넣고 Enter를 눌러 10ms 단위로 맞출 수도 있습니다.

- 곡이 바뀔 때 **앞부분이 잘리면** 늘립니다.
- **멈춰 있는 시간이 길게 느껴지면** 줄입니다.

### 준비 확인 스크립트

장비가 "준비됐다"는 신호를 알려주는 방법이 있다면, 고정 시간 대신 그 신호를 기다리는 스크립트를 등록할 수 있습니다.

1. 메뉴바 아이콘 → **Pause While Switching** 아래 **Choose Ready Script…** 를 누르고 스크립트 파일을 고릅니다.
2. 장치가 새 샘플레이트를 받아들이면 앱이 스크립트를 실행하고, **스크립트가 끝나는 즉시 재생**합니다.
   - 스크립트가 실패하거나 15초를 넘겨도 따로 기다리지 않고 바로 재생합니다.
   - 스크립트가 등록돼 있으면 고정 시간 슬라이더는 쓰지 않습니다.
3. 다른 스크립트로 바꾸려면 **Remove Ready Script** 로 지운 뒤 다시 고릅니다.

스크립트에는 아래 환경 변수가 전달됩니다.

| 변수 | 예 |
|---|---|
| `SRS_SAMPLE_RATE` | `96000` |
| `SRS_DEVICE_UID` | `com_motu_driver_gen5_control_interface:ul5eff6f7a` |
| `SRS_DEVICE_NAME` | `UltraLite-mk5` |

> **신뢰할 수 있는 스크립트만 사용하세요.** 스크립트는 샘플레이트가 바뀔 때마다 사용자 권한으로 자동 실행됩니다. 인터넷에서 받은 스크립트에는 악성 코드가 있을 수 있고, 실행 결과는 사용자 책임입니다.

#### 예제: MOTU UltraLite mk5

[`example_ready_scripts/motu-ultralite-mk5`](example_ready_scripts/motu-ultralite-mk5)는 MOTU UltraLite mk5가 샘플레이트 전환을 마치고 출력을 다시 여는 순간을 기다리는 스크립트입니다. 고정 시간을 맞출 필요 없이, 장비가 준비되는 즉시 재생됩니다.

1. 빌드합니다. 같은 폴더에 `motu-ultralite-mk5` 실행 파일이 생깁니다.

   ```bash
   example_ready_scripts/motu-ultralite-mk5/build.sh
   ```

2. **Choose Ready Script…** 에서 그 파일을 고릅니다.
3. **CueMix 5의 비밀번호를 꺼 주세요.** 비밀번호가 켜져 있으면 동작하지 않고, 앱은 기다리지 않고 바로 재생합니다.

- MOTU Gen 5 드라이버와 함께 설치되는 로컬 서비스에 CueMix 5와 같은 방식으로 접속해서 장비 상태를 읽기만 합니다. 장비 설정은 바꾸지 않습니다.
- **MOTU와 무관한 비공식 스크립트입니다.** 문서화되지 않은 장비 신호를 쓰기 때문에, MOTU 드라이버나 펌웨어 업데이트 후 동작하지 않을 수 있습니다.
- UltraLite mk5에서만 확인했습니다. 같은 Gen 5 계열(828 mk5 등)에서도 동작할 가능성이 있지만 확인하지 않았습니다.

## 알아둘 점

- **이 앱은 Music을 직접 제어합니다.** 샘플레이트가 바뀌는 곡에서는 Music이 몇 초간 일시정지되는데, DAC가 새 샘플레이트로 전환을 마칠 때까지 기다리는 정상 동작입니다. **재생 버튼을 누르지 말고 기다려 주세요.** 기다리는 동안 메뉴바 아이콘이 음표(♫)에서 쉼표로 바뀌고, 다시 재생되면 음표로 돌아옵니다.
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
