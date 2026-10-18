import AppKit

/// 수평 빔으로 이은 8분음표 2개. 메뉴바 아이콘과 앱 아이콘이 같이 쓴다.
/// 18×18 좌표계에서 설계했고, 원하는 사각형에 맞춰 늘려 그린다.
public enum NoteGlyph {
    static let designSize = 18.0

    /// 음표를 이루는 도형들 (머리 2, 기둥 2, 빔). rect 안에 정사각형 비율로 맞춘다.
    public static func shapes(in rect: NSRect) -> [NSBezierPath] {
        // 음표 머리: 20도 기울인 타원. 기둥은 타원의 실제 오른쪽 끝에 오른쪽 면을 맞춰야 머리에 붙어 보인다.
        let rx = 2.6, ry = 1.9, tilt = 20 * Double.pi / 180
        let reachX = (rx * rx * cos(tilt) * cos(tilt) + ry * ry * sin(tilt) * sin(tilt)).squareRoot()  // 중심→오른쪽 끝 x
        let reachY = (rx * rx - ry * ry) * sin(tilt) * cos(tilt) / reachX                              // 그 점의 y
        let stemWidth = 1.3, stemTop = 15.2, beamHeight = 2.6, headY = 3.6
        let heads = [4.6, 13.4]

        var paths: [NSBezierPath] = []
        for cx in heads {
            let head = NSBezierPath(ovalIn: NSRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2))
            var transform = AffineTransform(translationByX: cx, byY: headY)
            transform.rotate(byRadians: tilt)
            head.transform(using: transform)
            paths.append(head)
            let stemRight = cx + reachX
            paths.append(NSBezierPath(rect: NSRect(x: stemRight - stemWidth, y: headY + reachY,
                                                   width: stemWidth, height: stemTop - headY - reachY)))
        }
        // 수평 빔: 왼쪽 기둥 왼쪽 면 ~ 오른쪽 기둥 오른쪽 면
        let beamLeft = heads[0] + reachX - stemWidth, beamRight = heads[1] + reachX
        paths.append(NSBezierPath(rect: NSRect(x: beamLeft, y: stemTop - beamHeight, width: beamRight - beamLeft, height: beamHeight)))

        let side = min(rect.width, rect.height)
        var fit = AffineTransform(translationByX: rect.midX - side / 2, byY: rect.midY - side / 2)
        fit.scale(side / designSize)
        paths.forEach { $0.transform(using: fit) }
        return paths
    }

    /// 8분 쉼표 (앱이 Music을 일시정지해 둔 동안 메뉴바에 표시). 음표와 같은 18×18 좌표계·굵기.
    /// 시스템 글꼴에는 𝄾(U+1D13E) 글리프가 없어서 직접 그린다: 둥근 점 → 오른쪽 위로 휘는 꼬리 → 왼쪽 아래로 내려가는 기둥
    public static func restShapes(in rect: NSRect) -> (fills: [NSBezierPath], strokes: [NSBezierPath]) {
        let dot = NSBezierPath(ovalIn: NSRect(x: 3.8, y: 10.6, width: 5.0, height: 5.0))
        let flag = NSBezierPath()
        flag.move(to: NSPoint(x: 6.6, y: 11.2))
        flag.curve(to: NSPoint(x: 13.4, y: 14.0), controlPoint1: NSPoint(x: 9.0, y: 10.0), controlPoint2: NSPoint(x: 12.0, y: 11.0))
        flag.line(to: NSPoint(x: 8.8, y: 2.4))
        flag.lineWidth = 2.0  // 음표의 굵은 빔과 비슷한 무게감
        flag.lineCapStyle = .round
        flag.lineJoinStyle = .round

        let side = min(rect.width, rect.height)
        var fit = AffineTransform(translationByX: rect.midX - side / 2, byY: rect.midY - side / 2)
        fit.scale(side / designSize)
        dot.transform(using: fit)
        flag.transform(using: fit)
        flag.lineWidth *= side / designSize
        return ([dot], [flag])
    }

    /// 메뉴바에 보이는 기호
    public enum Symbol {
        case note  // 평소: 8분음표 2개
        case rest  // 앱이 Music을 일시정지해 둔 동안: 8분 쉼표
    }

    /// 메뉴바용 템플릿 이미지. 다크 모드/강조 상태에 자동으로 맞춰진다.
    public static func menuBarImage(_ symbol: Symbol) -> NSImage {
        menuBarTransitionImage(from: symbol, to: symbol, progress: 1)
    }

    /// 기호가 바뀌는 애니메이션의 한 프레임 (progress 0→1).
    /// 이전 기호는 작아지며 사라지고, 새 기호는 작게 나타나 살짝 크게 튕긴 뒤 제자리로 돌아온다.
    /// 이미지 크기는 그대로라 메뉴바 레이아웃이 흔들리지 않는다.
    public static func menuBarTransitionImage(from old: Symbol, to new: Symbol, progress: CGFloat) -> NSImage {
        let t = min(max(progress, 0), 1)
        let image = NSImage(size: NSSize(width: designSize, height: designSize), flipped: false) { rect in
            if old != new, t < 0.45 {
                let fade = t / 0.45
                draw(old, in: rect, scale: 1 - 0.4 * fade, alpha: 1 - fade)
            }
            // 감쇠 진동: 0.55에서 시작해 1.1 근처까지 튕겼다가 1로 수렴
            let spring = old == new ? 1 : 1 - 0.45 * exp(-5.5 * t) * cos(11 * t)
            let appear = old == new ? 1 : min(t / 0.25, 1)
            draw(new, in: rect, scale: spring, alpha: appear)
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func draw(_ symbol: Symbol, in rect: NSRect, scale: CGFloat, alpha: CGFloat) {
        guard alpha > 0, scale > 0 else { return }
        let side = rect.width * scale
        let box = NSRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
        NSColor.black.withAlphaComponent(alpha).set()
        switch symbol {
        case .note:
            shapes(in: box).forEach { $0.fill() }
        case .rest:
            let rest = restShapes(in: box)
            rest.fills.forEach { $0.fill() }
            rest.strokes.forEach { $0.stroke() }
        }
    }
}
