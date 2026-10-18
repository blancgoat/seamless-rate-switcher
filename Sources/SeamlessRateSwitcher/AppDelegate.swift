import AppKit
import NoteGlyph
import OSLog
import RateCore
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSTextFieldDelegate {
    private let switcher = RateSwitcher()
    private var statusItem: NSStatusItem!
    private var history: [(Date, RateSwitcher.Message)] = []
    private let historyLimit = 30

    private static let log = Logger(subsystem: "dev.blancgoat.SeamlessRateSwitcher", category: "switch")
    private static let settleEnabledKey = "settleEnabled"
    /// 전환 시 일시정지 후 추가 대기(ms). 인터페이스마다 클럭을 다시 잡는 시간이 달라 사용자가 정한다
    private static let settleDelayKey = "settleDelayMs"
    /// 준비 확인 스크립트 경로 (없으면 고정 대기 시간만 사용)
    private static let readyScriptKey = "readyScriptPath"
    /// 장치가 rate 변경을 확인한 뒤에도 클럭을 다 잡기까지 수 초 걸리는 인터페이스가 많아 넉넉하게 잡는다
    private static let defaultSettleDelayMs = 5000
    private static let sliderMaxMs = 20000

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.migrateDefaultsFromOldName()
        UserDefaults.standard.register(defaults: [Self.settleEnabledKey: true, Self.settleDelayKey: Self.defaultSettleDelayMs])
        // 이전 버전은 -1을 "끄기"로 저장했다
        if UserDefaults.standard.integer(forKey: Self.settleDelayKey) < 0 {
            UserDefaults.standard.set(false, forKey: Self.settleEnabledKey)
            UserDefaults.standard.set(Self.defaultSettleDelayMs, forKey: Self.settleDelayKey)
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        applySettleDelay()
        applyReadyScript()
        switcher.onMessage = { [weak self] message in
            guard let self else { return }
            // 최근 기록과 같은 내용을 시스템 로그에도 남긴다 (log show --predicate 'subsystem == "dev.blancgoat.SeamlessRateSwitcher"')
            switch message {
            case let .info(text): Self.log.info("\(text, privacy: .public)")
            case let .action(text): Self.log.notice("\(text, privacy: .public)")
            case let .warning(text): Self.log.error("\(text, privacy: .public)")
            }
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
        button.image = NoteGlyph.menuBarImage
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
        for key in [settleEnabledKey, settleDelayKey] where standard.object(forKey: key) == nil {
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

        let settle = NSMenuItem(title: L("Pause While Switching"), action: #selector(toggleSettle), keyEquivalent: "")
        settle.target = self
        settle.state = settleEnabled ? .on : .off
        settle.toolTip = L("Pauses only when the sample rate changes. When the next track’s rate is known in advance, pauses just before the current track ends.")
        menu.addItem(settle)
        if settleEnabled {
            if readyScriptURL == nil {
                let sliderItem = NSMenuItem()
                sliderItem.view = makeSettleSliderView()
                menu.addItem(sliderItem)
            } else {
                // 스크립트가 준비 시점을 정하므로 고정 대기 시간은 숨긴다
                menu.addItem(disabled: "    " + L("Delay: decided by the ready script"))
            }
            menu.addItem(makeReadyScriptItem())
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

    // MARK: - 전환 시 일시정지

    private var settleEnabled: Bool { UserDefaults.standard.bool(forKey: Self.settleEnabledKey) }
    private var settleDelayMs: Int { UserDefaults.standard.integer(forKey: Self.settleDelayKey) }
    private weak var settleSlider: NSSlider?
    private weak var settleField: NSTextField?

    private func applySettleDelay() {
        switcher.settleDelay = settleEnabled ? TimeInterval(settleDelayMs) / 1000 : nil
    }

    /// 0~20초 범위, 10ms 단위로 맞춰 저장하고 슬라이더·입력칸을 서로 맞춘다
    private func setSettleDelay(_ ms: Int) {
        let clamped = min(max(Int((Double(ms) / 10).rounded()) * 10, 0), Self.sliderMaxMs)
        UserDefaults.standard.set(clamped, forKey: Self.settleDelayKey)
        applySettleDelay()
        settleSlider?.doubleValue = Double(clamped)
        settleField?.stringValue = "\(clamped)"
    }

    @objc private func toggleSettle() {
        UserDefaults.standard.set(!settleEnabled, forKey: Self.settleEnabledKey)
        applySettleDelay()
        applyReadyScript()
    }

    /// 메뉴 안에 들어가는 라벨 + 입력칸 + 슬라이더 (0~20초, 10ms 단위).
    /// 슬라이더는 드래그하는 동안 바로 반영되고, 입력칸은 클릭해서 숫자를 넣고 Enter로 반영한다.
    /// (슬라이더 1px이 약 85ms라 10ms 단위는 입력칸으로 맞춘다)
    private func makeSettleSliderView() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 50))
        let current = min(settleDelayMs, Self.sliderMaxMs)

        let label = NSTextField(labelWithString: L("Extra delay"))
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 34, y: 28, width: 120, height: 16)

        let field = NSTextField(string: "\(current)")
        field.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        field.alignment = .right
        field.controlSize = .small
        field.bezelStyle = .roundedBezel
        field.frame = NSRect(x: 178, y: 26, width: 62, height: 20)
        // Enter는 메뉴가 받으면 메뉴가 닫히므로 delegate에서 직접 처리한다 (control(_:textView:doCommandBy:))
        field.delegate = self

        let unit = NSTextField(labelWithString: "ms")
        unit.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        unit.textColor = .secondaryLabelColor
        unit.frame = NSRect(x: 244, y: 28, width: 24, height: 16)

        let slider = MenuSlider(value: Double(current), minValue: 0, maxValue: Double(Self.sliderMaxMs),
                                target: self, action: #selector(settleSliderChanged(_:)))
        slider.isContinuous = true
        slider.frame = NSRect(x: 30, y: 4, width: 236, height: 20)

        [label, field, unit, slider].forEach(view.addSubview)
        settleSlider = slider
        settleField = field
        return view
    }

    @objc private func settleSliderChanged(_ sender: NSSlider) {
        setSettleDelay(Int(sender.doubleValue))
    }

    /// Enter를 누르면 0~20000, 10ms 단위로 맞춰 바로 입력칸에 다시 보여 준다 (입력 중에는 건드리지 않아 커서가 유지된다).
    /// true를 돌려줘 Enter가 메뉴까지 가지 않게 한다 (메뉴가 받으면 닫힌다).
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === settleField, selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        let digits = textView.string.filter { ("0"..."9").contains($0) }
        setSettleDelay(Int(digits.prefix(6)) ?? 0)
        textView.string = settleField?.stringValue ?? ""
        textView.selectAll(nil)
        return true
    }


    // MARK: - 준비 확인 스크립트

    private var readyScriptURL: URL? {
        UserDefaults.standard.string(forKey: Self.readyScriptKey).map { URL(fileURLWithPath: $0) }
    }

    private func applyReadyScript() {
        switcher.readyScript = readyScriptURL
    }

    private func setReadyScript(_ url: URL?) {
        UserDefaults.standard.set(url?.path, forKey: Self.readyScriptKey)
        applyReadyScript()
    }

    /// 스크립트가 없으면 누르면 바로 선택 창이 뜨는 항목, 있으면 "지우기"만 있는 하위 메뉴.
    /// 다른 스크립트로 바꾸려면 지운 뒤 다시 선택한다.
    private func makeReadyScriptItem() -> NSMenuItem {
        guard let url = readyScriptURL else {
            let choose = NSMenuItem(title: "    " + L("Choose Ready Script…"), action: #selector(chooseReadyScript), keyEquivalent: "")
            choose.target = self
            choose.toolTip = L("Resumes as soon as the script exits. Even if it fails, playback resumes right away.")
            return choose
        }
        let item = NSMenuItem(title: "    " + L("Ready Script: %@", url.lastPathComponent), action: nil, keyEquivalent: "")
        item.toolTip = url.path
        let submenu = NSMenu()
        let remove = NSMenuItem(title: L("Remove Ready Script"), action: #selector(removeReadyScript), keyEquivalent: "")
        remove.target = self
        submenu.addItem(remove)
        item.submenu = submenu
        return item
    }

    @objc private func chooseReadyScript() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = L("Choose a script that exits 0 when the audio interface is ready.")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url, confirmReadyScript(url) else { return }
        setReadyScript(url)
    }

    /// 스크립트는 샘플레이트가 바뀔 때마다 사용자 권한으로 자동 실행되므로, 등록 전에 위험을 알리고 확인받는다.
    private func confirmReadyScript(_ url: URL) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Only use scripts you trust")
        alert.informativeText = L("This script will run automatically with your user permissions every time the sample rate changes. Scripts downloaded from the internet may contain malicious code. You are responsible for any script you choose to run.") + "\n\n" + url.path
        alert.addButton(withTitle: L("Cancel"))           // 기본 버튼: 실수로 Enter를 눌러도 등록되지 않게
        alert.addButton(withTitle: L("Use This Script"))
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
    }

    @objc private func removeReadyScript() {
        setReadyScript(nil)
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

/// 메뉴 안에서 쓰는 슬라이더. 기본 NSSlider는 드래그하다 메뉴 밖에서 버튼을 떼면 메뉴가 그 이벤트를 받아 닫히므로,
/// 누른 순간부터 뗄 때까지의 마우스 이벤트를 직접 받아 처리한다.
private final class MenuSlider: NSSlider {
    override func mouseDown(with event: NSEvent) {
        update(with: event)
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            update(with: next)
            if next.type == .leftMouseUp { break }
        }
    }

    private func update(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let knob = (cell as? NSSliderCell)?.knobThickness ?? 0
        let usable = max(bounds.width - knob, 1)
        let fraction = min(max((point.x - knob / 2) / usable, 0), 1)
        doubleValue = minValue + fraction * (maxValue - minValue)
        sendAction(action, to: target)
    }
}
