import AppKit
import NoteGlyph
import RateCore
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let switcher = RateSwitcher()
    private var statusItem: NSStatusItem!
    private var history: [(Date, RateSwitcher.Message)] = []
    private let historyLimit = 30

    private static let enabledKey = "autoSwitchEnabled"
    private static let settleEnabledKey = "settleEnabled"
    /// 전환 시 일시정지 후 추가 대기(ms). 인터페이스마다 클럭을 다시 잡는 시간이 달라 사용자가 정한다
    private static let settleDelayKey = "settleDelayMs"
    /// 클럭을 다시 잡는 데 2초 넘게 걸리는 인터페이스가 많아 넉넉하게 잡는다
    private static let defaultSettleDelayMs = 3000
    private static let sliderMaxMs = 10000.0
    private static let inputMaxMs = 30000

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.migrateDefaultsFromOldName()
        UserDefaults.standard.register(defaults: [Self.enabledKey: true, Self.settleEnabledKey: true, Self.settleDelayKey: Self.defaultSettleDelayMs])
        // 이전 버전은 -1을 "끄기"로 저장했다
        if UserDefaults.standard.integer(forKey: Self.settleDelayKey) < 0 {
            UserDefaults.standard.set(false, forKey: Self.settleEnabledKey)
            UserDefaults.standard.set(Self.defaultSettleDelayMs, forKey: Self.settleDelayKey)
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        switcher.isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        applySettleDelay()
        switcher.onMessage = { [weak self] message in
            guard let self else { return }
            history.append((Date(), message))
            if history.count > historyLimit { history.removeFirst(history.count - historyLimit) }
        }
        switcher.onStatusChange = { [weak self] in self?.updateTitle() }

        do {
            try switcher.start()
        } catch {
            history.append((Date(), .warning(L("Failed to start log stream: %@", error.localizedDescription))))
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
        button.image = NoteGlyph.menuBarImage(slashed: !switcher.isEnabled)
        button.image?.accessibilityDescription = "Seamless Rate Switcher"
        button.imagePosition = .imageLeading
        button.title = rate.map { " " + Self.shortRate($0) } ?? ""
        button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .medium)
        button.appearsDisabled = !switcher.isRunning
    }

    /// 이름을 바꾸기 전(LikeLosslessSwitcher) 설정을 한 번만 옮겨온다. 번들 ID가 달라 설정 저장소가 다르다.
    /// register(defaults:) 전에 불러야 "값 없음"을 구분할 수 있다.
    private static func migrateDefaultsFromOldName() {
        let standard = UserDefaults.standard
        let migratedKey = "migratedFromLikeLosslessSwitcher"
        guard !standard.bool(forKey: migratedKey) else { return }
        standard.set(true, forKey: migratedKey)
        guard let old = UserDefaults(suiteName: "dev.blancgoat.LikeLosslessSwitcher") else { return }
        for key in [enabledKey, settleEnabledKey, settleDelayKey] where standard.object(forKey: key) == nil {
            if let value = old.object(forKey: key) { standard.set(value, forKey: key) }
        }
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
            menu.addItem(disabled: L("No output device"))
        }
        if let target = switcher.target {
            menu.addItem(disabled: L("Last track: %@Hz · %@", Self.shortRate(target.sampleRate), target.reason))
        }
        if !switcher.isRunning {
            menu.addItem(disabled: "⚠︎ " + L("Stopped reading Music logs (please relaunch the app)"))
        }
        if isLosslessSwitcherRunning {
            menu.addItem(disabled: "⚠︎ " + L("LosslessSwitcher is running. Both apps will fight over the sample rate"))
        }

        menu.addItem(.separator())

        let toggle = NSMenuItem(title: L("Auto Switch"), action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        toggle.state = switcher.isEnabled ? .on : .off
        menu.addItem(toggle)

        let settle = NSMenuItem(title: L("Pause While Switching"), action: #selector(toggleSettle), keyEquivalent: "")
        settle.target = self
        settle.state = settleEnabled ? .on : .off
        settle.toolTip = L("Pauses only when the sample rate changes. Restarts the track from the beginning if it was within the first 3 seconds.")
        menu.addItem(settle)
        if settleEnabled {
            let sliderItem = NSMenuItem()
            sliderItem.view = makeSettleSliderView()
            menu.addItem(sliderItem)
            let input = NSMenuItem(title: "    " + L("Set Delay Manually…"), action: #selector(inputSettleDelay), keyEquivalent: "")
            input.target = self
            menu.addItem(input)
        }

        let login = NSMenuItem(title: L("Launch at Login"), action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        let historyItem = NSMenuItem(title: L("Recent Activity"), action: nil, keyEquivalent: "")
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
        if history.isEmpty { historyMenu.addItem(disabled: L("None")) }
        historyItem.submenu = historyMenu
        menu.addItem(historyItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
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

    // MARK: - 전환 시 일시정지

    private var settleEnabled: Bool { UserDefaults.standard.bool(forKey: Self.settleEnabledKey) }
    private var settleDelayMs: Int { UserDefaults.standard.integer(forKey: Self.settleDelayKey) }
    private weak var settleLabel: NSTextField?

    private func applySettleDelay() {
        switcher.settleDelay = settleEnabled ? TimeInterval(settleDelayMs) / 1000 : nil
    }

    private func setSettleDelay(_ ms: Int) {
        UserDefaults.standard.set(ms, forKey: Self.settleDelayKey)
        applySettleDelay()
        settleLabel?.stringValue = Self.settleLabelText(ms)
    }

    private static func settleLabelText(_ ms: Int) -> String {
        L("Extra delay  %ldms", ms) + (Double(ms) > sliderMaxMs ? "  " + L("(custom)") : "")
    }

    @objc private func toggleSettle() {
        UserDefaults.standard.set(!settleEnabled, forKey: Self.settleEnabledKey)
        applySettleDelay()
    }

    /// 메뉴 안에 들어가는 라벨 + 슬라이더 (0~10초, 100ms 단위). 드래그하는 동안 바로 반영된다.
    private func makeSettleSliderView() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 46))
        let label = NSTextField(labelWithString: Self.settleLabelText(settleDelayMs))
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 34, y: 26, width: 230, height: 16)
        let slider = NSSlider(value: min(Double(settleDelayMs), Self.sliderMaxMs), minValue: 0, maxValue: Self.sliderMaxMs,
                              target: self, action: #selector(settleSliderChanged(_:)))
        slider.isContinuous = true
        slider.frame = NSRect(x: 30, y: 4, width: 236, height: 20)
        view.addSubview(label)
        view.addSubview(slider)
        settleLabel = label
        return view
    }

    @objc private func settleSliderChanged(_ sender: NSSlider) {
        setSettleDelay(Int((sender.doubleValue / 100).rounded()) * 100)
    }

    @objc private func inputSettleDelay() {
        let alert = NSAlert()
        alert.messageText = L("Extra Delay After Switching")
        alert.informativeText = L("After the device confirms the new sample rate, wait this long before resuming playback. (0–%ld ms)", Self.inputMaxMs)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        field.stringValue = "\(settleDelayMs)"
        field.placeholderString = "ms"
        alert.accessoryView = field
        alert.addButton(withTitle: L("OK"))
        alert.addButton(withTitle: L("Cancel"))
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)  // 메뉴바 전용 앱이라 창을 앞으로 가져와야 입력 가능
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let ms = Int(field.stringValue.trimmingCharacters(in: .whitespaces)), (0...Self.inputMaxMs).contains(ms) else {
            NSSound.beep()
            return
        }
        setSettleDelay(ms)
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
            alert.messageText = L("Couldn’t Change Launch at Login")
            alert.informativeText = error.localizedDescription + "\n" + L("The app may need to be in /Applications.")
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
