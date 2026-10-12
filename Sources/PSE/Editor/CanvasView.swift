import AppKit
import Combine

/// Shows the (cropped) screenshot aspect-fit and turns mouse input into annotations.
final class CanvasView: NSView, NSTextFieldDelegate {
    private let model: EditorModel
    private var cancellables: Set<AnyCancellable> = []

    var onCopyAndClose: (() -> Void)?
    var onSave: (() -> Void)?
    var onClose: (() -> Void)?

    private var dragStart: CGPoint?       // image px
    private var draft: Annotation?
    private var cropDraft: CGRect?
    private var moveLast: CGPoint?
    private var moved = false

    private var textField: NSTextField?
    private var textOrigin: CGPoint?      // image px

    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero)
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.needsDisplay = true
                self.window?.invalidateCursorRects(for: self)
            }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        let cursor: NSCursor = switch model.tool {
        case .select: .arrow
        case .text: .iBeam
        default: .crosshair
        }
        addCursorRect(displayRect, cursor: cursor)
    }

    // MARK: Geometry

    /// Where the crop region lands in the view (never upscaled beyond 1 point per image point).
    private var displayRect: CGRect {
        let c = model.crop
        let inset = bounds.insetBy(dx: 16, dy: 16)
        let s = min(inset.width / c.width, inset.height / c.height, 1 / model.scale)
        let size = CGSize(width: c.width * s, height: c.height * s)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    private var viewScale: CGFloat { displayRect.width / model.crop.width }

    private func toImage(_ p: CGPoint) -> CGPoint {
        let d = displayRect, s = viewScale
        return CGPoint(x: (p.x - d.minX) / s + model.crop.minX, y: (p.y - d.minY) / s + model.crop.minY)
    }

    private func toView(_ p: CGPoint) -> CGPoint {
        let d = displayRect, s = viewScale
        return CGPoint(x: (p.x - model.crop.minX) * s + d.minX, y: (p.y - model.crop.minY) * s + d.minY)
    }

    private func toView(_ r: CGRect) -> CGRect {
        let o = toView(r.origin)
        return CGRect(x: o.x, y: o.y, width: r.width * viewScale, height: r.height * viewScale)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.blended(withFraction: 0.35, of: .black)?.setFill()
        bounds.fill()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let d = displayRect, s = viewScale
        let backing = window?.backingScaleFactor ?? 2
        var list = model.annotations
        if let draft { list.append(draft) }

        ctx.saveGState()
        ctx.clip(to: d)
        ctx.interpolationQuality = .high
        ctx.translateBy(x: d.minX, y: d.minY)
        ctx.scaleBy(x: s, y: s)
        ctx.translateBy(x: -model.crop.minX, y: -model.crop.minY)
        SceneRenderer.draw(base: model.base, pixelated: model.pixelated, annotations: list, deviceScale: s * backing)
        ctx.restoreGState()

        if let sel = model.selected {
            let r = toView(sel.bounds).insetBy(dx: -5, dy: -5)
            let path = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
            path.lineWidth = 1.5
            path.setLineDash([5, 4], count: 2, phase: 0)
            NSColor.controlAccentColor.setStroke()
            path.stroke()
        }

        // Draft pixelate regions get an outline, otherwise they're invisible on flat areas.
        if let draft, draft.isPixelate {
            NSColor.white.withAlphaComponent(0.8).setStroke()
            let path = NSBezierPath(rect: toView(draft.bounds))
            path.setLineDash([4, 3], count: 2, phase: 0)
            path.stroke()
        }

        if let c = cropDraft {
            let r = toView(c)
            let outside = NSBezierPath(rect: d)
            outside.appendRect(r)
            outside.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.5).setFill()
            outside.fill()
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: r)
            border.lineWidth = 1.5
            border.setLineDash([6, 4], count: 2, phase: 0)
            border.stroke()
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let v = convert(event.locationInWindow, from: nil)
        let p = toImage(v)

        if textField != nil {
            commitText()
            if model.tool == .text { return }
        }

        switch model.tool {
        case .select:
            if let hit = model.annotations.last(where: { $0.hitTest(p) }) {
                if event.clickCount == 2, case let .text(origin, string) = hit.kind {
                    model.commit { model.annotations.removeAll { $0.id == hit.id } }
                    beginText(at: origin, initial: string, color: hit.color)
                    return
                }
                model.selectedID = hit.id
                model.beginLiveChange()
                moveLast = p
                moved = false
            } else {
                model.selectedID = nil
            }
        case .number:
            model.add(Annotation(kind: .number(p, model.nextNumber), color: model.color, unit: model.unit))
        case .text:
            beginText(at: p, initial: "", color: model.color)
        default:
            dragStart = p
        }
    }

    override func mouseDragged(with event: NSEvent) {
        var p = toImage(convert(event.locationInWindow, from: nil))

        if let last = moveLast, let id = model.selectedID,
           let i = model.annotations.firstIndex(where: { $0.id == id }) {
            model.annotations[i] = model.annotations[i].offset(by: CGVector(dx: p.x - last.x, dy: p.y - last.y))
            moveLast = p
            moved = true
            return
        }

        guard let start = dragStart else { return }
        let shift = event.modifierFlags.contains(.shift)
        let kind: Annotation.Kind
        switch model.tool {
        case .arrow:
            if shift { p = snap45(from: start, to: p) }
            kind = .arrow(start, p)
        case .rect, .highlight, .pixelate, .crop:
            if shift {
                let side = max(abs(p.x - start.x), abs(p.y - start.y))
                p = CGPoint(x: start.x + (p.x < start.x ? -side : side), y: start.y + (p.y < start.y ? -side : side))
            }
            let r = CGRect(from: start, to: p)
            if model.tool == .crop {
                cropDraft = r.intersection(model.crop)
                needsDisplay = true
                return
            }
            kind = model.tool == .rect ? .rect(r) : model.tool == .highlight ? .highlight(r) : .pixelate(r)
        default:
            return
        }
        draft = Annotation(kind: kind, color: model.color, unit: model.unit)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if moveLast != nil {
            moveLast = nil
            if moved { model.endLiveChange() }
            return
        }
        defer { dragStart = nil; draft = nil; cropDraft = nil; needsDisplay = true }

        let minSize = 4 * model.scale
        if let c = cropDraft, c.width >= minSize, c.height >= minSize {
            model.commit { model.crop = c.integral }
            model.tool = .arrow
            return
        }
        guard let d = draft else { return }
        let b = d.bounds
        let big = if case .arrow = d.kind { b.width > minSize * 4 || b.height > minSize * 4 }
            else { b.width >= minSize && b.height >= minSize }
        if big { model.add(d) }
    }

    private func snap45(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let angle = atan2(b.y - a.y, b.x - a.x)
        let step = CGFloat.pi / 4
        let snapped = (angle / step).rounded() * step
        let len = a.distance(to: b)
        return CGPoint(x: a.x + cos(snapped) * len, y: a.y + sin(snapped) * len)
    }

    // MARK: Text

    private func beginText(at p: CGPoint, initial: String, color: NSColor) {
        let field = NSTextField(string: initial)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.textColor = color
        field.font = .systemFont(ofSize: 18 * model.unit * viewScale, weight: .bold)
        field.delegate = self
        field.wantsLayer = true
        field.layer?.borderWidth = 1
        field.layer?.borderColor = NSColor.controlAccentColor.cgColor
        field.layer?.cornerRadius = 3
        textField = field
        textOrigin = p
        addSubview(field)
        layoutTextField()
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: initial.utf16.count, length: 0)
    }

    private func layoutTextField() {
        guard let field = textField, let origin = textOrigin else { return }
        field.sizeToFit()
        let v = toView(origin)
        // NSTextField draws its text ~2pt inside its frame.
        field.frame = CGRect(x: v.x - 2, y: v.y, width: max(field.frame.width + 12, 40), height: field.frame.height)
    }

    func controlTextDidChange(_ obj: Notification) { layoutTextField() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            commitText()
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            cancelText()
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) { commitText() }

    private func commitText() {
        guard let field = textField, let origin = textOrigin else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let color = field.textColor ?? model.color
        cancelText()
        if !text.isEmpty {
            model.add(Annotation(kind: .text(origin, text), color: color, unit: model.unit))
        }
    }

    private func cancelText() {
        guard let field = textField else { return }
        textField = nil
        textOrigin = nil
        field.delegate = nil
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
    }

    override func layout() {
        super.layout()
        layoutTextField()
    }

    // MARK: Keyboard & responder actions

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.isEmpty, let tool = Tool.forKeyCode(event.keyCode) {
            model.tool = tool
            return
        }
        switch event.keyCode {
        case 51, 117: model.deleteSelected()                      // Backspace, Delete
        case 36, 76: onCopyAndClose?()                            // Return, Enter
        case 53: model.selectedID != nil ? (model.selectedID = nil) : onClose?() // Esc
        case 123, 124, 125, 126: nudge(event.keyCode, big: flags.contains(.shift))
        default: super.keyDown(with: event)
        }
    }

    private func nudge(_ code: UInt16, big: Bool) {
        guard let id = model.selectedID, let i = model.annotations.firstIndex(where: { $0.id == id }) else { return }
        let step = (big ? 10 : 1) * model.scale
        let d: CGVector = switch code {
        case 123: CGVector(dx: -step, dy: 0)
        case 124: CGVector(dx: step, dy: 0)
        case 125: CGVector(dx: 0, dy: step)
        default: CGVector(dx: 0, dy: -step)
        }
        model.commit { model.annotations[i] = model.annotations[i].offset(by: d) }
    }

    @objc func copy(_ sender: Any?) { onCopyAndClose?() }
    @objc func saveDocument(_ sender: Any?) { onSave?() }
    @objc func undo(_ sender: Any?) { model.undo() }
    @objc func redo(_ sender: Any?) { model.redo() }
    @objc func delete(_ sender: Any?) { model.deleteSelected() }
}
