import AppKit
import NoteGlyph
import OSLog
import RateCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSTextFieldDelegate {
    private let switcher = RateSwitcher()
    private var statusItem: NSStatusItem!
    private let activity = ActivityLog()
    private lazy var activityWindow = ActivityWindowController(log: activity)
    private lazy var settingsWindow = SettingsWindowController()

    private static let log = Logger(subsystem: "dev.blancgoat.SeamlessRateSwitcher", category: "switch")
    private static let settleEnabledKey = SettingsKey.settleEnabled
    private static let settleDelayKey = SettingsKey.settleDelay
    private static let readyScriptKey = SettingsKey.readyScript
    /// 장치가 rate 변경을 확인하면 바로 소리를 낼 수 있는 인터페이스도 있어(RME Digiface USB) 0으로 두고,
    /// 앞부분이 잘리는 인터페이스는 사용자가 늘리거나 준비 확인 스크립트를 쓴다
    private static let defaultSettleDelayMs = 0
    /// 1.2.2까지의 기본값. 그때부터 쓰던 사람은 값을 저장하지 않았어도 이 값으로 동작해 왔다
    private static let legacyDefaultSettleDelayMs = 5000
    private static let sliderMaxMs = SettingsKey.maxDelayMs

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.keepLegacyDefaultDelay()
        Self.migrateDefaultsFromOldName()
        UserDefaults.standard.register(defaults: [Self.settleEnabledKey: true, Self.settleDelayKey: Self.defaultSettleDelayMs,
                                                  SettingsKey.menuBarRateStyle: RateStyle.simple.rawValue, SettingsKey.rateFormat: RateFormat.short.rawValue])
        // 이전 버전은 -1을 "끄기"로 저장했다
        if UserDefaults.standard.integer(forKey: Self.settleDelayKey) < 0 {
            UserDefaults.standard.set(false, forKey: Self.settleEnabledKey)
            UserDefaults.standard.set(Self.defaultSettleDelayMs, forKey: Self.settleDelayKey)
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        NSApp.mainMenu = makeMainMenu()

        applySettleDelay()
        applyReadyScript()
        // 메뉴나 설정 창에서 바꾼 값을 바로 적용한다
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            applySettleDelay()
            applyReadyScript()
            // 자세히 표시는 샘플레이트가 그대로면 다시 그리지 않으므로, 표기 방식이 바뀌면 직접 다시 배치한다
            let format = Self.rateFormat
            if format != shownRateFormat {
                shownRateFormat = format
                titleView?.relayout()
            }
            updateTitle()
        }
        switcher.onMessage = { [weak self] message in
            guard let self else { return }
            // 최근 기록과 같은 내용을 시스템 로그에도 남긴다 (log show --predicate 'subsystem == "dev.blancgoat.SeamlessRateSwitcher"')
            switch message {
            // debug 단계는 디스크에 남지 않아 나중에 원인을 볼 수 없으므로 세부 기록도 info로 남긴다
            case let .detail(text): Self.log.info("\(text, privacy: .public)")
            case let .info(text): Self.log.info("\(text, privacy: .public)")
            case let .action(text): Self.log.notice("\(text, privacy: .public)")
            case let .warning(text): Self.log.error("\(text, privacy: .public)")
            }
            activity.append(message)
        }
        switcher.onStatusChange = { [weak self] in self?.updateTitle() }


        do {
            try switcher.start()
        } catch {
            activity.append(.warning(L("Failed to start log stream: %@", error.localizedDescription)))
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
        trackPhase(rate: rate)
        // 앱이 Music을 일시정지해 둔 동안은 쉼표로 바꿔서, 멈춘 게 정상 동작임을 알린다
        setIcon(switcher.isHoldingPlayback ? .rest : .note)
        let holdingNote = L("Paused while the audio interface switches sample rate. Playback resumes automatically.")
        // Music 로그 수신이 멈추면 아이콘을 흐리게 해서 앱이 동작하지 않음을 알린다
        let disabled = !switcher.isRunning
        var stepTip: String?
        var ticking = false
        if rateStyle == .detailed {
            // 글자 일부만 움직이고 색을 바꾸려고 직접 그린다
            let detailed = detailedModel(rate: rate)
            stepTip = detailed.tip
            ticking = detailed.ticking
            let view = titleView ?? makeTitleView(in: button)
            view.dimmed = disabled
            view.set(detailed.model)
        } else {
            removeTitleView()
            if button.appearsDisabled != disabled { button.appearsDisabled = disabled }
            if button.imagePosition != .imageLeading { button.imagePosition = .imageLeading }
            if button.font != Self.titleFont { button.font = Self.titleFont }
            let text = rateStyle == .simple ? rate.map { " " + Self.displayRate($0) } ?? "" : ""
            // 메뉴가 열려 있으면 0.1초마다 불리므로 바뀐 것만 넣는다
            if button.title != text {
                button.title = text
                titleWidth = nil
                applyStatusItemLength()
            }
        }
        // 애니메이션 중에는 이미지가 프레임마다 바뀌므로 설명은 버튼에 붙인다
        let tip = [switcher.isHoldingPlayback ? holdingNote : nil, stepTip].compactMap { $0 }.joined(separator: "\n")
        let label = tip.isEmpty ? "Seamless Rate Switcher" : tip
        if button.accessibilityLabel() != label { button.setAccessibilityLabel(label) }
        if button.toolTip != (tip.isEmpty ? nil : tip) { button.toolTip = tip.isEmpty ? nil : tip }
        refreshMenuStatus()
        // 메뉴가 열려 있고 시간이 흐르는 줄이 있을 때만 계속 다시 그린다
        setTitleTicking(ticking || (statusMenuOpen && steps.needsTicking))
    }

    // MARK: - 메뉴바 샘플레이트 자세히 표시

    enum RateStyle: String { case off, simple, detailed }

    private var rateStyle: RateStyle {
        UserDefaults.standard.string(forKey: SettingsKey.menuBarRateStyle).flatMap(RateStyle.init) ?? .simple
    }

    private var lastPhase: RateSwitcher.Phase = .idle
    /// 메뉴 안에 쌓아 보여 주는 전환 단계
    private let steps = SwitchSteps()
    /// 메뉴바에 결과(✓ 또는 ?)를 이때까지 보여 준다
    private var doneUntil: Date?
    private var shownOutcome: RateSwitcher.Outcome = .ready
    /// 진행 중인(또는 방금 끝난) 전환의 이전 rate. 장치는 전환 도중 새 rate가 되므로 시작할 때 기억해 둔다
    private var switchFrom: Double?
    /// 카운트다운·점 애니메이션·잠깐 보이는 표시를 위해 제목을 다시 그리는 타이머
    private var titleTicker: Timer?
    /// "자세히"일 때 버튼 위에 직접 그리는 뷰
    private var titleView: RateTitleView?

    /// 단계가 바뀐 시각과 전환 결과를 기록한다. 메뉴바 표시 설정과 관계없이 메뉴에서도 쓰므로 항상 부른다
    private func trackPhase(rate: Double?) {
        let now = Date()
        steps.track(phase: switcher.phase, outcome: switcher.lastOutcome, nextRate: switcher.nextRate,
                    deviceRate: rate)
        let phase = switcher.phase
        guard phase != lastPhase else { return }
        if lastPhase == .idle { switchFrom = rate }
        if phase == .idle {
            shownOutcome = switcher.lastOutcome
            // 확실하지 않게 끝났으면 알아챌 수 있게 조금 더 오래 보여 준다. 그만둔 전환은 표시하지 않는다
            let hold: TimeInterval? = switch shownOutcome {
            case .ready: 1.5
            case .uncertain: 4
            case .cancelled: nil
            }
            doneUntil = hold.map(now.addingTimeInterval)
        } else {
            doneUntil = nil
        }
        lastPhase = phase
    }

    /// 예정        44.1k → 96k            (96k 회색)
    /// 일시정지·Core Audio 확인  44.1k → 96k ⚙︎   (96k 회색: 장치가 아직 44.1k)
    /// 추가 대기    44.1k → 96k 1.2s      (44.1k 회색: 장치는 이미 96k)
    /// 스크립트     44.1k → 96k ···
    /// 완료         96k ✓ (1.5초) / 96k ? (4초): 준비를 확인하지 못하고 재개
    private func detailedModel(rate: Double?) -> (model: RateTitleView.Model, tip: String?, ticking: Bool) {
        let now = Date()
        let current = rate ?? 0
        // 이 전환에서 나올 수 있는 기호: 스크립트를 쓰면 ···, 아니면 정한 대기 시간의 카운트다운
        // (대기 0ms면 카운트다운이 사실상 보이지 않으므로 넣지 않는다)
        var slot = ["⚙︎", "✓", "?"]
        if readyScriptURL != nil {
            slot.append("···")
        } else if settleDelayMs > 0 {
            slot.append(Self.countdown(TimeInterval(settleDelayMs) / 1000))
        }
        func switching(_ to: Double, switched: Bool, status: String, dots: Int = 3) -> RateTitleView.Model {
            RateTitleView.Model(stage: .switching(deviceSwitched: switched), from: switchFrom, to: to, status: status, dots: dots, statusSlot: slot)
        }
        switch switcher.phase {
        case let .pausing(to):
            return (switching(to, switched: false, status: "⚙︎"), L("Pausing Music…"), false)
        case let .confirming(to):
            return (switching(to, switched: false, status: "⚙︎"), L("Waiting for Core Audio to confirm the new sample rate…"), false)
        case let .settling(to, until):
            let left = max(until.timeIntervalSince(now), 0)
            return (switching(to, switched: true, status: Self.countdown(left, from: TimeInterval(settleDelayMs) / 1000)), L("Waiting the extra delay…"), true)
        case let .readyScript(to):
            let dots = Int(now.timeIntervalSinceReferenceDate * 3) % 3 + 1
            return (switching(to, switched: true, status: "···", dots: dots), L("Running the ready script…"), true)
        case .idle:
            if let doneUntil, now < doneUntil {
                if case let .uncertain(reason) = shownOutcome {
                    let model = RateTitleView.Model(stage: .done, from: switchFrom, to: current, status: "?", statusSlot: slot)
                    return (model, L("Resumed without confirming the device is ready (%@)", reason), true)
                }
                return (RateTitleView.Model(stage: .done, from: switchFrom, to: current, status: "✓", statusSlot: slot), nil, true)
            }
            if let next = switcher.nextRate, next != current, rate != nil {
                return (RateTitleView.Model(stage: .planned, from: current, to: next),
                        L("Next track: %@", Self.displayRate(next)), false)
            }
            return (RateTitleView.Model(stage: .plain, to: current), nil, false)
        }
    }

    /// 추가 대기 카운트다운 "1.2s". 대기가 10초 이상이면 10초 미만일 때 숫자 한 칸 폭의 공백(U+2007)을 앞에 붙여
    /// 10.0 → 9.9로 넘어갈 때도 폭이 같게 한다 (대기가 짧으면 붙이지 않아 오른쪽이 비지 않게)
    private static func countdown(_ seconds: TimeInterval, from total: TimeInterval? = nil) -> String {
        let longest = total ?? seconds
        let pad = longest >= 9.95 && seconds < 9.95 ? "\u{2007}" : ""
        return pad + String(format: "%.1fs", seconds)
    }

    private func makeTitleView(in button: NSStatusBarButton) -> RateTitleView {
        let view = RateTitleView(font: Self.titleFont)
        view.rateText = { $0 > 0 ? Self.displayRate($0) : "" }
        view.icon = shownIcon
        // 기본 버튼이 아이콘과 글자 양옆에 두는 여백을 재서 똑같이 둔다 (아이콘 + " 48k" 버튼 폭 - 아이콘 - 글자)
        if let cell = button.cell?.copy() as? NSButtonCell {
            cell.image = NoteGlyph.menuBarImage(.note)
            cell.imagePosition = .imageLeading
            cell.font = Self.titleFont
            cell.title = " " + Self.displayRate(48000)
            let titleWidth = NSAttributedString(string: cell.title, attributes: [.font: Self.titleFont]).size().width
            let spare = cell.cellSize.width - (cell.image?.size.width ?? 18) - titleWidth
            if spare > 0 { view.padding = spare / 2 }
        }
        // 메뉴바 높이는 Mac마다 다르다(노치 등). 버튼 높이를 그대로 따라가야 아이콘·글자가 가운데에 온다
        view.frame = NSRect(x: 0, y: 0, width: 0, height: button.bounds.height)
        view.autoresizingMask = [.height]
        view.onWidthChange = { [weak self, weak view, weak button] width in
            self?.titleWidth = width
            self?.applyStatusItemLength()
            view?.frame = NSRect(x: 0, y: 0, width: width, height: button?.bounds.height ?? NSStatusBar.system.thickness)
        }
        button.title = ""
        button.image = nil
        button.appearsDisabled = false
        button.addSubview(view)
        titleView = view
        return view
    }

    private func removeTitleView() {
        guard let titleView, let button = statusItem.button else { return }
        titleView.removeFromSuperview()
        self.titleView = nil
        titleWidth = nil
        applyStatusItemLength()
        button.image = shownIcon
    }

    // MARK: - 메뉴 안 전환 단계 스택 (메뉴바 표시 설정과 관계없이 항상)

    private weak var deviceMenuItem: NSMenuItem?
    private var statusMenuOpen = false

    func menuWillOpen(_ menu: NSMenu) {
        statusMenuOpen = true
        heldLength = statusItem.button?.frame.width
        updateTitle()
    }

    func menuDidClose(_ menu: NSMenu) {
        statusMenuOpen = false
        heldLength = nil
        applyStatusItemLength()
        updateTitle()
    }

    /// 자세히 표시가 그리는 폭 (nil이면 버튼이 글자에 맞춰 정한다)
    private var titleWidth: CGFloat?
    /// 메뉴가 열려 있는 동안 붙잡아 둔 폭. 메뉴바 항목은 오른쪽 끝이 고정이라 폭이 줄면 왼쪽 끝이 움직이고,
    /// 열린 메뉴도 그 왼쪽 끝을 따라 옆으로 움직인다 (✓가 사라질 때 등). 그동안은 줄이지 않고 남는 자리는 오른쪽에 비워 둔다.
    /// 늘어나야 할 때는 글자가 잘리지 않게 늘린다.
    private var heldLength: CGFloat?

    private func applyStatusItemLength() {
        let natural = titleWidth ?? statusItem.button.map { $0.fittingSize.width }
        guard let natural else { return }
        if let held = heldLength {
            let length = max(held, natural)
            heldLength = length
            if statusItem.length != length { statusItem.length = length }
        } else {
            let length = titleWidth ?? NSStatusItem.variableLength
            if statusItem.length != length { statusItem.length = length }
        }
    }

    /// 장치 줄(전환 중이면 48kHz → 96kHz)과 단계 스택을 지금 상태에 맞춘다
    private func refreshMenuStatus() {
        guard statusMenuOpen else { return }
        if let device = AudioDevice.defaultOutput {
            var line = "\(device.name) · \(Self.menuRateHz(device.nominalSampleRate))"
            if let to = switcher.phase.target, to != device.nominalSampleRate { line += " → \(Self.menuRateHz(to))" }
            if deviceMenuItem?.title != line { deviceMenuItem?.title = line }
        }
        steps.sync()
    }

    private func setTitleTicking(_ ticking: Bool) {
        guard ticking != (titleTicker != nil) else { return }
        titleTicker?.invalidate()
        titleTicker = nil
        guard ticking else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.updateTitle() }
        RunLoop.main.add(timer, forMode: .common)  // 메뉴가 열려 있어도 돌게
        titleTicker = timer
    }

    /// 기본 대기 시간이 5초에서 0으로 바뀌었다. 기존 사용자가 슬라이더를 건드린 적이 없으면 저장된 값이 없어
    /// 업데이트하자마자 0이 되므로, 그동안 쓰던 5초를 저장해 둔다. 처음 설치한 사람은 0부터 시작한다.
    /// migrateDefaultsFromOldName()이 첫 실행 표시를 남기기 전에 불러야 기존 사용자를 구분할 수 있다.
    private static func keepLegacyDefaultDelay() {
        let standard = UserDefaults.standard
        // 한 번만 판단한다: 그러지 않으면 처음 설치한 사람도 두 번째 실행부터 기존 사용자로 보인다
        let checkedKey = "checkedLegacyDefaultDelay"
        guard !standard.bool(forKey: checkedKey) else { return }
        standard.set(true, forKey: checkedKey)
        guard standard.bool(forKey: "migratedFromLikeLosslessSwitcher"),
              standard.object(forKey: settleDelayKey) == nil else { return }
        standard.set(legacyDefaultSettleDelayMs, forKey: settleDelayKey)
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

    // MARK: - 아이콘 전환 애니메이션

    private var shownSymbol: NoteGlyph.Symbol?
    /// 지금 보여 주는 아이콘 이미지 (자세히 표시로 바꿀 때 직접 그리는 뷰로 넘긴다)
    private var shownIcon: NSImage?

    /// 버튼 기본 이미지 또는 자세히 표시 뷰에 아이콘을 넣는다
    private func showIcon(_ image: NSImage) {
        shownIcon = image
        if let titleView { titleView.icon = image } else { statusItem.button?.image = image }
    }
    private var iconAnimation: Timer?

    /// 기호가 바뀌면 0.45초 동안 스프링처럼 튕기며 바꾼다 (동작 줄이기를 켠 경우는 바로 바꾼다)
    private func setIcon(_ symbol: NoteGlyph.Symbol) {
        guard symbol != shownSymbol else { return }
        let previous = shownSymbol
        shownSymbol = symbol
        iconAnimation?.invalidate()
        guard let previous, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            showIcon(NoteGlyph.menuBarImage(symbol))
            return
        }
        let duration: TimeInterval = 0.45
        let start = Date()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            let progress = min(Date().timeIntervalSince(start) / duration, 1)
            self?.showIcon(NoteGlyph.menuBarTransitionImage(from: previous, to: symbol, progress: progress))
            if progress >= 1 {
                timer.invalidate()
                self?.iconAnimation = nil
            }
        }
        RunLoop.main.add(timer, forMode: .common)  // 메뉴가 열려 있어도 애니메이션이 돌게
        iconAnimation = timer
    }

    private static let titleFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .medium)

    private var shownRateFormat = AppDelegate.rateFormat

    private static var rateFormat: RateFormat {
        UserDefaults.standard.string(forKey: SettingsKey.rateFormat).flatMap(RateFormat.init) ?? .short
    }

    /// 메뉴바용, 설정한 표기 방식으로: "44.1k" / "44.1kHz" / "44100" / "44100 Hz"
    static func displayRate(_ rate: Double) -> String {
        let format = rateFormat
        switch format {
        case .full: return menuRate(rate)
        case .fullHz: return menuRateHz(rate)
        case .short, .shortHz:
            let k = rate / 1000
            let number = k.rounded() == k ? "\(Int(k))k" : String(format: "%.1fk", k)
            return format == .shortHz ? number + "Hz" : number
        }
    }

    /// 메뉴 안용 고정 표기 (설정과 관계없이 정확한 값): 44100 → "44100"
    static func menuRate(_ rate: Double) -> String {
        "\(Int(rate.rounded()))"
    }

    /// 메뉴 안용 고정 표기, 단위까지: 44100 → "44100 Hz"
    static func menuRateHz(_ rate: Double) -> String {
        menuRate(rate) + " Hz"
    }

    enum RateFormat: String { case short, shortHz, full, fullHz }

    // MARK: - 메뉴 (열 때마다 새로 구성)

    /// 누를 수 있는 항목을 위에, 상태를 보여 주는 정보(장치·단계 스택·경고)를 아래에 둔다. 종료는 관례대로 맨 끝.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        // 메뉴가 닫혀 있는 동안 지나간 스택을 먼저 정리해, 열자마자 오래된 줄이 보이지 않게
        updateTitle()

        let settle = NSMenuItem(title: L("Pause While Switching"), action: #selector(toggleSettle), keyEquivalent: "")
        settle.target = self
        settle.state = settleEnabled ? .on : .off
        settle.toolTip = L("Pauses only when the sample rate changes. When the next track’s rate is known in advance, pauses just before the current track ends.")
            + "\n" + L("Pause → change rate → Core Audio confirms the device switched → extra delay (or ready script) → resume")
        menu.addItem(settle)
        if settleEnabled {
            // 스크립트를 쓰면 스크립트가 준비 시점을 정하므로 추가 대기는 숨긴다.
            // 쓰지 않으면 추가 대기가 주 설정이고, 스크립트 선택은 그 대안으로 아래에 둔다
            if readyScriptURL == nil {
                let sliderItem = NSMenuItem()
                sliderItem.view = makeSettleSliderView()
                menu.addItem(sliderItem)
            }
            makeReadyScriptItems().forEach(menu.addItem)
        }

        menu.addItem(.separator())

        let activityItem = NSMenuItem(title: L("Show Log…"), action: #selector(openActivity), keyEquivalent: "")
        activityItem.target = self
        menu.addItem(activityItem)

        let settingsItem = NSMenuItem(title: L("Settings…"), action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        if let device = AudioDevice.defaultOutput {
            menu.addItem(disabled: "\(device.name) · \(Self.menuRateHz(device.nominalSampleRate))")
            deviceMenuItem = menu.items.last
            steps.install(in: menu, at: menu.numberOfItems)
        } else {
            menu.addItem(disabled: L("No output device"))
        }
        if !switcher.isRunning {
            menu.addItem(disabled: "⚠︎ " + L("Stopped reading Music logs (please relaunch the app)"))
        }
        if isLosslessSwitcherRunning {
            menu.addItem(disabled: "⚠︎ " + L("LosslessSwitcher is running. Both apps will fight over the sample rate"))
        }

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
    }

    /// 메뉴 안에 들어가는 라벨 + 입력칸 + 슬라이더 (0~20초, 10ms 단위).
    /// 슬라이더는 드래그하는 동안 바로 반영되고, 입력칸은 클릭해서 숫자를 넣고 Enter로 반영한다.
    /// (슬라이더 1px이 약 85ms라 10ms 단위는 입력칸으로 맞춘다)
    private func makeSettleSliderView() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 50))
        let current = min(settleDelayMs, Self.sliderMaxMs)

        // 이 대기는 Core Audio가 장치의 rate 변경을 확인한 뒤부터 센다 (확인 시간은 0ms여도 항상 기다린다)
        let label = NSTextField(labelWithString: L("Extra delay after Core Audio confirms"))
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 34, y: 28, width: 160, height: 16)

        let field = NSTextField(string: "\(current)")
        field.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        field.alignment = .right
        field.controlSize = .small
        field.bezelStyle = .roundedBezel
        field.frame = NSRect(x: 198, y: 26, width: 62, height: 20)
        // Enter는 메뉴가 받으면 메뉴가 닫히므로 delegate에서 직접 처리한다 (control(_:textView:doCommandBy:))
        field.delegate = self

        let unit = NSTextField(labelWithString: "ms")
        unit.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        unit.textColor = .secondaryLabelColor
        unit.frame = NSRect(x: 264, y: 28, width: 24, height: 16)

        let slider = MenuSlider(value: Double(current), minValue: 0, maxValue: Double(Self.sliderMaxMs),
                                target: self, action: #selector(settleSliderChanged(_:)))
        slider.isContinuous = true
        slider.frame = NSRect(x: 30, y: 4, width: 256, height: 20)

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
        // 스크립트가 고정 대기 시간의 최대값보다 오래 붙잡지 않게 같은 값으로 맞춘다
        switcher.readyScriptTimeout = TimeInterval(Self.sliderMaxMs) / 1000
    }

    private func setReadyScript(_ url: URL?) {
        UserDefaults.standard.set(url?.path, forKey: Self.readyScriptKey)
        applyReadyScript()
    }

    /// 스크립트가 없으면 누르면 바로 선택 창이 뜨는 항목, 있으면 "지우기"만 있는 하위 메뉴.
    /// 다른 스크립트로 바꾸려면 지운 뒤 다시 선택한다. 마지막 실행이 실패했으면 그 아래에 이유를 보여 준다.
    private func makeReadyScriptItems() -> [NSMenuItem] {
        guard let url = readyScriptURL else {
            let choose = NSMenuItem(title: "    " + L("Choose Ready Script…"), action: #selector(chooseReadyScript), keyEquivalent: "")
            choose.target = self
            choose.toolTip = L("Instead of a fixed delay, a script can tell when the audio interface is ready.")
            return [choose]
        }
        let item = NSMenuItem(title: "    " + L("Ready Script: %@", url.lastPathComponent), action: nil, keyEquivalent: "")
        item.toolTip = url.path + "\n" + L("Resumes as soon as the script exits. Even if it fails, playback resumes right away.")
        let submenu = NSMenu()
        let remove = NSMenuItem(title: L("Remove Ready Script"), action: #selector(removeReadyScript), keyEquivalent: "")
        remove.target = self
        submenu.addItem(remove)
        item.submenu = submenu

        guard let failure = switcher.lastReadyScriptFailure else { return [item] }
        let short = failure.count > 60 ? String(failure.prefix(60)) + "…" : failure
        let warning = NSMenuItem(title: "    ⚠︎ " + L("Last run failed: %@", short), action: nil, keyEquivalent: "")
        warning.isEnabled = false
        warning.toolTip = failure
        return [item, warning]
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

    @objc private func openActivity() {
        activityWindow.show()
    }

    @objc private func openSettings() {
        settingsWindow.show()
    }

    /// Dock 없는 앱이라 메뉴 막대에 보이지는 않지만, 창이 앞에 있을 때 ⌘, ⌘W ⌘Q와 입력칸의 복사·붙여넣기가 이 메뉴로 동작한다
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        let settings = appMenu.addItem(withTitle: L("Settings…"), action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: "", action: nil, keyEquivalent: "").submenu = appMenu

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        main.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = window

        return main
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
