import AppKit
import RateCore

/// 메뉴 안에서 전환 단계를 한 줄씩 아래로 쌓아 보여 주는 스택.
///
///     다음 곡 (예정)          96kHz      ← 다음 곡이 다른 rate로 예정되면
///     ⏸ Music 일시정지         0.0초 ✓
///     ⚙︎ Core Audio 확인       1.1초 ✓
///     ··· 준비 확인 스크립트     3.2초      ← 진행 중인 줄은 시간이 흐른다
///     ✓ 전환 완료 48k → 96k    5.1초      ← 끝나면 전체를 잠깐 보여 준 뒤 한꺼번에 사라진다
///
/// 메뉴바 표시 설정과 관계없이 항상 쌓는다. 메뉴가 열려 있으면 줄이 생길 때 미끄러지며 나타나고, 사라질 때 함께 흐려진다.
final class SwitchSteps {
    enum Kind: Equatable {
        case planned(Double)
        case pausing
        case confirming
        case settling(until: Date)
        case readyScript
        case done(from: Double?, to: Double, outcome: RateSwitcher.Outcome)
    }

    struct Step {
        let id: Int
        var kind: Kind
        let started: Date
        var ended: Date?
        /// 이 단계에서 준비를 확인하지 못했다 (스크립트 실패, 장치 확인 알림 없음)
        var problem: String?
    }

    private(set) var steps: [Step] = []
    private var nextID = 0
    /// 이 시각이 지나면 스택 전체를 지운다
    private var clearAt: Date?
    private var lastPhase: RateSwitcher.Phase = .idle
    private var switchStarted: (date: Date, from: Double?)?

    // MARK: - 상태 추적

    /// 단계·다음 곡이 바뀔 때마다 (그리고 메뉴가 열려 있으면 주기적으로) 부른다
    func track(phase: RateSwitcher.Phase, outcome: RateSwitcher.Outcome, nextRate: Double?, deviceRate: Double?, enabled: Bool) {
        let now = Date()
        if phase != lastPhase {
            phaseChanged(from: lastPhase, to: phase, outcome: outcome, deviceRate: deviceRate, now: now)
            lastPhase = phase
        }
        guard phase == .idle else { return }
        if let clearAt, now >= clearAt {
            steps.removeAll()
            self.clearAt = nil
        }
        // 다음 곡 예정 줄: 전환 결과를 보여 주는 동안은 건드리지 않는다
        guard !steps.contains(where: { if case .done = $0.kind { true } else { false } }) else { return }
        if enabled, let nextRate, nextRate != deviceRate {
            if let index = steps.firstIndex(where: { if case .planned = $0.kind { true } else { false } }) {
                steps[index].kind = .planned(nextRate)
            } else {
                steps = [newStep(.planned(nextRate), now)]
            }
            clearAt = nil
        } else if !steps.isEmpty, clearAt == nil {
            // 곡을 넘겨 예정이 사라졌다: 곧바로 전환이 시작될 수 있으니 조금 기다렸다가 지운다
            clearAt = now.addingTimeInterval(1)
        }
    }

