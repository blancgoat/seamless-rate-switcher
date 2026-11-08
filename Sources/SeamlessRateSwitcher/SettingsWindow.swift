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
    /// 샘플레이트 표기: short(44.1k) / shortHz(44.1kHz) / full(44100) / fullHz(44100 Hz).
    /// 메뉴바에만 쓴다 (메뉴 안은 44100 Hz로 고정)
    static let rateFormat = "rateFormat"
    /// 다음 곡 rate가 다를 때 곡이 끝나기 100ms 전에 멈춘다 (끄면 곡 끝에 맞춰 멈춘다)
    static let pauseBeforeEnd = "pauseBeforeEnd"
    static let pauseBeforeEndMs = 100
    /// 곡 전환 효과(AutoMix·크로스페이드) 앞에서는 설정과 관계없이 항상 이만큼 앞서 멈춘다 (RateSwitcher.transitionLead)
    static let transitionLeadMs = 150

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
    @ObservedObject var updates = UpdateChecker.shared

    @AppStorage(SettingsKey.menuBarRateStyle) private var rateStyle = "simple"
    @AppStorage(SettingsKey.rateFormat) private var rateFormat = "short"
    @AppStorage(SettingsKey.pauseBeforeEnd) private var pauseBeforeEnd = true

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
                // 메뉴바에 샘플레이트를 표시하지 않으면 표기 방식도 의미가 없다
                if rateStyle != "off" {
                    Picker(L("Sample Rate Format"), selection: $rateFormat) {
                        Text("44.1k").tag("short")
                        Text("44.1kHz").tag("shortHz")
                        Text("44100").tag("full")
                        Text("44100 Hz").tag("fullHz")
                    }
                }
                Toggle(L("Launch at Login"), isOn: Binding(get: { state.launchAtLogin }, set: setLaunchAtLogin))
            }
            Section {
                Toggle(isOn: $pauseBeforeEnd) {
                    Text(L("Trim Track Ends for Clean Switches"))
                    Text(L("Cuts the last 0.1 s of a track so the next one never starts at the wrong sample rate. Turn off if your tracks play right up to the end.") + "\n"
                         + L("Always on while AutoMix or Crossfade is on."))
                }
            }
            Section {
                LabeledContent {
                    HStack(spacing: 8) {
                        updateStatusView
                        Button(L("Check for Updates")) { updates.check() }
                            .disabled(updates.status == .checking)
                    }
                } label: {
                    Text(L("Version %@", UpdateChecker.currentVersion))
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            state.launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    @ViewBuilder private var updateStatusView: some View {
        switch updates.status {
        case .idle:
            EmptyView()
        case .checking:
            ProgressView().controlSize(.small)
        case .upToDate:
            Text(L("Up to date")).foregroundStyle(.secondary)
        case let .available(release):
            Button(L("Download %@…", release.version)) { updates.openReleasePage() }
                .buttonStyle(.link)
        case let .failed(reason):
            Text(L("Couldn’t check")).foregroundStyle(.secondary).help(reason)
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
