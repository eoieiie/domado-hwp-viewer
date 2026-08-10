import AppKit
import CoreGraphics

func render(size: Int) -> Data {
    let s = CGFloat(size)
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)

    // Warm cream squircle so the red tomato stays legible at 16pt
    let inset = s * 0.055
    let bg = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: bg, cornerWidth: s * 0.225, cornerHeight: s * 0.225, transform: nil))
    ctx.clip()
    let grad = CGGradient(colorsSpace: cs, colors: [
        CGColor(red: 1.00, green: 0.96, blue: 0.92, alpha: 1),
        CGColor(red: 1.00, green: 0.88, blue: 0.80, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])

    // Document sheet peeking out behind the tomato — this is a document app
    let dw = s * 0.40, dh = s * 0.50
    let dx = s * 0.50 - dw * 0.30, dy = s * 0.30
    let fold = dw * 0.26
    let doc = CGMutablePath()
    doc.move(to: CGPoint(x: dx, y: dy))
    doc.addLine(to: CGPoint(x: dx + dw, y: dy))
    doc.addLine(to: CGPoint(x: dx + dw, y: dy + dh - fold))
    doc.addLine(to: CGPoint(x: dx + dw - fold, y: dy + dh))
    doc.addLine(to: CGPoint(x: dx, y: dy + dh))
    doc.closeSubpath()
    ctx.addPath(doc)
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.96))
    ctx.fillPath()
    ctx.addPath(doc)
    ctx.setStrokeColor(CGColor(red: 0.85, green: 0.62, blue: 0.50, alpha: 0.55))
    ctx.setLineWidth(max(1, s * 0.008))
    ctx.strokePath()
    // text lines on the sheet
    ctx.setFillColor(CGColor(red: 0.80, green: 0.60, blue: 0.50, alpha: 0.45))
    for i in 0..<3 {
        let ly = dy + dh - fold - s * 0.055 - CGFloat(i) * s * 0.055
        ctx.fill(CGRect(x: dx + s * 0.05, y: ly, width: dw - s * 0.10, height: max(1, s * 0.018)))
    }

    // Tomato body
    let r = s * 0.245
    let cx = s * 0.415, cy = s * 0.375
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: cx - r * 1.06, y: cy - r, width: r * 2.12, height: r * 1.94))
    ctx.clip()
    let body = CGGradient(colorsSpace: cs, colors: [
        CGColor(red: 0.96, green: 0.34, blue: 0.26, alpha: 1),
        CGColor(red: 0.78, green: 0.11, blue: 0.12, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(body,
                           startCenter: CGPoint(x: cx - r * 0.35, y: cy + r * 0.45), startRadius: 0,
                           endCenter: CGPoint(x: cx, y: cy), endRadius: r * 1.5, options: [])
    ctx.restoreGState()

    // Specular highlight
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.30))
    ctx.saveGState()
    ctx.translateBy(x: cx - r * 0.42, y: cy + r * 0.42)
    ctx.rotate(by: -0.5)
    ctx.addEllipse(in: CGRect(x: -r * 0.28, y: -r * 0.15, width: r * 0.56, height: r * 0.30))
    ctx.fillPath()
    ctx.restoreGState()

    // Green calyx: five leaves radiating from the stem
    let green = CGColor(red: 0.30, green: 0.66, blue: 0.28, alpha: 1)
    let darkGreen = CGColor(red: 0.20, green: 0.50, blue: 0.20, alpha: 1)
    ctx.setFillColor(green)
    let top = CGPoint(x: cx, y: cy + r * 0.86)
    for k in 0..<5 {
        let a = CGFloat(k) / 5 * .pi * 2 - .pi / 2
        let leaf = CGMutablePath()
        let tip = CGPoint(x: top.x + cos(a) * r * 0.82, y: top.y + sin(a) * r * 0.42)
        let p = CGFloat(0.34)
        leaf.move(to: top)
        leaf.addQuadCurve(to: tip,
                          control: CGPoint(x: top.x + cos(a + p) * r * 0.55,
                                           y: top.y + sin(a + p) * r * 0.42))
        leaf.addQuadCurve(to: top,
                          control: CGPoint(x: top.x + cos(a - p) * r * 0.55,
                                           y: top.y + sin(a - p) * r * 0.42))
        ctx.addPath(leaf)
        ctx.fillPath()
    }
    // Stem
    ctx.setFillColor(darkGreen)
    ctx.saveGState()
    ctx.translateBy(x: top.x, y: top.y)
    ctx.addPath(CGPath(roundedRect: CGRect(x: -r * 0.075, y: 0, width: r * 0.15, height: r * 0.30),
                       cornerWidth: r * 0.075, cornerHeight: r * 0.075, transform: nil))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.restoreGState()

    let out = ctx.makeImage()!
    return NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])!
}

let dir = "/tmp/iconsrc/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: dir)
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
for (px, name) in [(16,"16x16"),(32,"16x16@2x"),(32,"32x32"),(64,"32x32@2x"),
                   (128,"128x128"),(256,"128x128@2x"),(256,"256x256"),(512,"256x256@2x"),
                   (512,"512x512"),(1024,"512x512@2x")] {
    try! render(size: px).write(to: URL(fileURLWithPath: "\(dir)/icon_\(name).png"))
}
print("생성 완료")
