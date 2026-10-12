import AppKit

enum Tool: String, CaseIterable, Identifiable {
    case select, arrow, rect, text, number, highlight, pixelate, crop

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .arrow: "arrow.up.right"
        case .rect: "rectangle"
        case .text: "textformat"
        case .number: "1.circle"
        case .highlight: "highlighter"
        case .pixelate: "checkerboard.rectangle"
        case .crop: "crop"
        }
    }

    var title: String {
        switch self {
        case .select: "Выбор / перемещение"
        case .arrow: "Стрелка"
        case .rect: "Рамка"
        case .text: "Текст"
        case .number: "Номер шага"
        case .highlight: "Маркер"
        case .pixelate: "Размытие"
        case .crop: "Обрезка"
        }
    }

    var key: String {
        switch self {
        case .select: "V"
        case .arrow: "A"
        case .rect: "R"
        case .text: "T"
        case .number: "N"
        case .highlight: "H"
        case .pixelate: "B"
        case .crop: "C"
        }
    }

    /// Physical key codes, so shortcuts work with any keyboard layout.
    static func forKeyCode(_ code: UInt16) -> Tool? {
        switch code {
        case 9: .select
        case 0: .arrow
        case 15: .rect
        case 17: .text
        case 45: .number
        case 4: .highlight
        case 11: .pixelate
        case 8: .crop
        default: nil
        }
    }
}

enum StrokeSize: CGFloat, CaseIterable {
    case s = 1, m = 1.6, l = 2.6
}

enum Palette {
    static let colors: [NSColor] = [
        NSColor(srgbRed: 1.00, green: 0.23, blue: 0.19, alpha: 1), // red
        NSColor(srgbRed: 1.00, green: 0.58, blue: 0.00, alpha: 1), // orange
        NSColor(srgbRed: 1.00, green: 0.84, blue: 0.04, alpha: 1), // yellow
        NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1), // green
        NSColor(srgbRed: 0.00, green: 0.48, blue: 1.00, alpha: 1), // blue
        NSColor(srgbRed: 0.69, green: 0.32, blue: 0.87, alpha: 1), // purple
        NSColor(srgbRed: 0.08, green: 0.08, blue: 0.09, alpha: 1), // black
        NSColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 1), // white
    ]
}

/// One mark on the screenshot. All geometry is in image pixels (top-left origin).
struct Annotation: Identifiable {
    enum Kind {
        case arrow(CGPoint, CGPoint)
        case rect(CGRect)
        case highlight(CGRect)
        case pixelate(CGRect)
        case number(CGPoint, Int)
        case text(CGPoint, String)
    }

    let id = UUID()
    var kind: Kind
    var color: NSColor
    /// Image pixels per design point: capture scale × stroke size.
    var unit: CGFloat

    var lineWidth: CGFloat { 3 * unit }
    var fontSize: CGFloat { 18 * unit }
    var badgeRadius: CGFloat { 12 * unit }

    var isPixelate: Bool {
        if case .pixelate = kind { return true }
        return false
    }

    var textFont: NSFont { .systemFont(ofSize: fontSize, weight: .bold) }

    var bounds: CGRect {
        switch kind {
        case let .arrow(a, b):
            return CGRect(from: a, to: b).insetBy(dx: -lineWidth * 3, dy: -lineWidth * 3)
        case let .rect(r), let .highlight(r), let .pixelate(r):
            return r
        case let .number(p, _):
            return CGRect(x: p.x - badgeRadius, y: p.y - badgeRadius, width: badgeRadius * 2, height: badgeRadius * 2)
        case let .text(p, s):
            let size = (s as NSString).size(withAttributes: [.font: textFont])
            return CGRect(origin: p, size: size)
        }
    }

    func hitTest(_ p: CGPoint) -> Bool {
        let slop = 6 * unit
        switch kind {
        case let .arrow(a, b):
            return distance(from: p, toSegment: a, b) < lineWidth + slop
        default:
            return bounds.insetBy(dx: -slop, dy: -slop).contains(p)
        }
    }

    func offset(by d: CGVector) -> Annotation {
        var copy = self
        func mv(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + d.dx, y: p.y + d.dy) }
        switch kind {
        case let .arrow(a, b): copy.kind = .arrow(mv(a), mv(b))
        case let .rect(r): copy.kind = .rect(r.offsetBy(dx: d.dx, dy: d.dy))
        case let .highlight(r): copy.kind = .highlight(r.offsetBy(dx: d.dx, dy: d.dy))
        case let .pixelate(r): copy.kind = .pixelate(r.offsetBy(dx: d.dx, dy: d.dy))
        case let .number(p, n): copy.kind = .number(mv(p), n)
        case let .text(p, s): copy.kind = .text(mv(p), s)
        }
        return copy
    }

    private func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return p.distance(to: a) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return p.distance(to: CGPoint(x: a.x + t * dx, y: a.y + t * dy))
    }
}
