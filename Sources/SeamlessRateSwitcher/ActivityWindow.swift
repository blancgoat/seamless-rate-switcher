import AppKit
import RateCore

/// 앱이 켜져 있는 동안의 활동 기록 (최근 1000건). Activity 창이 실시간으로 보여 준다.
final class ActivityLog {
    struct Entry {
        let date: Date
        let message: RateSwitcher.Message
    }

    private(set) var entries: [Entry] = []
    private let limit = 1000
    var onAppend: ((Entry) -> Void)?

    func append(_ message: RateSwitcher.Message) {
        let entry = Entry(date: Date(), message: message)
        entries.append(entry)
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        onAppend?(entry)
    }

    func clear() {
        entries.removeAll()
    }
}

/// 활동 기록 창. Music을 조작하면서 띄워 두고 볼 수 있게 일반 창으로 둔다.
/// - 새 기록은 바로 아래에 붙고, 맨 아래를 보고 있을 때만 자동으로 따라 내려간다
/// - "자세히"를 끄면 곡 전환·포맷 기록 같은 진단용 세부 기록을 숨긴다
final class ActivityWindowController: NSWindowController {
    private let log: ActivityLog
    private let textView = NSTextView()
    private let scrollView = NSScrollView()
    private let detailsToggle = NSButton(checkboxWithTitle: L("Show Details"), target: nil, action: nil)
    private let onTopToggle = NSButton(checkboxWithTitle: L("Keep on Top"), target: nil, action: nil)

    private static let detailsKey = "activityShowDetails"
    private static let onTopKey = "activityKeepOnTop"

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    init(log: ActivityLog) {
        self.log = log
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 420),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = L("Activity")
        window.minSize = NSSize(width: 480, height: 240)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("ActivityWindow")
        super.init(window: window)
        buildContent()
        reload()
        log.onAppend = { [weak self] entry in self?.append(entry) }
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        if window?.isVisible != true { window?.center() }
        NSApp.activate(ignoringOtherApps: true)  // 메뉴바 전용 앱이라 창을 앞으로 가져와야 한다
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        scrollToBottom()
    }

    // MARK: - 화면 구성

    private func buildContent() {
        guard let content = window?.contentView else { return }

        detailsToggle.target = self
        detailsToggle.action = #selector(toggleDetails)
        detailsToggle.state = UserDefaults.standard.bool(forKey: Self.detailsKey) ? .on : .off

        // 항상 위: Music을 앞에 두고 조작해도 기록이 가려지지 않게
        onTopToggle.target = self
        onTopToggle.action = #selector(toggleOnTop)
        onTopToggle.state = UserDefaults.standard.bool(forKey: Self.onTopKey) ? .on : .off
        applyOnTop()

        let clear = NSButton(title: L("Clear"), target: self, action: #selector(clearAll))
        let bar = NSStackView(views: [detailsToggle, onTopToggle, NSView(), clear])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        bar.translatesAutoresizingMaskIntoConstraints = false

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 8, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(bar)
        content.addSubview(scrollView)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: bar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    // MARK: - 기록 표시

    private var showsDetails: Bool { detailsToggle.state == .on }

    private func isShown(_ message: RateSwitcher.Message) -> Bool {
        if case .detail = message { return showsDetails }
        return true
    }

    private static func line(for entry: ActivityLog.Entry) -> (text: String, color: NSColor) {
        let time = clock.string(from: entry.date)
        switch entry.message {
        case let .detail(text): return ("\(time)     \(text)", .tertiaryLabelColor)
        case let .info(text): return ("\(time)     \(text)", .secondaryLabelColor)
        case let .action(text): return ("\(time)  \(text)", .labelColor)
        case let .warning(text): return ("\(time)  ⚠︎ \(text)", .systemOrange)
        }
    }

    private func attributed(_ entry: ActivityLog.Entry) -> NSAttributedString {
        let (text, color) = Self.line(for: entry)
        return NSAttributedString(string: text + "\n", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
            .foregroundColor: color,
        ])
    }

    private func reload() {
        let all = NSMutableAttributedString()
        log.entries.filter { isShown($0.message) }.forEach { all.append(attributed($0)) }
        textView.textStorage?.setAttributedString(all)
        scrollToBottom()
    }

    private func append(_ entry: ActivityLog.Entry) {
        guard isShown(entry.message), let storage = textView.textStorage else { return }
        // 맨 아래를 보고 있을 때만 따라 내려간다 (위로 스크롤해서 읽는 중이면 그대로 둔다)
        let follow = isScrolledToBottom
        storage.append(attributed(entry))
        // 보관 한도를 넘어 기록에서 빠진 만큼 앞쪽 줄도 정리한다
        if log.entries.count >= 1000, storage.length > 0 {
            let first = (storage.string as NSString).range(of: "\n")
            if first.location != NSNotFound { storage.deleteCharacters(in: NSRange(location: 0, length: first.location + 1)) }
        }
        if follow { scrollToBottom() }
    }

    private var isScrolledToBottom: Bool {
        let visible = scrollView.contentView.bounds
        return visible.maxY >= textView.bounds.height - 20
    }

    private func scrollToBottom() {
        textView.scrollToEndOfDocument(nil)
    }

    // MARK: - 버튼

    @objc private func toggleDetails() {
        UserDefaults.standard.set(showsDetails, forKey: Self.detailsKey)
        reload()
    }

    @objc private func toggleOnTop() {
        UserDefaults.standard.set(onTopToggle.state == .on, forKey: Self.onTopKey)
        applyOnTop()
    }

    private func applyOnTop() {
        window?.level = onTopToggle.state == .on ? .floating : .normal
    }

    @objc private func clearAll() {
        log.clear()
        reload()
    }
}
