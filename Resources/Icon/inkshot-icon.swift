// Inkshot app icon, drawn by hand on the macOS grid (824 px body on 1024).
//   swift Resources/Icon/inkshot-icon.swift <out.png>
// A tilted screenshot card inside viewfinder corners, marked up the Inkshot way:
// highlighter over a line and an annotation arrow pointing at it.
import AppKit

let out = CommandLine.arguments.dropFirst().first ?? "AppIcon-1024.png"
let size = 1024

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func shadow(_ dy: CGFloat, _ blur: CGFloat, _ alpha: CGFloat, _ color: NSColor = .black) {
    let s = NSShadow()
    s.shadowOffset = NSSize(width: 0, height: dy)
    s.shadowBlurRadius = blur
    s.shadowColor = color.withAlphaComponent(alpha)
    s.set()
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: size, height: size)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// MARK: Body

let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

NSGraphicsContext.saveGraphicsState()
shadow(-14, 30, 0.35)
rgb(0x4338CA).setFill()
bodyPath.fill()
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.saveGraphicsState()
bodyPath.addClip()
NSGradient(colors: [rgb(0x6366F1), rgb(0x7C3AED), rgb(0x9333EA)],
           atLocations: [0, 0.55, 1], colorSpace: .sRGB)!.draw(in: body, angle: -60)
// Soft light from the top-left, depth towards the bottom.
NSGradient(colors: [rgb(0xFFFFFF, 0.38), rgb(0xFFFFFF, 0)])!
    .draw(fromCenter: CGPoint(x: 260, y: 860), radius: 0, toCenter: CGPoint(x: 260, y: 860), radius: 620, options: [])
NSGradient(colors: [rgb(0x1E1B4B, 0.4), rgb(0x1E1B4B, 0)])!
    .draw(in: CGRect(x: body.minX, y: body.minY, width: body.width, height: 520), angle: 90)
NSGraphicsContext.restoreGraphicsState()

rgb(0xFFFFFF, 0.25).setStroke()
let rim = NSBezierPath(roundedRect: body.insetBy(dx: 3, dy: 3), xRadius: 182, yRadius: 182)
rim.lineWidth = 6
rim.stroke()

// MARK: Screenshot card (tilted)

let card = CGRect(x: -260, y: -195, width: 520, height: 390) // centred on the origin, then moved
let cardCentre = CGPoint(x: 500, y: 520)
ctx.saveGState()
ctx.translateBy(x: cardCentre.x, y: cardCentre.y)
ctx.rotate(by: -7 * .pi / 180)

let cardPath = NSBezierPath(roundedRect: card, xRadius: 38, yRadius: 38)
NSGraphicsContext.saveGraphicsState()
shadow(-22, 44, 0.45, rgb(0x1E1B4B))
rgb(0xFFFFFF).setFill()
cardPath.fill()
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.saveGraphicsState()
cardPath.addClip()
NSGradient(starting: rgb(0xFFFFFF), ending: rgb(0xEEF2FF))!.draw(in: card, angle: -90)
// Title bar with traffic lights.
rgb(0xE0E7FF).setFill()
CGRect(x: card.minX, y: card.maxY - 58, width: card.width, height: 58).fill()
for (i, c) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
    rgb(UInt32(c)).setFill()
    NSBezierPath(ovalIn: CGRect(x: card.minX + 30 + CGFloat(i) * 34, y: card.maxY - 39, width: 20, height: 20)).fill()
}
// A small "photo": sky, sun, mountains.
let photo = CGRect(x: card.minX + 30, y: card.minY + 32, width: 200, height: 268)
let photoPath = NSBezierPath(roundedRect: photo, xRadius: 22, yRadius: 22)
NSGraphicsContext.saveGraphicsState()
photoPath.addClip()
NSGradient(starting: rgb(0x38BDF8), ending: rgb(0xA5B4FC))!.draw(in: photo, angle: -90)
rgb(0xFDE68A).setFill()
NSBezierPath(ovalIn: CGRect(x: photo.maxX - 78, y: photo.maxY - 82, width: 46, height: 46)).fill()
let far = NSBezierPath()
far.move(to: CGPoint(x: photo.minX - 10, y: photo.minY))
far.line(to: CGPoint(x: photo.minX + 70, y: photo.minY + 150))
far.line(to: CGPoint(x: photo.minX + 130, y: photo.minY + 80))
far.line(to: CGPoint(x: photo.maxX + 10, y: photo.minY + 170))
far.line(to: CGPoint(x: photo.maxX + 10, y: photo.minY))
far.close()
rgb(0x6366F1).setFill()
far.fill()
let near = NSBezierPath()
near.move(to: CGPoint(x: photo.minX - 10, y: photo.minY))
near.line(to: CGPoint(x: photo.minX + 40, y: photo.minY + 70))
near.line(to: CGPoint(x: photo.minX + 120, y: photo.minY + 20))
near.line(to: CGPoint(x: photo.maxX + 10, y: photo.minY + 95))
near.line(to: CGPoint(x: photo.maxX + 10, y: photo.minY))
near.close()
rgb(0x4338CA).setFill()
near.fill()
NSGraphicsContext.restoreGraphicsState()

