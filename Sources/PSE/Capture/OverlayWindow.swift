import AppKit

final class OverlayWindow: NSWindow {
    let overlayView: OverlayView

    init(screen: NSScreen, shot: DisplayShot, windows: [CGRect], controller: CaptureController, showToolbar: Bool) {
        overlayView = OverlayView(shot: shot, windows: windows, controller: controller, showToolbar: showToolbar)
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = overlayView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Shows the frozen screen dimmed; the user drags an area or clicks a window.
/// Flipped, so local coordinates match the CG (top-left) display coordinates of the shot.
final class OverlayView: NSView {
    let shot: DisplayShot
    private weak var controller: CaptureController?
    private let image: NSImage
    private let windowRects: [CGRect]
    private var toolbar: OverlayToolbar?

    private var dragStart: CGPoint?
    private var selection: CGRect?
    private var hoveredWindow: CGRect?
    private var mouse: CGPoint?

    var hasToolbar: Bool { toolbar != nil }
    private var mode: CaptureMode { controller?.mode ?? .area }

    init(shot: DisplayShot, windows: [CGRect], controller: CaptureController, showToolbar: Bool) {
        self.shot = shot
        self.controller = controller
        image = NSImage(cgImage: shot.image, size: shot.frame.size)
        let bounds = CGRect(origin: .zero, size: shot.frame.size)
        windowRects = windows.compactMap { r in
            let local = r.offsetBy(dx: -shot.frame.minX, dy: -shot.frame.minY).intersection(bounds)
            return local.isNull || local.width < 20 || local.height < 20 ? nil : local
        }
        super.init(frame: bounds)

        if showToolbar {
            let bar = OverlayToolbar(controller: controller)
            bar.setFrameOrigin(CGPoint(x: (bounds.width - bar.frame.width) / 2, y: 54))
            addSubview(bar)
            toolbar = bar
        }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    func modeDidChange() {
        selection = nil
        hoveredWindow = mode == .window ? mouse.flatMap(windowAt) : nil
        toolbar?.refresh()
        needsDisplay = true
    }

    private func windowAt(_ p: CGPoint) -> CGRect? {
        windowRects.first { $0.contains(p) }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill(using: .sourceOver)

        let focus = mode == .window ? hoveredWindow : selection
        guard let r = focus else {
            if mode != .window, dragStart == nil, let m = mouse { drawCrosshair(at: m) }
            return
        }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: r).addClip()
        image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()

        if mode == .window {
            NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
            r.fill(using: .sourceOver)
            NSColor.controlAccentColor.setStroke()
            let path = NSBezierPath(rect: r.insetBy(dx: 1.5, dy: 1.5))
            path.lineWidth = 3
            path.stroke()
        } else {
            NSColor.white.setStroke()
            let path = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5))
            path.lineWidth = 1
            path.stroke()
        }
        drawSizeLabel(for: r)
    }

    private func drawCrosshair(at p: CGPoint) {
        NSColor.white.withAlphaComponent(0.45).setStroke()
        let path = NSBezierPath()
        path.move(to: CGPoint(x: bounds.minX, y: p.y + 0.5))
        path.line(to: CGPoint(x: bounds.maxX, y: p.y + 0.5))
        path.move(to: CGPoint(x: p.x + 0.5, y: bounds.minY))
        path.line(to: CGPoint(x: p.x + 0.5, y: bounds.maxY))
        path.lineWidth = 1
        path.stroke()
    }

