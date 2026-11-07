import AppKit
import RateCore
import ServiceManagement
import SwiftUI

/// 설정 키. 메뉴·설정 창·AppDelegate가 같이 쓴다.
enum SettingsKey {
    static let settleEnabled = "settleEnabled"
    /// 전환 시 일시정지 후 추가 대기(ms). 인터페이스마다 클럭을 다시 잡는 시간이 달라 사용자가 정한다
    static let settleDelay = "settleDelayMs"
    /// 준비 확인 스크립트 경로 (없으면 고정 대기 시간만 사용)
    static let readyScript = "readyScriptPath"
    /// 메뉴 막대 아이콘 옆 샘플레이트 표시: off(아이콘만) / simple(48k) / detailed(다음 곡·전환 단계까지)
    static let menuBarRateStyle = "menuBarRateStyle"
    /// 샘플레이트 자동 전환. 예전에 지운 같은 기능의 키(autoSwitchEnabled)는 꺼 둔 채 남아 있을 수 있어 새 키를 쓴다
    static let autoSwitch = "autoSwitch"

    static let maxDelayMs = 20000
}

/// ⌘,로 여는 설정 창. 한 번 정해 두는 표시·실행 설정만 둔다 (전환 관련은 자주 보도록 메뉴에 있다).
/// 값은 UserDefaults에 저장하고, AppDelegate가 변경을 감지해 적용한다.
final class SettingsWindowController: NSWindowController {
    init() {
        let hosting = NSHostingController(rootView: SettingsView(state: SettingsViewState()))
        let window = NSWindow(contentViewController: hosting)
        window.title = L("Settings")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        if window?.isVisible != true { window?.center() }
        NSApp.activate(ignoringOtherApps: true)  // 메뉴바 전용 앱이라 창을 앞으로 가져와야 한다
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// UserDefaults에 저장하지 않는 화면 상태 (이 툴체인에는 @State 매크로 플러그인이 없어 ObservableObject로 둔다)
private final class SettingsViewState: ObservableObject {
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
}

private struct SettingsView: View {
    @ObservedObject var state: SettingsViewState

    @AppStorage(SettingsKey.menuBarRateStyle) private var rateStyle = "simple"

    var body: some View {
        Form {
            Section {
                Picker(selection: $rateStyle) {
                    Text(L("Off")).tag("off")
                    Text(L("Current Sample Rate")).tag("simple")
                    Text(L("Detailed")).tag("detailed")
                } label: {
                    Text(L("Sample Rate in Menu Bar"))
                    Text(L("Current Sample Rate: the output device’s rate, like 48k.") + "\n"
                         + L("Detailed: also the next track’s rate and each step of a switch.") + "\n"
                         + L("⚙︎ waiting for Core Audio · 1.2s extra delay · ··· ready script"))
                }
                Toggle(L("Launch at Login"), isOn: Binding(get: { state.launchAtLogin }, set: setLaunchAtLogin))
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            state.launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        let service = SMAppService.mainApp
        do {
            if on { try service.register() } else { try service.unregister() }
        } catch {
            let alert = NSAlert()
            alert.messageText = L("Couldn’t Change Launch at Login")
            alert.informativeText = error.localizedDescription + "\n" + L("The app may need to be in /Applications.")
            alert.runModal()
        }
        state.launchAtLogin = service.status == .enabled
    }
}
