import AppKit

/// 메뉴바 "자세히" 표시를 직접 그리는 뷰. 버튼 기본 글자로는 글자 일부만 움직이거나 색을 바꿀 수 없어서 쓴다.
///
///     ♫ 44.1k → 96k            예정: 96k 회색 (장치는 아직 44.1k)
///     𝄽 44.1k → 96k  ⚙︎         Core Audio 확인 전: 96k 회색, 화살표가 살짝 움직인다
///     𝄽 44.1k → 96k  ···        장치는 이미 96k: 44.1k 회색, 96k 원래 색
///     ♫ 96k          ✓         재생 재개: "44.1k →"가 왼쪽으로 빠지고 96k가 왼쪽으로, ✓는 제자리
///     ♫ 96k                    ✓가 사라지며 폭이 줄어든다
///
/// 색은 "장치가 실제로 그 rate인가"를 나타내고, 배치는 "듣는 사람 입장에서 전환이 끝났는가"를 나타낸다.
final class RateTitleView: NSView {
    struct Model: Equatable {
        enum Stage: Equatable {
            /// 평소: to만
            case plain
            /// 다음 곡이 다른 rate로 예정됨
            case planned
            /// 전환 중. deviceSwitched: Core Audio가 장치 rate 변경을 확인했다
            case switching(deviceSwitched: Bool)
            /// 재생 재개 직후 결과 표시
            case done
        }
        var stage: Stage
        var from: Double?
        var to: Double
        /// 오른쪽 단계 기호: ⚙︎ / 1.2s / ··· / ✓ / ?
        var status: String?
        /// status가 ···일 때 켜진 점 개수 (나머지는 자리만 차지)
        var dots = 3
        /// 이 전환에서 나올 수 있는 기호들. 그중 가장 넓은 폭으로 기호 칸을 잡아 ✓·⚙︎ 위치를 고정한다
        /// (안 나오는 기호까지 넣으면 오른쪽이 비어 옆 항목과 멀어진다)
        var statusSlot: [String] = []
    }

    var rateText: (Double) -> String = { "\(Int($0))" }
    var onWidthChange: ((CGFloat) -> Void)?
    var icon: NSImage? { didSet { needsDisplay = true } }
    var dimmed = false { didSet { if dimmed != oldValue { needsDisplay = true } } }

    private let font: NSFont
    /// 좌우 여백. 기본 버튼이 아이콘 양옆에 두는 여백 (실행 중 측정한 값)
    var padding: CGFloat = 4
    /// 기본 버튼(아이콘 + " 48k")과 같은 간격 (음표 상태 스크린샷 측정: 음표 끝 → 숫자 8pt)
    private static let iconGap: CGFloat = 5
    /// 줄 상자를 가운데 두면 기본 버튼보다 1.5pt 높게 그려진다 (음표 상태 스크린샷 측정).
    /// 메뉴바 버튼 셀은 글자 위치를 알려 주지 않고(titleRect가 0), 화면 밖에 그려 보면 실제와 다른 자리에 그려져
    /// 자동으로 잴 수 없다. 포인트 단위 차이라 Retina 배율·화면 해상도와 관계없이 같다
    private static let textDrop: CGFloat = 1.5
    private static let space: CGFloat = 4
    private static let duration: CFTimeInterval = 0.32

    /// 화면에 그리는 글자 조각 하나. 같은 id끼리 위치·투명도·강조(회색 0 ~ 원래 색 1)를 보간한다
    private struct Piece {
        var text: String
        var x: CGFloat
        var alpha: CGFloat
        var emphasis: CGFloat
    }

    private var model: Model?
    private var start: [String: Piece] = [:]
    private var target: [String: Piece] = [:]
    private var startWidth: CGFloat = 0
    private var targetWidth: CGFloat = 0
    private var animationStart: CFTimeInterval?
    private var timer: Timer?

    init(font: NSFont) {
        self.font = font
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    // 클릭은 아래 버튼이 받는다
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private(set) var currentWidth: CGFloat = 0

    func set(_ new: Model) {
        guard new != model else { return }
        let old = model
        model = new
        let layout = layout(for: new)
        // 단계·rate가 그대로고 기호 글자(카운트다운·점)만 바뀌면 애니메이션 없이 바꾼다
        if let old, Self.sameLayout(old, new) {
            if var status = layout.pieces["status"] {
                status.alpha = target["status"]?.alpha ?? status.alpha
                target["status"] = status
                if start["status"] != nil { start["status"]?.text = status.text }
            }
            needsDisplay = true
            return
        }
        guard old != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            start = layout.pieces
            target = layout.pieces
            startWidth = layout.width
            targetWidth = layout.width
            animationStart = nil
            applyWidth(layout.width)
            updateTimer()
            needsDisplay = true
            return
        }
        // 지금 보이는 상태에서 새 배치로 보간을 다시 시작한다
        let now = interpolated()
        var from = now.pieces
        var to = layout.pieces
        for (id, piece) in to where from[id] == nil {
            var appearing = piece
            appearing.alpha = 0
            from[id] = appearing
        }
        for (id, piece) in from where to[id] == nil {
            var leaving = piece
            leaving.alpha = 0
            to[id] = leaving
        }
        start = from
        target = to
        startWidth = now.width
        targetWidth = layout.width
        animationStart = CACurrentMediaTime()
        updateTimer()
        needsDisplay = true
    }

