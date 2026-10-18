import AppKit
import RateCore
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let switcher = RateSwitcher()
    private var statusItem: NSStatusItem!
    private var history: [(Date, RateSwitcher.Message)] = []
    private let historyLimit = 30

    private static let enabledKey = "autoSwitchEnabled"

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [Self.enabledKey: true])

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        switcher.isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        switcher.onMessage = { [weak self] message in
            guard let self else { return }
            history.append((Date(), message))
            if history.count > historyLimit { history.removeFirst(history.count - historyLimit) }
        }
        switcher.onStatusChange = { [weak self] in self?.updateTitle() }

        do {
            try switcher.start()
        } catch {
            history.append((Date(), .warning("log stream 실행 실패: \(error.localizedDescription)")))
        }
        updateTitle()
    }

    func applicationWillTerminate(_ notification: Notification) {
        switcher.stop()
    }

    // MARK: - 메뉴바 표시

    private func updateTitle() {
        guard let button = statusItem.button else { return }
        let rate = AudioDevice.defaultOutput?.nominalSampleRate
        button.image = NSImage(systemSymbolName: switcher.isEnabled ? "waveform" : "waveform.slash",
                               accessibilityDescription: "Like LosslessSwitcher")
        button.imagePosition = .imageLeading
        button.title = rate.map { " " + Self.shortRate($0) } ?? ""
        button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .medium)
        button.appearsDisabled = !switcher.isRunning
    }

    /// 44100 → "44.1k", 96000 → "96k"
    static func shortRate(_ rate: Double) -> String {
        let k = rate / 1000
        return k.rounded() == k ? "\(Int(k))k" : String(format: "%.1fk", k)
    }

    // MARK: - 메뉴 (열 때마다 새로 구성)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if let device = AudioDevice.defaultOutput {
            menu.addItem(disabled: "\(device.name) · \(Self.shortRate(device.nominalSampleRate))Hz")
        } else {
            menu.addItem(disabled: "출력 장치 없음")
        }
        if let target = switcher.target {
            menu.addItem(disabled: "마지막 곡: \(Self.shortRate(target.sampleRate))Hz · \(target.reason)")
        }
        if !switcher.isRunning {
            menu.addItem(disabled: "⚠︎ Music 로그 수신 중지됨 (앱을 다시 실행하세요)")
        }
        if isLosslessSwitcherRunning {
            menu.addItem(disabled: "⚠︎ LosslessSwitcher가 실행 중이에요. 같이 쓰면 서로 rate를 바꿉니다")
        }

        menu.addItem(.separator())

        let toggle = NSMenuItem(title: "자동 전환", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        toggle.state = switcher.isEnabled ? .on : .off
        menu.addItem(toggle)

        let login = NSMenuItem(title: "로그인 시 실행", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        let historyItem = NSMenuItem(title: "최근 기록", action: nil, keyEquivalent: "")
        let historyMenu = NSMenu()
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm:ss"
        for (date, message) in history.reversed() {
            let text: String
            switch message {
            case let .info(t): text = "   \(t)"
            case let .action(t): text = t
            case let .warning(t): text = "⚠︎ \(t)"
            }
            historyMenu.addItem(disabled: "\(clock.string(from: date))  \(text)")
        }
        if history.isEmpty { historyMenu.addItem(disabled: "없음") }
        historyItem.submenu = historyMenu
        menu.addItem(historyItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private var isLosslessSwitcherRunning: Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.localizedName == "LosslessSwitcher" && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
    }

    @objc private func toggleEnabled() {
        switcher.isEnabled.toggle()
        UserDefaults.standard.set(switcher.isEnabled, forKey: Self.enabledKey)
        updateTitle()
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "로그인 시 실행 설정 실패"
            alert.informativeText = "\(error.localizedDescription)\n앱이 /Applications에 있어야 할 수 있어요."
            alert.runModal()
        }
    }
}

private extension NSMenu {
    func addItem(disabled title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        addItem(item)
    }
}