    private func phaseChanged(from old: RateSwitcher.Phase, to phase: RateSwitcher.Phase,
                              outcome: RateSwitcher.Outcome, deviceRate: Double?, now: Date) {
        if let last = steps.indices.last, steps[last].ended == nil, !isPlanned(steps[last]) {
            steps[last].ended = now
        }
        if old == .idle {
            // 새 전환: 예정 줄만 남기고 이전 결과는 지운다
            steps.removeAll { !isPlanned($0) }
            if let index = steps.firstIndex(where: isPlanned) { steps[index].ended = now }
            switchStarted = (now, deviceRate)
            clearAt = nil
        }
        switch phase {
        case .pausing: steps.append(newStep(.pausing, now))
        case .confirming: steps.append(newStep(.confirming, now))
        case let .settling(_, until):
            // 대기 0초는 줄을 만들지 않는다 (RME처럼 바로 재생하는 장치)
            if until.timeIntervalSince(now) > 0.05 { steps.append(newStep(.settling(until: until), now)) }
        case .readyScript: steps.append(newStep(.readyScript, now))
        case .idle:
            guard let to = old.target else { break }
            if case .cancelled = outcome {
                clearAt = now.addingTimeInterval(0.8)
                break
            }
            var done = newStep(.done(from: switchStarted?.from, to: to, outcome: outcome), switchStarted?.date ?? now)
            done.ended = now
            if case let .uncertain(reason) = outcome {
                // 문제는 대기 전 단계에서 생긴다: 스크립트 실패, 장치 확인 알림 없음, rate 변경 실패
                if let index = steps.lastIndex(where: { step in
                    if case .settling = step.kind { false } else { !isPlanned(step) }
                }) {
                    steps[index].problem = reason
                }
                done.problem = reason
            }
            steps.append(done)
            // 문제가 있었으면 메뉴를 늦게 열어도 볼 수 있게 더 오래 남긴다
            if case .uncertain = outcome {
                clearAt = now.addingTimeInterval(10)
            } else {
                clearAt = now.addingTimeInterval(5)
            }
            switchStarted = nil
        }
    }

    private func newStep(_ kind: Kind, _ started: Date) -> Step {
        nextID += 1
        return Step(id: nextID, kind: kind, started: started)
    }

    private func isPlanned(_ step: Step) -> Bool {
        if case .planned = step.kind { true } else { false }
    }

    /// 시간이 흐르는 줄이 있거나 곧 지울 스택이 있어 주기적으로 다시 그려야 하는지
    var needsTicking: Bool {
        clearAt != nil || steps.contains { $0.ended == nil && !isPlanned($0) }
    }

    // MARK: - 메뉴 줄

    private weak var menu: NSMenu?
    private var rows: [Int: (item: NSMenuItem, view: StepRowView)] = [:]
    /// 사라지는 중인 줄 (애니메이션이 끝나면 메뉴에서 뺀다)
    private var leaving: Set<Int> = []

    /// 메뉴를 새로 만들 때 index 위치부터 지금 스택을 애니메이션 없이 넣는다
    func install(in menu: NSMenu, at index: Int) {
        self.menu = menu
        rows.removeAll()
        leaving.removeAll()
        for (offset, step) in steps.enumerated() {
            let row = makeRow(step)
            menu.insertItem(row.item, at: index + offset)
            rows[step.id] = row
        }
        anchorIndex = index
    }

    private var anchorIndex = 0

    /// 메뉴가 열려 있는 동안 모델과 줄을 맞춘다. 새 줄은 나타나는 애니메이션, 지워진 줄은 함께 흐려진 뒤 빠진다.
    func sync() {
        guard let menu else { return }
        let now = Date()
        let ids = Set(steps.map(\.id))
        // 지워진 줄: 위에서부터 이어서 오른쪽으로 밀리며 사라지고(자리는 유지), 다 사라지면 함께 접힌다
        let removed = rows.filter { !ids.contains($0.key) && !leaving.contains($0.key) }
            .sorted { menu.index(of: $0.value.item) < menu.index(of: $1.value.item) }
        if !removed.isEmpty {
            leaving.formUnion(removed.map(\.key))
            let group = DispatchGroup()
            for (order, entry) in removed.enumerated() {
                group.enter()
                entry.value.view.slideAway(delay: Double(order) * 0.04) { group.leave() }
            }
            group.notify(queue: .main) { [weak self] in self?.collapse(removed.map { ($0.key, $0.value) }) }
        }
        for (offset, step) in steps.enumerated() {
            if let row = rows[step.id] {
                row.view.update(step, now: now)
            } else {
                let row = makeRow(step)
                // 사라지는 중인 줄보다 앞에 넣어 새 스택이 위에서부터 쌓이게 한다
                let index = min(anchorIndex + offset, menu.numberOfItems)
                menu.insertItem(row.item, at: index)
                rows[step.id] = row
                row.view.animateIn()
            }
        }
    }