    /// 모델은 그대로인데 글자 모양(rateText)이 바뀌었을 때 (설정에서 표기 방식을 바꿈) 애니메이션 없이 다시 배치한다
    func relayout() {
        guard let model else { return }
        let layout = layout(for: model)
        start = layout.pieces
        target = layout.pieces
        startWidth = layout.width
        targetWidth = layout.width
        animationStart = nil
        applyWidth(layout.width)
        updateTimer()
        needsDisplay = true
    }

    private static func sameLayout(_ a: Model, _ b: Model) -> Bool {
        a.stage == b.stage && a.from == b.from && a.to == b.to && a.statusSlot == b.statusSlot
    }

    // MARK: - 배치

    private func width(_ text: String) -> CGFloat {
        NSAttributedString(string: text, attributes: [.font: font]).size().width
    }

    private func layout(for model: Model) -> (pieces: [String: Piece], width: CGFloat) {
        let x0 = padding + (icon?.size.width ?? 18) + Self.iconGap
        let toText = rateText(model.to)
        // rate 조각은 rate 값으로 구분한다: 평소 44.1k가 예정 표시의 왼쪽 44.1k로, 전환 뒤 96k가 평소 96k로 그대로 이어진다
        let toID = "rate:\(model.to)"
        guard let from = model.from, model.stage != .plain else {
            let pieces = [toID: Piece(text: toText, x: x0, alpha: 1, emphasis: 1)]
            return (pieces, x0 + width(toText) + padding)
        }
        let fromText = rateText(from)
        let arrowX = x0 + width(fromText) + Self.space
        let toX = arrowX + width("→") + Self.space
        let statusX = toX + width(toText) + Self.space
        let statusWidth = (model.statusSlot + [model.status ?? ""]).map(width).max() ?? 0
        let switchingWidth = statusX + statusWidth + padding
        let fromID = "rate:\(from)"
        var pieces: [String: Piece] = [:]
        switch model.stage {
        case .plain:
            break
        case .planned:
            pieces[fromID] = Piece(text: fromText, x: x0, alpha: 1, emphasis: 1)
            pieces["arrow"] = Piece(text: "→", x: arrowX, alpha: 1, emphasis: 0)
            pieces[toID] = Piece(text: toText, x: toX, alpha: 1, emphasis: 0)
            return (pieces, toX + width(toText) + padding)
        case let .switching(deviceSwitched):
            pieces[fromID] = Piece(text: fromText, x: x0, alpha: 1, emphasis: deviceSwitched ? 0 : 1)
            pieces["arrow"] = Piece(text: "→", x: arrowX, alpha: 1, emphasis: 0)
            pieces[toID] = Piece(text: toText, x: toX, alpha: 1, emphasis: deviceSwitched ? 1 : 0)
        case .done:
            // 이전 rate와 화살표는 왼쪽으로 빠지고, 새 rate가 맨 앞으로 온다. 기호는 제자리
            let shift = toX - x0
            pieces[fromID] = Piece(text: fromText, x: x0 - shift, alpha: 0, emphasis: 0)
            pieces["arrow"] = Piece(text: "→", x: arrowX - shift, alpha: 0, emphasis: 0)
            pieces[toID] = Piece(text: toText, x: x0, alpha: 1, emphasis: 1)
        }
        if let status = model.status {
            pieces["status"] = Piece(text: status, x: statusX, alpha: 1, emphasis: 1)
        }
        return (pieces, switchingWidth)
    }

    // MARK: - 애니메이션

    private var progress: CGFloat {
        guard let animationStart else { return 1 }
        let t = min((CACurrentMediaTime() - animationStart) / Self.duration, 1)
        return CGFloat(t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2)  // ease-in-out
    }

