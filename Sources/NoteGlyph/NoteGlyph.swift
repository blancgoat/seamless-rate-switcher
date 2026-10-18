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

    /// 메뉴바용 템플릿 이미지. 자동 전환을 끄면 사선.
    public static func menuBarImage(slashed: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: designSize, height: designSize), flipped: false) { rect in
            NSColor.black.set()
            shapes(in: rect).forEach { $0.fill() }
            guard slashed else { return true }
            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: 2.5, y: 2.5))
            slash.line(to: NSPoint(x: 15.5, y: 15.5))
            slash.lineCapStyle = .round
            // 사선 주변을 먼저 지워서 음표와 겹쳐도 사선이 또렷하게 보이게
            NSGraphicsContext.current?.compositingOperation = .clear
            slash.lineWidth = 4
            slash.stroke()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            slash.lineWidth = 1.6
            slash.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}
