import AppKit

final class OverlayWindow: NSWindow {
    let overlayView: OverlayView

    init(screen: NSScreen, shot: DisplayShot, windows: [WindowInfo], controller: CaptureController, showToolbar: Bool) {
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
    /// Windows in local coordinates, front to back.
    private let windows: [(rect: CGRect, info: WindowInfo)]
    private var toolbar: OverlayToolbar?

    private var dragStart: CGPoint?
    private var selection: CGRect?
    private var hovered: (rect: CGRect, info: WindowInfo)?
    private var mouse: CGPoint?

    var hasToolbar: Bool { toolbar != nil }
    private var mode: CaptureMode { controller?.mode ?? .area }
    /// Modes where clicking picks a window.
    private var picksWindows: Bool { mode != .area }

    init(shot: DisplayShot, windows: [WindowInfo], controller: CaptureController, showToolbar: Bool) {
        self.shot = shot
        self.controller = controller
        image = NSImage(cgImage: shot.image, size: shot.frame.size)
        let bounds = CGRect(origin: .zero, size: shot.frame.size)
        self.windows = windows.compactMap { w in
            let local = w.frame.offsetBy(dx: -shot.frame.minX, dy: -shot.frame.minY).intersection(bounds)
            return local.isNull || local.width < 20 || local.height < 20 ? nil : (local, w)
        }
        super.init(frame: bounds)

        if showToolbar {
            let bar = OverlayToolbar(controller: controller)
            addSubview(bar)
            toolbar = bar
            layoutToolbar()
        }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))

