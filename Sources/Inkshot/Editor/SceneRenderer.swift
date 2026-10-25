import AppKit

/// Draws the screenshot plus its annotations into the CURRENT NSGraphicsContext, which must be
/// flipped and set up in image-pixel coordinates. Shared by the canvas and the PNG export, so
/// what you see is exactly what gets copied.
enum SceneRenderer {
    /// `deviceScale` = device pixels per image pixel; keeps shadows the same on screen and in export.
    /// `isDark(rect)` tells whether the screenshot is dark under a rect (adaptive highlighter).
    static func draw(base: NSImage, pixelated: () -> NSImage, annotations: [Annotation], deviceScale: CGFloat,
                     isDark: (CGRect) -> Bool) {
        let full = CGRect(origin: .zero, size: base.size)
        base.draw(in: full, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)

        let blurRects = annotations.filter(\.isPixelate).map(\.bounds)
        if !blurRects.isEmpty {
            NSGraphicsContext.saveGraphicsState()
            let clip = NSBezierPath()
            blurRects.forEach { clip.appendRect($0) }
            clip.addClip()
            pixelated().draw(in: full, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }

        for a in annotations where !a.isPixelate {
            draw(a, deviceScale: deviceScale, isDark: isDark)
        }
    }

    static func draw(_ a: Annotation, deviceScale: CGFloat, isDark: (CGRect) -> Bool) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }

        func shadow() {
            ctx.setShadow(offset: CGSize(width: 0, height: -1 * a.unit * deviceScale),
                          blur: 4 * a.unit * deviceScale,
                          color: NSColor.black.withAlphaComponent(0.35).cgColor)
        }

        switch a.kind {
        case let .arrow(from, to):
            shadow()
            a.color.setFill()
            arrowPath(from: from, to: to, width: a.lineWidth).fill()

        case let .rect(r):
            shadow()
            a.color.setStroke()
            let path = NSBezierPath(roundedRect: r, xRadius: a.lineWidth, yRadius: a.lineWidth)
            path.lineWidth = a.lineWidth
            path.stroke()

        case let .highlight(r):
            // Multiply darkens: a real marker on light content, but invisible on dark UIs.
            // On dark content use screen instead, which lightens and keeps light text readable.
            if isDark(r) {
                ctx.setBlendMode(.screen)
                a.color.withAlphaComponent(0.7).setFill()
            } else {
                ctx.setBlendMode(.multiply)
                a.color.withAlphaComponent(0.6).setFill()
            }
            NSBezierPath(rect: r).fill()

        case .pixelate:
            break // drawn by the scene clip

        case let .pen(points):
            shadow()
            a.color.setStroke()
            let path = smoothPath(points)
            path.lineWidth = a.lineWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()

        case let .question(p):
            drawBadge(at: p, label: "?", a, ctx: ctx, shadow: shadow)

        case let .cross(r):
            let x = NSBezierPath()
            x.move(to: CGPoint(x: r.minX, y: r.minY))
            x.line(to: CGPoint(x: r.maxX, y: r.maxY))
            x.move(to: CGPoint(x: r.maxX, y: r.minY))
            x.line(to: CGPoint(x: r.minX, y: r.maxY))
            x.lineCapStyle = .round
            // A thin light rim keeps the X readable on any background.
            ctx.saveGState()
            shadow()
            (a.color.isLight ? NSColor.black : NSColor.white).withAlphaComponent(0.85).setStroke()
            x.lineWidth = a.lineWidth * 1.6 + 2 * a.unit
            x.stroke()
            ctx.restoreGState()
            a.color.setStroke()
            x.lineWidth = a.lineWidth * 1.6
            x.stroke()

        case let .number(p, n):
            drawBadge(at: p, label: "\(n)", a, ctx: ctx, shadow: shadow)

        case let .text(p, s):
            let text = s as NSString
            ctx.setLineJoin(.round)
            text.draw(at: p, withAttributes: [
                .font: a.textFont,
                .strokeColor: a.color.isLight ? NSColor.black : NSColor.white,
                .strokeWidth: 14, // positive = outline only, % of font size
            ])
            text.draw(at: p, withAttributes: [.font: a.textFont, .foregroundColor: a.color])
        }
    }

    /// Filled circle with a white rim and a bold label (step numbers, "?").
    private static func drawBadge(at p: CGPoint, label: String, _ a: Annotation, ctx: CGContext, shadow: () -> Void) {
        let r = a.badgeRadius
        let circle = NSBezierPath(ovalIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        ctx.saveGState()
        shadow()
        a.color.setFill()
        circle.fill()
        ctx.restoreGState()
        NSColor.white.setStroke()
        circle.lineWidth = 1.5 * a.unit
        circle.stroke()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: r * 1.15, weight: .bold),
            .foregroundColor: a.color.isLight ? NSColor.black : NSColor.white,
        ]
        let text = label as NSString
        let size = text.size(withAttributes: attrs)
        text.draw(at: CGPoint(x: p.x - size.width / 2, y: p.y - size.height / 2), withAttributes: attrs)
    }

    /// Freehand points smoothed with quadratic curves through the midpoints.
    static func smoothPath(_ points: [CGPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 1 else {
            path.line(to: first) // a single click: round caps draw a dot
            return path
        }
        for i in 1..<points.count {
            let c = points[i - 1], next = points[i]
            let mid = CGPoint(x: (c.x + next.x) / 2, y: (c.y + next.y) / 2)
            let start = path.currentPoint
            // quadratic (start, c, mid) as a cubic
            path.curve(to: mid,
                       controlPoint1: CGPoint(x: start.x + 2 / 3 * (c.x - start.x), y: start.y + 2 / 3 * (c.y - start.y)),
                       controlPoint2: CGPoint(x: mid.x + 2 / 3 * (c.x - mid.x), y: mid.y + 2 / 3 * (c.y - mid.y)))
        }
        path.line(to: points[points.count - 1])
        return path
    }

    /// Tapered shaft + solid head, as one polygon.
    static func arrowPath(from a: CGPoint, to b: CGPoint, width w: CGFloat) -> NSBezierPath {
        let len = a.distance(to: b)
        let path = NSBezierPath()
        guard len > 1 else { return path }
        let d = CGPoint(x: (b.x - a.x) / len, y: (b.y - a.y) / len)
        let n = CGPoint(x: -d.y, y: d.x)
        let headLen = min(w * 4.5 + 4, len * 0.6)
        let headHalf = headLen * 0.55
        let base = CGPoint(x: b.x - d.x * headLen * 0.85, y: b.y - d.y * headLen * 0.85)
        let wing = CGPoint(x: b.x - d.x * headLen, y: b.y - d.y * headLen)
        func pt(_ p: CGPoint, _ k: CGFloat) -> CGPoint { CGPoint(x: p.x + n.x * k, y: p.y + n.y * k) }

        path.move(to: pt(a, w * 0.2))
        path.line(to: pt(base, w * 0.6))
        path.line(to: pt(wing, headHalf))
        path.line(to: b)
        path.line(to: pt(wing, -headHalf))
        path.line(to: pt(base, -w * 0.6))
        path.line(to: pt(a, -w * 0.2))
        path.close()
        path.lineJoinStyle = .round
        return path
    }
}
