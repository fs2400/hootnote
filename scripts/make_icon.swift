// Renders Hootnote's icons:
//   <out>/AppIcon.iconset/*.png  a playful cartoon owl on a night-blue tile (app icon)
//   <out>/MenuBarOwl.png         a 36x36 template silhouette for the menu bar
// Pure vector drawing; no external assets.
import AppKit

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> CGRect {
    CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2)
}

/// Draws the owl in a 1024-point space with y pointing down.
func drawOwl(_ c: CGContext) {
    // Tile: night sky
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
    c.saveGState()
    c.addPath(tilePath)
    c.clip()
    let sky = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0x2B3A78), color(0x141A3C)] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(sky, start: CGPoint(x: 300, y: 100), end: CGPoint(x: 724, y: 924), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    // Moon behind the owl
    c.setFillColor(color(0xFFE9B0, 0.16))
    c.fillEllipse(in: ellipse(690, 330, 190, 190))
    c.setFillColor(color(0xFFE9B0, 0.10))
    c.fillEllipse(in: ellipse(690, 330, 250, 250))
    // Stars
    c.setFillColor(color(0xFFFFFF, 0.85))
    for (x, y, r) in [(250.0, 250.0, 9.0), (330.0, 180.0, 6.0), (820.0, 560.0, 7.0), (210.0, 470.0, 5.0)] {
        c.fillEllipse(in: ellipse(x, y, r, r))
    }
    // Branch
    c.setFillColor(color(0x6B3E22))
    c.addPath(CGPath(roundedRect: CGRect(x: 120, y: 842, width: 784, height: 44), cornerWidth: 22, cornerHeight: 22, transform: nil))
    c.fillPath()
    c.setFillColor(color(0x8E5730))
    c.addPath(CGPath(roundedRect: CGRect(x: 120, y: 842, width: 784, height: 16), cornerWidth: 8, cornerHeight: 8, transform: nil))
    c.fillPath()
    c.restoreGState()

    let brown = color(0x9A5B34), brownDark = color(0x6E3B1F), tan = color(0xF0C48E), cream = color(0xFBEBD0)
    let ink = color(0x1B1F3B), amber = color(0xFFB627), beak = color(0xFF8A1C)

    // Ear tufts (behind head)
    c.setFillColor(brownDark)
    for side in [-1.0, 1.0] {
        c.move(to: CGPoint(x: 512 + side * 120, y: 300))
        c.addQuadCurve(to: CGPoint(x: 512 + side * 205, y: 168), control: CGPoint(x: 512 + side * 140, y: 200))
        c.addQuadCurve(to: CGPoint(x: 512 + side * 205, y: 330), control: CGPoint(x: 512 + side * 228, y: 250))
        c.closePath()
        c.fillPath()
    }
    // Body and head: one round silhouette
    c.setShadow(offset: CGSize(width: 0, height: 10), blur: 30, color: color(0x000000, 0.35))
    c.setFillColor(brown)
    c.fillEllipse(in: ellipse(512, 640, 226, 230))
    c.fillEllipse(in: ellipse(512, 450, 222, 205))
    c.setShadow(offset: .zero, blur: 0, color: nil)
    // Wings
    c.setFillColor(brownDark)
    for side in [-1.0, 1.0] {
        c.saveGState()
        c.translateBy(x: 512 + side * 205, y: 680)
        c.rotate(by: side * -0.22)
        c.fillEllipse(in: ellipse(0, 0, 62, 150))
        c.restoreGState()
    }
    // Belly with feather scallops
    c.setFillColor(cream)
    c.fillEllipse(in: ellipse(512, 702, 148, 150))
    c.setStrokeColor(color(0xC79A6A))
    c.setLineWidth(9)
    c.setLineCap(.round)
    for (row, y) in [640.0, 700.0, 760.0].enumerated() {
        let count = row == 1 ? 3 : 2
        let span = row == 1 ? 150.0 : 100.0
        for i in 0..<count {
            let x = 512 - span / 2 + span * Double(i) / Double(max(count - 1, 1))
            c.addArc(center: CGPoint(x: x, y: y - 12), radius: 22, startAngle: .pi * 0.15, endAngle: .pi * 0.85, clockwise: false)
            c.strokePath()
        }
    }
    // Face disc
    c.setFillColor(tan)
    c.fillEllipse(in: ellipse(424, 470, 128, 122))
    c.fillEllipse(in: ellipse(600, 470, 128, 122))
    // Eyes: amber rings, whites, pupils looking slightly up and in, two highlights each
    for (cx, look) in [(426.0, 10.0), (598.0, -10.0)] {
        c.setFillColor(amber)
        c.fillEllipse(in: ellipse(cx, 470, 100, 100))
        c.setFillColor(color(0xFFFFFF))
        c.fillEllipse(in: ellipse(cx, 470, 82, 82))
        c.setFillColor(ink)
        c.fillEllipse(in: ellipse(cx + look, 478, 50, 52))
        c.setFillColor(color(0xFFFFFF))
        c.fillEllipse(in: ellipse(cx + look + 16, 458, 17, 17))
        c.fillEllipse(in: ellipse(cx + look - 16, 500, 8, 8))
    }
    // Brows: a little cheeky lift on one side
    c.setStrokeColor(brownDark)
    c.setLineWidth(18)
    c.move(to: CGPoint(x: 352, y: 352)); c.addQuadCurve(to: CGPoint(x: 476, y: 360), control: CGPoint(x: 410, y: 318)); c.strokePath()
    c.move(to: CGPoint(x: 548, y: 366)); c.addQuadCurve(to: CGPoint(x: 672, y: 352), control: CGPoint(x: 612, y: 338)); c.strokePath()
    // Beak
    c.setFillColor(beak)
    c.move(to: CGPoint(x: 476, y: 548))
    c.addQuadCurve(to: CGPoint(x: 548, y: 548), control: CGPoint(x: 512, y: 532))
    c.addQuadCurve(to: CGPoint(x: 512, y: 610), control: CGPoint(x: 540, y: 586))
    c.addQuadCurve(to: CGPoint(x: 476, y: 548), control: CGPoint(x: 484, y: 586))
    c.fillPath()
    // Cheeks
    c.setFillColor(color(0xFF7A6B, 0.45))
    c.fillEllipse(in: ellipse(352, 560, 30, 18))
    c.fillEllipse(in: ellipse(672, 560, 30, 18))
    // Feet gripping the branch
    c.setFillColor(beak)
    for fx in [452.0, 572.0] {
        for dx in [-24.0, 0.0, 24.0] { c.fillEllipse(in: ellipse(fx + dx, 850, 15, 20)) }
    }
}

