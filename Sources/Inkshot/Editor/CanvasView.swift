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
    private var penPoints: [CGPoint] = []

    private var textField: NSTextField?
    private var textOrigin: CGPoint?      // image px
    /// The text annotation being edited in place (hidden while its live draft is shown).
    private var editingID: UUID?
    private var textColor: NSColor = .white
    private var textUnit: CGFloat = 1
    /// Colour/size when typing started: a change from the toolbar restyles the text being typed.
    private var textStyleBaseline: (NSColor, StrokeSize)?

    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero)
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                (self.enclosingScrollView as? EditorScrollView)?.updateDocumentSize()
                if self.textField != nil, let (color, size) = self.textStyleBaseline,
                   color != self.model.color || size != self.model.size {
                    self.textColor = self.model.color
                    self.textUnit = self.model.unit
                    self.textStyleBaseline = (self.model.color, self.model.size)
                    self.styleFieldEditor()
                    self.layoutTextField()
                }
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

    /// Height needed to show the crop at fit-width (never upscaled); tall captures scroll.
    func preferredHeight(forWidth width: CGFloat) -> CGFloat {
        let c = model.crop
        let s = min((width - 32) / c.width, 1 / model.scale)
        return c.height * s + 32
    }

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
        var list = model.annotations.filter { $0.id != editingID }
        if let textDraft { list.append(textDraft) }
        if let draft { list.append(draft) }

        ctx.saveGState()
        ctx.clip(to: d)
        ctx.interpolationQuality = .high
        ctx.translateBy(x: d.minX, y: d.minY)
        ctx.scaleBy(x: s, y: s)
        ctx.translateBy(x: -model.crop.minX, y: -model.crop.minY)
        SceneRenderer.draw(base: model.base, pixelated: model.pixelated, annotations: list, deviceScale: s * backing,
                           isDark: model.isDark)
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

        // A click outside the text being typed finishes it; the same click then acts normally
        // (e.g. starts the next text right away).
        if textField != nil { commitText() }

        let hit = model.annotations.last(where: { $0.hitTest(p) })
        if let hit, event.clickCount == 2, hit.isText, model.tool != .pen {
            return beginText(editing: hit)
        }
        if let hit, canGrab(hit) {
            model.selectedID = hit.id
            model.beginLiveChange()
            moveLast = p
            moved = false
            return
        }

        switch model.tool {
        case .select:
            model.selectedID = nil
        case .number:
            model.add(Annotation(kind: .number(p, model.nextNumber), color: model.color, unit: model.unit))
        case .question:
            model.add(Annotation(kind: .question(p), color: model.color, unit: model.unit))
        case .pen:
            dragStart = p
            penPoints = [p]
            draft = Annotation(kind: .pen(penPoints), color: model.color, unit: model.unit)
            needsDisplay = true
        case .text:
            model.selectedID = nil
            beginText(at: p)
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
        case .pen:
            // Skip points closer than ~1 pt: smoother line, fewer points to store.
            if let last = penPoints.last, last.distance(to: p) < model.unit { return }
            penPoints.append(p)
            kind = .pen(penPoints)
        case .cross:
            if shift {
                let side = max(abs(p.x - start.x), abs(p.y - start.y))
                p = CGPoint(x: start.x + (p.x < start.x ? -side : side), y: start.y + (p.y < start.y ? -side : side))
            }
            kind = .cross(CGRect(from: start, to: p))
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
        if model.tool == .pen, let d = draft {
            penPoints = []
            return model.add(d) // a click leaves a dot
        }
        if model.tool == .cross, let start = dragStart, (draft.map { $0.bounds.width < minSize && $0.bounds.height < minSize } ?? true) {
            // A click: an X of the default size, centred on the click.
            let half = 12 * model.unit * 1.1
            return model.add(Annotation(kind: .cross(CGRect(x: start.x - half, y: start.y - half, width: half * 2, height: half * 2)),
                                        color: model.color, unit: model.unit))
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

    // MARK: Grabbing marks

    /// Whether a click on `a` grabs it (select + drag) instead of drawing something new.
    /// Texts can be grabbed with any tool except the pen and crop; with Select and Text tools
    /// every mark can.
    private func canGrab(_ a: Annotation) -> Bool {
        switch model.tool {
        case .select, .text: true
        case .pen, .crop: false
        default: a.isText
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .cursorUpdate],
                                       owner: self, userInfo: nil))
    }

    // An open hand over a mark that a click would grab.
    override func mouseMoved(with event: NSEvent) {
        let p = toImage(convert(event.locationInWindow, from: nil))
        if model.tool != .select, let hit = model.annotations.last(where: { $0.hitTest(p) }), canGrab(hit) {
            NSCursor.openHand.set()
        } else {
            window?.invalidateCursorRects(for: self)
            cursorForTool.set()
        }
    }

    private var cursorForTool: NSCursor {
        switch model.tool {
        case .select: .arrow
        case .text: .iBeam
        default: .crosshair
        }
    }

    // MARK: Text

    /// The text being typed, drawn by the canvas exactly like the final mark (outline included);
    /// the NSTextField on top is invisible apart from its caret and selection.
    private var textDraft: Annotation? {
        guard let field = textField, let origin = textOrigin, !field.stringValue.isEmpty else { return nil }
        var a = Annotation(kind: .text(origin, field.stringValue), color: textColor, unit: textUnit)
        if let editingID { a.id = editingID }
        return a
    }

    private func beginText(at p: CGPoint) {
        startTextField(origin: p, initial: "", color: model.color, unit: model.unit, editing: nil)
    }

    private func beginText(editing a: Annotation) {
        guard case let .text(origin, string) = a.kind else { return }
        model.selectedID = nil
        startTextField(origin: origin, initial: string, color: a.color, unit: a.unit, editing: a.id)
    }

    private func startTextField(origin: CGPoint, initial: String, color: NSColor, unit: CGFloat, editing: UUID?) {
        let field = NSTextField(string: initial)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.textColor = .clear
        field.usesSingleLineMode = false
        field.cell?.wraps = false
        field.cell?.isScrollable = false
        field.maximumNumberOfLines = 0
        field.delegate = self
        textField = field
        textOrigin = origin
        textColor = color
        textUnit = unit
        editingID = editing
        textStyleBaseline = (model.color, model.size)
        addSubview(field)
        layoutTextField()
        window?.makeFirstResponder(field)
        styleFieldEditor()
        (field.currentEditor() as? NSTextView)?.selectedRange = NSRange(location: initial.utf16.count, length: 0)
        needsDisplay = true
    }

    /// The field editor draws its own text in the control text colour; make it invisible so only the
    /// canvas' live draft shows, keep a caret in the mark's colour and a faint selection.
    private func styleFieldEditor() {
        guard let editor = textField?.currentEditor() as? NSTextView else { return }
        editor.textColor = .clear
        editor.typingAttributes[.foregroundColor] = NSColor.clear
        editor.insertionPointColor = textColor.isLight ? .white : textColor
        editor.selectedTextAttributes = [.backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.3)]
    }

    private func layoutTextField() {
        guard let field = textField, let origin = textOrigin else { return }
        let fontSize = 18 * textUnit
        field.font = .systemFont(ofSize: fontSize * viewScale, weight: .bold)
        let text = field.stringValue.isEmpty ? " " : field.stringValue
        let size = (text as NSString).size(withAttributes: [.font: field.font!])
        let v = toView(origin)
        // NSTextField draws its text ~2 pt inside its frame; keep the caret on the rendered glyphs.
        field.frame = CGRect(x: v.x - 2, y: v.y, width: max(size.width + 16, 40), height: size.height + 2)
    }

    func controlTextDidChange(_ obj: Notification) {
        styleFieldEditor()
        layoutTextField()
        needsDisplay = true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        let newLine = selector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))
            || (selector == #selector(NSResponder.insertNewline(_:)) && NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
        if newLine {
            textView.insertText("\n", replacementRange: textView.selectedRange())
            return true
        }
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
        let editing = editingID, color = textColor, unit = textUnit
        cancelText()
        if let editing, let i = model.annotations.firstIndex(where: { $0.id == editing }) {
            // One undo step: change the text in place, or remove it when emptied.
            if text.isEmpty {
                model.commit { model.annotations.remove(at: i) }
            } else {
                model.commit { model.annotations[i].kind = .text(origin, text) }
                model.selectedID = editing
            }
        } else if !text.isEmpty {
            let a = Annotation(kind: .text(origin, text), color: color, unit: unit)
            model.add(a)
            model.selectedID = a.id
        }
    }

    private func cancelText() {
        guard let field = textField else { return }
        textField = nil
        textOrigin = nil
        editingID = nil
        textStyleBaseline = nil
        field.delegate = nil
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
        needsDisplay = true
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

/// Scrolls the canvas vertically when the image is taller than the window (scrolling captures).
final class EditorScrollView: NSScrollView {
    private let canvas: CanvasView

    init(canvas: CanvasView) {
        self.canvas = canvas
        super.init(frame: .zero)
        documentView = canvas
        hasVerticalScroller = true
        autohidesScrollers = true
        borderType = .noBorder
        backgroundColor = NSColor.windowBackgroundColor.blended(withFraction: 0.35, of: .black) ?? .darkGray
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        updateDocumentSize()
    }

    func updateDocumentSize() {
        let width = contentSize.width
        let size = CGSize(width: width, height: max(contentSize.height, canvas.preferredHeight(forWidth: width)))
        if canvas.frame.size != size { canvas.setFrameSize(size) }
    }
}

// MARK: Self-test hooks

extension CanvasView {
    var debugIsEditingText: Bool { textField != nil }

    /// Types into the text being edited, like the keyboard would.
    func debugType(_ text: String) {
        guard let field = textField else { return }
        if let editor = field.currentEditor() as? NSTextView {
            editor.string = text // like keystrokes: caret at the end, nothing selected
            editor.selectedRange = NSRange(location: text.utf16.count, length: 0)
        } else {
            field.stringValue = text
        }
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    }

    func debugCommitText() { commitText() }

    /// View point (canvas coordinates) of an image point.
    func debugViewPoint(_ p: CGPoint) -> CGPoint {
        let d = displayRect, s = viewScale
        return CGPoint(x: (p.x - model.crop.minX) * s + d.minX, y: (p.y - model.crop.minY) * s + d.minY)
    }
}