// Text lines; the second one is highlighted.
let lineX = card.minX + 258
let lines: [(y: CGFloat, w: CGFloat)] = [(258, 200), (206, 170), (154, 205), (102, 150), (50, 185)]
for (i, l) in lines.enumerated() {
    let y = card.minY + l.y
    if i == 1 {
        rgb(0xFACC15, 0.9).setFill()
        NSBezierPath(roundedRect: CGRect(x: lineX - 12, y: y - 12, width: l.w + 24, height: 42), xRadius: 10, yRadius: 10).fill()
    }
    (i == 1 ? rgb(0x78350F, 0.75) : rgb(0xC7D2FE)).setFill()
    NSBezierPath(roundedRect: CGRect(x: lineX, y: y, width: l.w, height: 18), xRadius: 9, yRadius: 9).fill()
}
NSGraphicsContext.restoreGraphicsState()
ctx.restoreGState()

// MARK: Viewfinder corners (upright, around the card)

let frame = CGRect(x: 198, y: 248, width: 604, height: 548)
let arm: CGFloat = 104, r: CGFloat = 44
let corners = NSBezierPath()
func corner(_ p: CGPoint, _ dx: CGFloat, _ dy: CGFloat) {
    corners.move(to: CGPoint(x: p.x + dx * arm, y: p.y))
    corners.line(to: CGPoint(x: p.x + dx * r, y: p.y))
    corners.curve(to: CGPoint(x: p.x, y: p.y + dy * r), controlPoint1: p, controlPoint2: p)
    corners.line(to: CGPoint(x: p.x, y: p.y + dy * arm))
}
corner(CGPoint(x: frame.minX, y: frame.maxY), 1, -1)
corner(CGPoint(x: frame.maxX, y: frame.maxY), -1, -1)
corner(CGPoint(x: frame.minX, y: frame.minY), 1, 1)
corner(CGPoint(x: frame.maxX, y: frame.minY), -1, 1)
corners.lineWidth = 30
corners.lineCapStyle = .round
corners.lineJoinStyle = .round
NSGraphicsContext.saveGraphicsState()
shadow(-6, 16, 0.35, rgb(0x1E1B4B))
rgb(0xFFFFFF).setStroke()
corners.stroke()
NSGraphicsContext.restoreGraphicsState()

// MARK: Annotation arrow (Inkshot's tapered arrow) pointing at the highlight

func arrow(from a: CGPoint, to b: CGPoint, width w: CGFloat) -> NSBezierPath {
    let len = hypot(b.x - a.x, b.y - a.y)
    let d = CGPoint(x: (b.x - a.x) / len, y: (b.y - a.y) / len), n = CGPoint(x: -d.y, y: d.x)
    let headLen = w * 3.3, headHalf = headLen * 0.5
    let base = CGPoint(x: b.x - d.x * headLen * 0.82, y: b.y - d.y * headLen * 0.82)
    let wing = CGPoint(x: b.x - d.x * headLen, y: b.y - d.y * headLen)
    func pt(_ p: CGPoint, _ k: CGFloat) -> CGPoint { CGPoint(x: p.x + n.x * k, y: p.y + n.y * k) }
    let path = NSBezierPath()
    path.move(to: pt(a, w * 0.22))
    path.line(to: pt(base, w * 0.62))
    path.line(to: pt(wing, headHalf))
    path.line(to: b)
    path.line(to: pt(wing, -headHalf))
    path.line(to: pt(base, -w * 0.62))
    path.line(to: pt(a, -w * 0.22))
    path.close()
    path.lineJoinStyle = .round
    return path
}
let arrowPath = arrow(from: CGPoint(x: 838, y: 222), to: CGPoint(x: 676, y: 452), width: 40)
NSGraphicsContext.saveGraphicsState()
shadow(-10, 22, 0.45, rgb(0x450A0A))
rgb(0xFFFFFF).setStroke()
arrowPath.lineWidth = 22
arrowPath.stroke()
NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.saveGraphicsState()
arrowPath.addClip()
NSGradient(starting: rgb(0xFB923C), ending: rgb(0xEF4444))!.draw(in: arrowPath.bounds, angle: 125)
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