    /// 사라진 줄들의 높이를 함께 줄인 뒤 메뉴에서 뺀다.
    /// 메뉴가 열려 있는 동안 높이 변화를 따라가지 않으면, 마지막에 빠지는 순간 한 번에 줄어든다.
    private func collapse(_ removed: [(id: Int, row: (item: NSMenuItem, view: StepRowView))]) {
        let finish = { [weak self] in
            guard let self else { return }
            for (id, row) in removed {
                if let menu, menu.index(of: row.item) >= 0 { menu.removeItem(row.item) }
                // 그사이 메뉴를 새로 만들었으면 같은 id라도 다른 줄이다
                if rows[id]?.view === row.view { rows[id] = nil }
                leaving.remove(id)
            }
        }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return finish() }
        let start = Date()
        let duration = 0.25
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { timer in
            let progress = min(Date().timeIntervalSince(start) / duration, 1)
            let eased = 1 - pow(1 - progress, 3)
            for (_, row) in removed {
                // 폭은 처음 정한 값으로 둔다. 메뉴 폭만큼 늘어난 지금 폭을 넣으면 메뉴가 그걸 원하는 폭으로 보고 더 넓힌다
                row.view.setFrameSize(NSSize(width: StepRowView.width, height: StepRowView.height * (1 - eased)))
            }
            if progress >= 1 {
                timer.invalidate()
                finish()
            }
        }
        RunLoop.main.add(timer, forMode: .common)  // 메뉴가 열려 있어도 돌게
    }

    private func makeRow(_ step: Step) -> (item: NSMenuItem, view: StepRowView) {
        let view = StepRowView()
        view.update(step, now: Date())
        let item = NSMenuItem()
        item.view = view
        return (item, view)
    }
}

extension RateSwitcher.Phase {
    /// 전환 중이면 맞추려는 rate
    var target: Double? {
        switch self {
        case .idle: nil
        case let .pausing(to), let .confirming(to), let .readyScript(to): to
        case let .settling(to, _): to
        }
    }
}