    private func drawSizeLabel(for r: CGRect) {
        let text = "\(Int(r.width.rounded())) × \(Int(r.height.rounded()))" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attrs)
        var box = CGRect(x: r.minX, y: r.maxY + 6, width: size.width + 12, height: size.height + 6)
        if box.maxY > bounds.maxY { box.origin.y = r.maxY - box.height - 6; box.origin.x += 6 }
        box.origin.x = min(box.origin.x, bounds.maxX - box.width - 4)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        text.draw(at: CGPoint(x: box.minX + 6, y: box.minY + 3), withAttributes: attrs)
    }

    // MARK: Mouse

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        mouse = p
        if mode == .window { hoveredWindow = windowAt(p) }
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        mouse = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch mode {
        case .window:
            if let r = windowAt(p) { controller?.finish(self, rect: r) }
        case .area, .scroll:
            dragStart = p
            selection = nil
            toolbar?.isHidden = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode != .window, let start = dragStart else { return }
        var p = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.shift) {
            let side = max(abs(p.x - start.x), abs(p.y - start.y))
            p = CGPoint(x: start.x + (p.x < start.x ? -side : side), y: start.y + (p.y < start.y ? -side : side))
        }
        mouse = p
        selection = CGRect(from: start, to: p).intersection(bounds)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard mode != .window, dragStart != nil else { return }
        dragStart = nil
        toolbar?.isHidden = false
        if mode == .scroll, let r = selection, r.width >= 40, r.height >= 40 {
            controller?.beginScroll(self, rect: r)
        } else if mode == .area, let r = selection, r.width >= 3, r.height >= 3 {
            controller?.finish(self, rect: r)
        } else {
            selection = nil
            needsDisplay = true
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        controller?.cancel()
    }

    // Key codes, not characters: works with any keyboard layout (e.g. Russian).
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: controller?.cancel()                       // Esc
        case 0: controller?.setMode(.area)                  // A
        case 13: controller?.setMode(.window)               // W
        case 1: controller?.setMode(.scroll)                // S
        case 49: controller?.setMode(mode == .area ? .window : .area) // Space
        case 3: controller?.finish(self, rect: bounds)      // F
        default: super.keyDown(with: event)
        }
    }
}

/// Icon-only HUD: area / window / full screen / close.
final class OverlayToolbar: NSVisualEffectView {
    private weak var controller: CaptureController?
    private var modeButtons: [(CaptureMode, NSButton)] = []

    init(controller: CaptureController) {
        self.controller = controller
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        appearance = NSAppearance(named: .vibrantDark)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true

        let area = button("rectangle.dashed", tip: L("Area (A)"), #selector(pickArea))
        let window = button("macwindow", tip: L("Window (W)"), #selector(pickWindow))
        let scroll = button("scroll", tip: L("Scrolling Capture (S)"), #selector(pickScroll))
        let full = button("display", tip: L("Full Screen (F)"), #selector(pickFull))
        let close = button("xmark", tip: L("Cancel (Esc)"), #selector(cancel))
        modeButtons = [(.area, area), (.window, window), (.scroll, scroll)]

        let divider = NSBox()
        divider.boxType = .separator
        divider.heightAnchor.constraint(equalToConstant: 22).isActive = true

        let stack = NSStackView(views: [area, window, scroll, full, divider, close])
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        let size = stack.fittingSize
        stack.frame = CGRect(origin: .zero, size: size)
        addSubview(stack)
        setFrameSize(size)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    func refresh() {
        for (mode, button) in modeButtons {
            button.layer?.backgroundColor = mode == controller?.mode
                ? NSColor.white.withAlphaComponent(0.22).cgColor : NSColor.clear.cgColor
        }
    }

    private func button(_ symbol: String, tip: String, _ action: Selector) -> NSButton {
        let config = NSImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?.withSymbolConfiguration(config)
        let b = NSButton(image: image ?? NSImage(), target: self, action: action)
        b.isBordered = false
        b.contentTintColor = .white
        b.toolTip = tip
        b.wantsLayer = true
        b.layer?.cornerRadius = 7
        b.widthAnchor.constraint(equalToConstant: 40).isActive = true
        b.heightAnchor.constraint(equalToConstant: 34).isActive = true
        return b
    }

    @objc private func pickArea() { controller?.setMode(.area) }
    @objc private func pickWindow() { controller?.setMode(.window) }
    @objc private func pickScroll() { controller?.setMode(.scroll) }
    @objc private func cancel() { controller?.cancel() }
    @objc private func pickFull() {
        guard let view = superview as? OverlayView else { return }
        controller?.finish(view, rect: view.bounds)
    }
}
