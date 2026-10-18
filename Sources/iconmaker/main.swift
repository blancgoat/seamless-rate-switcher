import AppKit
import NoteGlyph

// 앱 아이콘 생성: iconmaker <출력.iconset>
// 터미널 앱처럼 짙은 회색→검정 바탕, 가운데 흰 음표, 오른쪽 아래에 작게 "44.1k".

guard CommandLine.arguments.count == 2 else {
    print("사용: iconmaker <출력.iconset>")
    exit(1)
}
let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func gray(_ white: CGFloat, _ alpha: CGFloat = 1) -> NSColor { NSColor(white: white, alpha: alpha) }

/// 1024 기준 좌표로 설계. 128px 미만에서는 글씨가 4~8px로 뭉개지므로 빼고 음표만 그린다.
func drawIcon(size: CGFloat, showLabel: Bool) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let k = size / 1024
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: k, y: k)

    // macOS 아이콘 그리드: 1024 캔버스 안 824 사각형, 모서리 반경 약 185
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

    // 바닥 그림자
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = gray(0, 0.35)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    gray(0.1).setFill()
    tilePath.fill()
    NSGraphicsContext.restoreGraphicsState()

    // 바탕: 위는 짙은 회색, 아래는 거의 검정
    NSGradient(starting: gray(0.20), ending: gray(0.075))!.draw(in: tilePath, angle: -90)

    // 음표 뒤 은은한 빛 (부드러운 느낌)
    NSGraphicsContext.saveGraphicsState()
    tilePath.addClip()
    NSGradient(colors: [gray(1, 0.09), gray(1, 0)])!
        .draw(fromCenter: NSPoint(x: 512, y: 530), radius: 0, toCenter: NSPoint(x: 512, y: 530), radius: 420, options: [])
    NSGraphicsContext.restoreGraphicsState()

    // 위쪽 테두리 하이라이트: 테두리 선 모양 안에만 위→아래로 옅어지는 흰색
    NSGraphicsContext.saveGraphicsState()
    let rim = NSBezierPath(roundedRect: tile.insetBy(dx: 2, dy: 2), xRadius: 183, yRadius: 183)
    NSBezierPath(cgPath: rim.cgPath.copy(strokingWithWidth: 4, lineCap: .butt, lineJoin: .round, miterLimit: 10)).addClip()
    NSGradient(colors: [gray(1, 0.22), gray(1, 0.04), gray(1, 0)], atLocations: [0, 0.35, 1], colorSpace: .deviceRGB)!
        .draw(in: tile, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // 음표: 흰색→밝은 회색 그라데이션 + 아래로 부드러운 그림자
    // 가운데 정렬. 도형의 무게중심이 18 좌표계에서 약간 아래(8.4)라 그만큼 올린다
    let noteSide: CGFloat = 540
    let noteRect = NSRect(x: 512 - noteSide / 2, y: 512 - noteSide / 2 + noteSide * 0.6 / 18, width: noteSide, height: noteSide)
    let notes = NoteGlyph.shapes(in: noteRect)
    NSGraphicsContext.saveGraphicsState()
    let noteShadow = NSShadow()
    noteShadow.shadowColor = gray(0, 0.45)
    noteShadow.shadowBlurRadius = 18
    noteShadow.shadowOffset = NSSize(width: 0, height: -8)
    noteShadow.set()
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    for shape in notes {
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        NSGradient(starting: gray(1), ending: gray(0.84))!.draw(in: noteRect, angle: -90)
        NSGraphicsContext.restoreGraphicsState()
    }
    ctx.endTransparencyLayer()
    NSGraphicsContext.restoreGraphicsState()

    // "44.1k": 오른쪽 아래에 작게. 터미널 느낌의 고정폭 글꼴, 흰색 계열
    if showLabel {
        let label = NSAttributedString(string: "44.1k", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 78, weight: .medium),
            .foregroundColor: gray(0.80),
        ])
        let s = label.size()
        label.draw(at: NSPoint(x: tile.maxX - 70 - s.width, y: tile.minY + 52))
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// iconset 규격: 16, 32, 128, 256, 512 각각 @1x, @2x
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let rep = drawIcon(size: px, showLabel: px >= 128)
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try rep.representation(using: .png, properties: [:])!.write(to: outDir.appendingPathComponent(name))
    }
}
print("생성됨: \(outDir.path)")