        // Start with the pointer's current position, so the crosshair and loupe show right away.
        let global = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let local = CGPoint(x: global.x - shot.frame.minX, y: primaryHeight - global.y - shot.frame.minY)
        if bounds.contains(local) { mouse = local }
    }

    /// Self-test hook: put the pointer somewhere without a real mouse event.
    func debugMovePointer(to p: CGPoint) {
        mouse = p
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    private func layoutToolbar() {
        guard let bar = toolbar else { return }
        bar.setFrameOrigin(CGPoint(x: (bounds.width - bar.frame.width) / 2, y: 54))
    }

    func modeDidChange() {
        selection = nil
        hovered = picksWindows ? mouse.flatMap(windowAt) : nil
        toolbar?.refresh()
        layoutToolbar()
        needsDisplay = true
    }

    private func windowAt(_ p: CGPoint) -> (rect: CGRect, info: WindowInfo)? {
        windows.first { $0.rect.contains(p) }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill(using: .sourceOver)

        if let r = selection {
            reveal(r)
            NSColor.white.setStroke()
            let path = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5))
            path.lineWidth = 1
            path.stroke()
            drawLabel(sizeText(r), for: r)
        } else if picksWindows, let w = hovered {
            reveal(w.rect)
            NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
            w.rect.fill(using: .sourceOver)
            NSColor.controlAccentColor.setStroke()
            let path = NSBezierPath(rect: w.rect.insetBy(dx: 1.5, dy: 1.5))
            path.lineWidth = 3
            path.stroke()
            drawLabel(mode == .webPage ? webLabel(for: w.rect) : sizeText(w.rect), for: w.rect)
        } else if mode != .window, mode != .webPage, dragStart == nil, let m = mouse {
            drawCrosshair(at: m)
        }

        if mode == .area || mode == .scroll, let m = mouse, toolbar.map({ $0.isHidden || !$0.frame.contains(m) }) ?? true {
            drawLoupe(at: m)
        }
    }

    // MARK: Loupe

    private static let loupePixels = 15        // odd: the centre pixel is the one under the pointer
    private static let loupeCell: CGFloat = 8  // points per magnified pixel

    /// Magnified pixels around the pointer, with a grid, the centre pixel marked, and its
    /// position and colour underneath. Sits below-right of the pointer, flipping at screen edges.
    private func drawLoupe(at p: CGPoint) {
        let n = Self.loupePixels, cell = Self.loupeCell
        let side = CGFloat(n) * cell
        let s = shot.scale
        let cx = Int(p.x * s), cy = Int(p.y * s)

        var box = CGRect(x: p.x + 24, y: p.y + 24, width: side, height: side)
        if box.maxX > bounds.maxX - 8 { box.origin.x = p.x - 24 - side }
        if box.maxY + 30 > bounds.maxY - 8 { box.origin.y = p.y - 24 - side - 30 }

        let shape = NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        NSColor.black.setFill()
        box.fill()

        let wanted = CGRect(x: cx - n / 2, y: cy - n / 2, width: n, height: n)
        let available = wanted.intersection(CGRect(x: 0, y: 0, width: shot.image.width, height: shot.image.height))
        if !available.isNull, let pixels = shot.image.cropping(to: available) {
            let dest = CGRect(x: box.minX + (available.minX - wanted.minX) * cell,
                              y: box.minY + (available.minY - wanted.minY) * cell,
                              width: available.width * cell, height: available.height * cell)
            NSGraphicsContext.current?.imageInterpolation = .none
            NSImage(cgImage: pixels, size: available.size)
                .draw(in: dest, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        }

        let grid = NSBezierPath()
        for i in 1..<n {
            let o = CGFloat(i) * cell
            grid.move(to: CGPoint(x: box.minX + o, y: box.minY))
            grid.line(to: CGPoint(x: box.minX + o, y: box.maxY))
            grid.move(to: CGPoint(x: box.minX, y: box.minY + o))
            grid.line(to: CGPoint(x: box.maxX, y: box.minY + o))
        }
        grid.lineWidth = 0.5
        NSColor.gray.withAlphaComponent(0.3).setStroke() // visible on both light and dark content
        grid.stroke()

        let centre = CGRect(x: box.minX + CGFloat(n / 2) * cell, y: box.minY + CGFloat(n / 2) * cell,
                            width: cell, height: cell)
        NSColor.black.setStroke()
        NSBezierPath(rect: centre.insetBy(dx: -1, dy: -1)).stroke()
        NSColor.white.setStroke()
        NSBezierPath(rect: centre).stroke()
        NSGraphicsContext.restoreGraphicsState()

        NSColor.white.withAlphaComponent(0.9).setStroke()
        shape.lineWidth = 2
        shape.stroke()

        // Position (points) and colour of the centre pixel.
        let hex = pixelHex(x: cx, y: cy) ?? "—"
        let text = "\(Int(p.x)), \(Int(p.y))   \(hex)   C ⧉" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attrs)
        let label = CGRect(x: box.midX - (size.width + 12) / 2, y: box.maxY + 6, width: size.width + 12, height: size.height + 6)
        NSColor.black.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: label, xRadius: 5, yRadius: 5).fill()
        text.draw(at: CGPoint(x: label.minX + 6, y: label.minY + 3), withAttributes: attrs)
    }

    /// sRGB hex of one pixel of the frozen shot.
    private func pixelHex(x: Int, y: Int) -> String? {
        guard x >= 0, y >= 0, x < shot.image.width, y < shot.image.height,
              let one = shot.image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return nil }
        var rgba = [UInt8](repeating: 0, count: 4)
        let ok = rgba.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(one, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        return ok ? String(format: "#%02X%02X%02X", rgba[0], rgba[1], rgba[2]) : nil
    }

    private func reveal(_ r: CGRect) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: r).addClip()
        image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func sizeText(_ r: CGRect) -> String {
        "\(Int(r.width.rounded())) × \(Int(r.height.rounded()))"
    }

    private func webLabel(for r: CGRect) -> String {
        let width = Int(PageWidth.current.points(windowWidth: r.width))
        return String(format: L("Full page · %d pt wide"), width)
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

    private func drawLabel(_ string: String, for r: CGRect) {
        let text = string as NSString
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
        if picksWindows { hovered = windowAt(p) }
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
            if let w = windowAt(p) { controller?.finish(self, rect: w.rect) }
        case .webPage:
            if let w = windowAt(p) { controller?.captureWebPage(self, window: w.info, localRect: w.rect) }
        case .area, .scroll:
            // In scroll mode a plain click picks the window under the pointer, a drag an area.
            dragStart = p
            selection = nil
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode == .area || mode == .scroll, let start = dragStart else { return }
        var p = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.shift) {
            let side = max(abs(p.x - start.x), abs(p.y - start.y))
            p = CGPoint(x: start.x + (p.x < start.x ? -side : side), y: start.y + (p.y < start.y ? -side : side))
        }
        mouse = p
        toolbar?.isHidden = true
        selection = CGRect(from: start, to: p).intersection(bounds)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard mode == .area || mode == .scroll, let start = dragStart else { return }
        dragStart = nil
        toolbar?.isHidden = false
        let dragged = selection.map { $0.width >= 3 && $0.height >= 3 } ?? false
        switch mode {
        case .scroll where dragged:
            if let r = selection, r.width >= 40, r.height >= 40 { return controller?.beginScroll(self, rect: r) ?? () }
        case .scroll:
            if let w = windowAt(start) { return controller?.beginScroll(self, rect: w.rect) ?? () }
        case .area where dragged:
            if let r = selection { return controller?.finish(self, rect: r) ?? () }
        default:
            break
        }
        selection = nil
        needsDisplay = true
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
        case 35: controller?.setMode(.webPage)              // P
        case 49: controller?.setMode(mode == .area ? .window : .area) // Space
        case 3: controller?.finish(self, rect: bounds)      // F
        case 8 where mode == .area || mode == .scroll:      // C: eyedropper
            if let m = mouse, let hex = pixelHex(x: Int(m.x * shot.scale), y: Int(m.y * shot.scale)) {
                controller?.pickColor(hex, screen: window?.screen)
            }
        case 18 where mode == .webPage: controller?.setPageWidth(.window)   // 1
        case 19 where mode == .webPage: controller?.setPageWidth(.desktop)  // 2
        case 20 where mode == .webPage: controller?.setPageWidth(.mobile)   // 3
        default: super.keyDown(with: event)
        }
    }
}