func renderIcon(px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    let c = ctx.cgContext
    let s = CGFloat(px) / 1024
    c.translateBy(x: 0, y: CGFloat(px))
    c.scaleBy(x: s, y: -s)
    drawOwl(c)
    ctx.flushGraphics()
    return rep
}

/// Menu bar: owl head with tufts, eyes cut out, as a black template.
func renderMenuBar(px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    let c = ctx.cgContext
    let s = CGFloat(px) / 36
    c.translateBy(x: 0, y: CGFloat(px))
    c.scaleBy(x: s, y: -s)
    // One round body, two short tufts angled out, big eye rings, a beak notch.
    let path = CGMutablePath()
    path.addEllipse(in: ellipse(18, 20.5, 12, 13.5))
    path.move(to: CGPoint(x: 9.5, y: 11)); path.addLine(to: CGPoint(x: 5, y: 4.5)); path.addLine(to: CGPoint(x: 14, y: 8.5)); path.closeSubpath()
    path.move(to: CGPoint(x: 26.5, y: 11)); path.addLine(to: CGPoint(x: 31, y: 4.5)); path.addLine(to: CGPoint(x: 22, y: 8.5)); path.closeSubpath()
    c.addPath(path)
    c.setFillColor(CGColor(gray: 0, alpha: 1))
    c.fillPath()
    // Eye rings and beak are cut out of the silhouette.
    c.setBlendMode(.clear)
    c.fillEllipse(in: ellipse(12.8, 16.5, 5.4, 5.4))
    c.fillEllipse(in: ellipse(23.2, 16.5, 5.4, 5.4))
    c.move(to: CGPoint(x: 16.3, y: 22)); c.addLine(to: CGPoint(x: 19.7, y: 22)); c.addLine(to: CGPoint(x: 18, y: 25.5)); c.closePath(); c.fillPath()
    c.setBlendMode(.normal)
    c.fillEllipse(in: ellipse(13.4, 16.9, 2.6, 2.6))
    c.fillEllipse(in: ellipse(22.6, 16.9, 2.6, 2.6))
    ctx.flushGraphics()
    return rep
}

let out = CommandLine.arguments[1]
let iconset = "\(out)/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! renderIcon(px: px).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(iconset)/icon_\(name).png"))
}
try! renderMenuBar(px: 36).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/MenuBarOwl.png"))