    private func interpolated() -> (pieces: [String: Piece], width: CGFloat) {
        let p = progress
        var pieces: [String: Piece] = [:]
        for (id, end) in target {
            let begin = start[id] ?? end
            pieces[id] = Piece(text: end.text,
                               x: begin.x + (end.x - begin.x) * p,
                               alpha: begin.alpha + (end.alpha - begin.alpha) * p,
                               emphasis: begin.emphasis + (end.emphasis - begin.emphasis) * p)
        }
        return (pieces, startWidth + (targetWidth - startWidth) * p)
    }

    private var isSwitching: Bool {
        if case .switching = model?.stage { return true }
        return false
    }

    private func updateTimer() {
        let needed = animationStart != nil || isSwitching
        if needed, timer == nil {
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(timer, forMode: .common)  // 메뉴가 열려 있어도 돌게
            self.timer = timer
        } else if !needed {
            timer?.invalidate()
            timer = nil
        }
    }

    private func tick() {
        if animationStart != nil {
            let state = interpolated()
            applyWidth(state.width)
            if progress >= 1 {
                start = target.filter { $0.value.alpha > 0 }
                target = start
                startWidth = targetWidth
                animationStart = nil
            }
        }
        updateTimer()
        needsDisplay = true
    }

    private func applyWidth(_ width: CGFloat) {
        guard abs(width - currentWidth) > 0.25 else { return }
        currentWidth = width
        onWidthChange?(width)
    }

    // MARK: - 그리기

    override func draw(_ dirtyRect: NSRect) {
        let state = interpolated()
        let alpha: CGFloat = dimmed ? 0.4 : 1
        if let icon {
            let y = (bounds.height - icon.size.height) / 2
            let rect = NSRect(x: padding, y: y, width: icon.size.width, height: icon.size.height)
            Self.tinted(icon, NSColor.labelColor.withAlphaComponent(alpha)).draw(in: rect)
        }
        // draw(at:)은 글자 줄 상자의 왼쪽 아래를 기준으로 그린다
        let lineHeight = font.ascender - font.descender
        // 줄 상자를 가운데 둔 뒤 기본 버튼에 맞춰 내리고, 화면 픽셀에 맞춰 흐려지지 않게 한다 (1배율 화면 대비)
        let y = backingAligned(((bounds.height - lineHeight) / 2).rounded() - Self.textDrop)
        // 전환 중에는 화살표가 오른쪽으로 살짝 밀렸다 돌아오기를 반복한다
        let nudge = isSwitching ? 0.75 * (1 - cos(CACurrentMediaTime() * 2 * .pi / 1.2)) : 0
        // 왼쪽으로 빠지는 글자가 아이콘 위로 지나가지 않게 글자 영역 안에서만 그린다
        let textStart = padding + (icon?.size.width ?? 18) + Self.iconGap / 2
        NSGraphicsContext.saveGraphicsState()
        NSRect(x: textStart, y: 0, width: bounds.width - textStart, height: bounds.height).clip()
        defer { NSGraphicsContext.restoreGraphicsState() }
        for (id, piece) in state.pieces where piece.alpha > 0.01 {
            var x = piece.x
            if id == "arrow" { x += nudge }
            let point = NSPoint(x: x, y: y)
            if id == "status", piece.text == "···", let model, model.dots < 3 {
                drawDots(at: point, visible: model.dots, alpha: piece.alpha * alpha)
                continue
            }
            // 회색(장치가 아직/이미 아닌 rate)과 원래 색을 강조 값으로 섞는다
            let gray = (1 - piece.emphasis) * piece.alpha * alpha
            let normal = piece.emphasis * piece.alpha * alpha
            if gray > 0.01 { draw(piece.text, at: point, color: .secondaryLabelColor, alpha: gray) }
            if normal > 0.01 { draw(piece.text, at: point, color: .labelColor, alpha: normal) }
        }
    }

    /// 화면 픽셀 경계로 맞춘다 (Retina 0.5pt, 일반 화면 1pt 단위)
    private func backingAligned(_ y: CGFloat) -> CGFloat {
        let scale = window?.backingScaleFactor ?? 2
        return (y * scale).rounded() / scale
    }

    private func draw(_ text: String, at point: NSPoint, color: NSColor, alpha: CGFloat) {
        (text as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: color.withAlphaComponent(color.alphaComponent * alpha)])
    }

    private func drawDots(at point: NSPoint, visible: Int, alpha: CGFloat) {
        let text = NSMutableAttributedString(string: "···", attributes: [.font: font, .foregroundColor: NSColor.labelColor.withAlphaComponent(alpha)])
        text.addAttribute(.foregroundColor, value: NSColor.clear, range: NSRange(location: visible, length: 3 - visible))
        text.draw(at: point)
    }

    /// 템플릿 아이콘을 메뉴바 글자색으로 칠한다 (직접 그리면 자동으로 칠해지지 않는다)
    private static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