/// Icon-only HUD: area / window / scrolling / web page / full screen, page widths (web mode), close.
final class OverlayToolbar: NSVisualEffectView {
    private weak var controller: CaptureController?
    private var modeButtons: [(CaptureMode, NSButton)] = []
    private var widthButtons: [(PageWidth, NSButton)] = []
    private var widthGroup: [NSView] = []
    private let stack = NSStackView()

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
        let web = button("globe", tip: L("Full Web Page (P)"), #selector(pickWeb))
        let full = button("display", tip: L("Full Screen (F)"), #selector(pickFull))
        let close = button("xmark", tip: L("Cancel (Esc)"), #selector(cancel))
        modeButtons = [(.area, area), (.window, window), (.scroll, scroll), (.webPage, web)]

        let asWindow = button("rectangle", tip: L("Page width: as the window (1)"), #selector(widthWindow))
        let desktop = button("desktopcomputer", tip: L("Page width: desktop 1440 (2)"), #selector(widthDesktop))
        let mobile = button("iphone", tip: L("Page width: mobile 390 (3)"), #selector(widthMobile))
        widthButtons = [(.window, asWindow), (.desktop, desktop), (.mobile, mobile)]
        let widthDivider = divider()
        widthGroup = [widthDivider, asWindow, desktop, mobile]

        for v in [area, window, scroll, web, full, widthDivider, asWindow, desktop, mobile, divider(), close] {
            stack.addArrangedSubview(v)
        }
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        addSubview(stack)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    func refresh() {
        let mode = controller?.mode
        for (m, b) in modeButtons { highlight(b, m == mode) }
        for (w, b) in widthButtons { highlight(b, w == PageWidth.current) }
        widthGroup.forEach { $0.isHidden = mode != .webPage }
        let size = stack.fittingSize
        stack.frame = CGRect(origin: .zero, size: size)
        setFrameSize(size)
    }

    private func highlight(_ b: NSButton, _ on: Bool) {
        b.layer?.backgroundColor = on ? NSColor.white.withAlphaComponent(0.22).cgColor : NSColor.clear.cgColor
    }

    private func divider() -> NSView {
        let d = NSBox()
        d.boxType = .separator
        d.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return d
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
    @objc private func pickWeb() { controller?.setMode(.webPage) }
    @objc private func widthWindow() { controller?.setPageWidth(.window) }
    @objc private func widthDesktop() { controller?.setPageWidth(.desktop) }
    @objc private func widthMobile() { controller?.setPageWidth(.mobile) }
    @objc private func cancel() { controller?.cancel() }
    @objc private func pickFull() {
        guard let view = superview as? OverlayView else { return }
        controller?.finish(view, rect: view.bounds)
    }
}