/// 스택 한 줄. 칸마다 폭을 고정해 글자가 바뀌어도 줄이 흔들리지 않게 한다.
///
///     [기호][단계 이름 ............][   시간][표시]
///      ···  준비 확인 스크립트           3.2초
///      ⚙︎   Core Audio 확인              1.1초  ✓
final class StepRowView: NSView {
    private let icon = NSTextField(labelWithString: "")
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let mark = NSTextField(labelWithString: "")
    static let width: CGFloat = 340
    static let height: CGFloat = 20
    /// 체크 표시 칸이 있는 메뉴의 글자 시작 위치
    private static let inset: CGFloat = 21
    private static let iconWidth: CGFloat = 22
    private static let markWidth: CGFloat = 16
    private static let detailWidth: CGFloat = 86

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height))
        wantsLayer = true
        autoresizingMask = [.width]
        icon.font = .menuFont(ofSize: 0)
        title.font = .menuFont(ofSize: 0)
        title.lineBreakMode = .byTruncatingTail
        detail.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .right
        mark.font = .menuFont(ofSize: 0)
        mark.textColor = .secondaryLabelColor
        mark.alignment = .center
        [icon, title, detail, mark].forEach(addSubview)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let y = (bounds.height - 17) / 2
        mark.frame = NSRect(x: bounds.width - 10 - Self.markWidth, y: y, width: Self.markWidth, height: 17)
        detail.frame = NSRect(x: mark.frame.minX - Self.detailWidth, y: y, width: Self.detailWidth, height: 17)
        icon.frame = NSRect(x: Self.inset, y: y, width: Self.iconWidth, height: 17)
        title.frame = NSRect(x: icon.frame.maxX, y: y, width: detail.frame.minX - icon.frame.maxX - 6, height: 17)
    }

    func update(_ step: SwitchSteps.Step, now: Date) {
        let elapsed = (step.ended ?? now).timeIntervalSince(step.started)
        let seconds = String(format: L("%.1fs"), elapsed)
        let running = step.ended == nil
        var markText = step.problem != nil ? "?" : (running ? "" : "✓")
        var symbol = ""
        /// 기호 끝에서 이만큼은 자리만 차지하고 투명하게 (점 애니메이션)
        var hiddenSymbolTail = 0
        var titleColor = NSColor.labelColor
        var text: String
        var right: String
        switch step.kind {
        case let .planned(rate):
            text = L("Next track (planned)")
            right = AppDelegate.menuRateHz(rate)
            titleColor = .secondaryLabelColor
            markText = ""
        case .pausing:
            symbol = "⏸"
            text = L("Pausing Music")
            right = seconds
        case .confirming:
            symbol = "⚙︎"
            text = L("Core Audio confirmation")
            right = seconds
        case let .settling(until):
            symbol = "⏳"
            text = L("Extra delay")
            right = running ? String(format: L("%.1fs left"), max(until.timeIntervalSince(now), 0)) : seconds
        case .readyScript:
            symbol = "···"
            if running { hiddenSymbolTail = 2 - Int(now.timeIntervalSinceReferenceDate * 3) % 3 }
            text = L("Ready script")
            right = seconds
        case let .done(from, to, outcome):
            let change = "\(from.map(AppDelegate.menuRate) ?? "?") → \(AppDelegate.menuRate(to))"
            if case .uncertain = outcome {
                symbol = "?"
                text = L("Switched %@ without confirming the device is ready", change)
                titleColor = .systemOrange
            } else {
                symbol = "✓"
                text = L("Switched %@", change)
            }
            right = seconds
            markText = ""
        }
        // 0.1초마다 불리므로 바뀐 것만 넣는다 (같은 값을 다시 넣어도 다시 그리고 배치한다)
        if toolTip != step.problem { toolTip = step.problem }
        if (symbol, hiddenSymbolTail) != drawnSymbol {
            drawnSymbol = (symbol, hiddenSymbolTail)
            let attributed = NSMutableAttributedString(string: symbol, attributes: [.font: icon.font!, .foregroundColor: NSColor.labelColor])
            if hiddenSymbolTail > 0 {
                attributed.addAttribute(.foregroundColor, value: NSColor.clear,
                                        range: NSRange(location: attributed.length - hiddenSymbolTail, length: hiddenSymbolTail))
            }
            icon.attributedStringValue = attributed
        }
        if title.stringValue != text { title.stringValue = text }
        if title.textColor != titleColor { title.textColor = titleColor }
        if detail.stringValue != right { detail.stringValue = right }
        if mark.stringValue != markText { mark.stringValue = markText }
    }

    private var drawnSymbol: (String, Int) = ("", -1)

    /// 위에서 살짝 내려오며 나타난다. 0.1초마다 글자를 고치며 다시 배치하므로 위치는 레이어 애니메이션으로 움직인다
    func animateIn() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer else { return }
        let duration = 0.28
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let slide = CABasicAnimation(keyPath: "transform.translation.y")
        slide.fromValue = 6   // 레이어 좌표는 아래에서 위로: 위에서 시작
        slide.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [fade, slide]
        group.duration = duration
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(group, forKey: "appear")
    }

    /// 오른쪽으로 살짝 밀리며 흐려진다. 자리는 그대로 남고, 다 사라진 뒤 접는다.
    func slideAway(delay: TimeInterval, completion: @escaping () -> Void) {
        let duration = 0.28
        guard let layer, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                animator().alphaValue = 0
            }, completionHandler: completion)
            return
        }
        let slide = CABasicAnimation(keyPath: "transform.translation.x")
        slide.fromValue = 0
        slide.toValue = 28
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [slide, fade]
        group.beginTime = CACurrentMediaTime() + delay
        group.duration = duration
        // 천천히 출발해 빠르게 빠지는 곡선 (시스템 화면 전환과 비슷한 ease-in)
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)
        group.fillMode = .both
        group.isRemovedOnCompletion = false
        layer.add(group, forKey: "leave")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + duration) { completion() }
    }
}
