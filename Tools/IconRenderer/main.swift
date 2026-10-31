import AppKit

// Usage:
//   icon-renderer appicon <output.iconset>
//   icon-renderer preview <output-dir>   (1024px PNG, for review)
//
// Two keycaps: the front one shows "R", the one behind shows the same letter mirrored,
// as if seen from the other side of the flip. An arrow arcs from the back key to the front one.

func renderPNG(pixels: Int, to url: URL, draw: () -> Void) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}

func roundedFont(size: CGFloat) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: .heavy)
    guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
    return NSFont(descriptor: descriptor, size: size) ?? base
}

/// Draws a keycap centered on the origin of the current coordinate system.
func drawKeycap(side: CGFloat, top: (NSColor, NSColor), base: NSColor, label: String, labelColor: NSColor, mirrored: Bool) {
    let radius = side * 0.2
    let depth = side * 0.07

    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.35)
    shadow.shadowBlurRadius = side * 0.08
    shadow.shadowOffset = NSSize(width: 0, height: -side * 0.05)

    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    base.setFill()
    NSBezierPath(roundedRect: NSRect(x: -side / 2, y: -side / 2 - depth, width: side, height: side),
                 xRadius: radius, yRadius: radius).fill()
    NSGraphicsContext.restoreGraphicsState()

    let face = NSBezierPath(roundedRect: NSRect(x: -side / 2, y: -side / 2, width: side, height: side),
                            xRadius: radius, yRadius: radius)
    NSGradient(starting: top.0, ending: top.1)?.draw(in: face, angle: 90)

    // Concave dish on the key face.
    let inset = side * 0.11
    let dish = NSBezierPath(roundedRect: NSRect(x: -side / 2 + inset, y: -side / 2 + inset * 1.3,
                                                width: side - inset * 2, height: side - inset * 2.1),
                            xRadius: radius * 0.7, yRadius: radius * 0.7)
    NSGradient(starting: NSColor(white: 0, alpha: 0.06), ending: NSColor(white: 1, alpha: 0.18))?.draw(in: dish, angle: 90)

    let attrs: [NSAttributedString.Key: Any] = [.font: roundedFont(size: side * 0.56), .foregroundColor: labelColor]
    let text = NSAttributedString(string: label, attributes: attrs)
    let size = text.size()
    NSGraphicsContext.saveGraphicsState()
    if mirrored {
        let flip = NSAffineTransform()
        flip.scaleX(by: -1, yBy: 1)
        flip.concat()
    }
    text.draw(at: NSPoint(x: -size.width / 2, y: -size.height / 2 + side * 0.02))
    NSGraphicsContext.restoreGraphicsState()
}

func drawAppIcon(side: CGFloat) {
    let scale = NSAffineTransform()
    scale.scale(by: side / 1024)
    scale.concat()

    let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    NSGradient(starting: rgb(0.20, 0.80, 0.72), ending: rgb(0.10, 0.27, 0.55))?.draw(in: tile, angle: 90)

    NSGraphicsContext.saveGraphicsState()
    tile.addClip()

    // Soft light from the top-left.
    NSGradient(starting: NSColor(white: 1, alpha: 0.18), ending: NSColor(white: 1, alpha: 0))?
        .draw(fromCenter: NSPoint(x: 260, y: 860), radius: 0, toCenter: NSPoint(x: 260, y: 860), radius: 620, options: [])

    // Back keycap: mirrored letter.
    NSGraphicsContext.saveGraphicsState()
    let back = NSAffineTransform()
    back.translateX(by: 395, yBy: 615)
    back.rotate(byDegrees: 12)
    back.concat()
    drawKeycap(side: 300, top: (rgb(0.72, 0.86, 0.92), rgb(0.58, 0.74, 0.84)), base: rgb(0.32, 0.45, 0.58),
               label: "R", labelColor: rgb(0.20, 0.34, 0.48, 0.75), mirrored: true)
    NSGraphicsContext.restoreGraphicsState()

    // Front keycap.
    NSGraphicsContext.saveGraphicsState()
    let front = NSAffineTransform()
    front.translateX(by: 600, yBy: 415)
    front.rotate(byDegrees: -6)
    front.concat()
    drawKeycap(side: 360, top: (rgb(1, 1, 1), rgb(0.88, 0.92, 0.96)), base: rgb(0.55, 0.62, 0.72),
               label: "R", labelColor: rgb(0.10, 0.22, 0.40), mirrored: false)
    NSGraphicsContext.restoreGraphicsState()

    // Flip arrow, clockwise over the top-right, from the back key to the front key.
    let center = NSPoint(x: 512, y: 500)
    let radius: CGFloat = 330
    let startAngle: CGFloat = 105, endAngle: CGFloat = 14
    let arc = NSBezierPath()
    arc.appendArc(withCenter: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: true)
    arc.lineWidth = 34
    arc.lineCapStyle = .round

    let arrowShadow = NSShadow()
    arrowShadow.shadowColor = NSColor(white: 0, alpha: 0.3)
    arrowShadow.shadowBlurRadius = 16
    arrowShadow.shadowOffset = NSSize(width: 0, height: -6)
    NSGraphicsContext.saveGraphicsState()
    arrowShadow.set()
    rgb(1, 0.66, 0.22).set()
    arc.stroke()

    let theta = endAngle * .pi / 180
    let tip = NSPoint(x: center.x + radius * cos(theta), y: center.y + radius * sin(theta))
    let tangent = NSPoint(x: sin(theta), y: -cos(theta))   // direction of clockwise travel
    let normal = NSPoint(x: cos(theta), y: sin(theta))
    let head = NSBezierPath()
    head.move(to: NSPoint(x: tip.x + tangent.x * 70, y: tip.y + tangent.y * 70))
    head.line(to: NSPoint(x: tip.x - tangent.x * 10 + normal.x * 58, y: tip.y - tangent.y * 10 + normal.y * 58))
    head.line(to: NSPoint(x: tip.x - tangent.x * 10 - normal.x * 58, y: tip.y - tangent.y * 10 - normal.y * 58))
    head.close()
    head.lineJoinStyle = .round
    head.lineWidth = 10
    head.fill()
    head.stroke()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
}

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write("usage: icon-renderer appicon|preview <output>\n".data(using: .utf8)!)
    exit(2)
}
let out = URL(fileURLWithPath: args[2])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

switch args[1] {
case "appicon":
    for points in [16, 32, 128, 256, 512] {
        for factor in [1, 2] {
            let pixels = points * factor
            let name = factor == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
            try renderPNG(pixels: pixels, to: out.appendingPathComponent(name)) { drawAppIcon(side: CGFloat(pixels)) }
        }
    }
case "preview":
    try renderPNG(pixels: 1024, to: out.appendingPathComponent("appicon.png")) { drawAppIcon(side: 1024) }
default:
    exit(2)
}
