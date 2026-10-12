import AppKit
import ScreenCaptureKit

/// Records a region while the user (or auto-scroll) scrolls it, and stitches the frames.
/// Our border and control panel belong to PSE, which the capture filter excludes, so they never
/// show up in the frames. The panel is non-activating: the scrolled app stays frontmost.
@MainActor
final class ScrollCaptureSession {
    /// Stitched image and the suggested crop (main scrolling column), nil when cancelled.
    var onFinish: ((CGImage?, CGRect?) -> Void)?

    private let displayID: CGDirectDisplayID
    private let displayFrame: CGRect   // global CG coordinates
    private let region: CGRect         // display-local points, top-left origin
    private let scale: CGFloat
    private let screen: NSScreen

    private let stitcher: ScrollStitcher
    private let stitchQueue = DispatchQueue(label: "com.viafirst.pse.stitch", qos: .userInitiated)
    private var border: NSWindow?
    private var panel: ScrollControlPanel?
    private var keyMonitors: [Any] = []

    private var running = false
    private var cancelled = false
    private var autoScroll = false
    private var stillFrames = 0

    init(displayID: CGDirectDisplayID, displayFrame: CGRect, region: CGRect, scale: CGFloat, screen: NSScreen) {
        self.displayID = displayID
        self.displayFrame = displayFrame
        self.region = region
        self.scale = scale
        self.screen = screen
        stitcher = ScrollStitcher(scale: scale)
    }

    /// Region in AppKit screen coordinates (bottom-left origin).
    private var regionOnScreen: CGRect {
        CGRect(x: screen.frame.minX + region.minX, y: screen.frame.maxY - region.maxY,
               width: region.width, height: region.height)
    }

    func start() {
        showChrome()
        running = true
        Task { @MainActor in await run() }
    }

    func finish() {
        running = false
    }

    func cancel() {
        cancelled = true
        running = false
    }

    // MARK: Loop

    private func run() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else { return end(nil) }

            let pid = ProcessInfo.processInfo.processIdentifier
            let filter = SCContentFilter(display: display,
                                         excludingApplications: content.applications.filter { $0.processID == pid },
                                         exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.sourceRect = region
            config.width = Int((region.width * scale).rounded())
            config.height = Int((region.height * scale).rounded())
            config.showsCursor = false
            config.captureResolution = .best

            while running {
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                guard running else { break }
                let result = await stitch(image)
                handle(result)
                if autoScroll {
                    postScroll()
                    try await Task.sleep(nanoseconds: 350_000_000)
                } else {
                    try await Task.sleep(nanoseconds: 80_000_000)
                }
            }
        } catch {
            if !cancelled {
                NSAlert(error: error).runModal()
            }
            cancelled = true
        }
        if cancelled { return end(nil) }
        let stitcher = stitcher
        let (image, columns) = await withCheckedContinuation { cont in
            stitchQueue.async { cont.resume(returning: (stitcher.makeImage(), stitcher.suggestedColumns())) }
        }
        let crop = image.flatMap { img in
            columns.map { CGRect(x: $0.lowerBound, y: 0, width: $0.count, height: img.height) }
        }
        end(image, crop: crop)
    }

    private func stitch(_ image: CGImage) async -> (ScrollStitcher.Result, Int) {
        let stitcher = stitcher
        return await withCheckedContinuation { cont in
            stitchQueue.async { cont.resume(returning: (stitcher.add(image), stitcher.stitchedHeight)) }
        }
    }

    private func handle(_ result: (ScrollStitcher.Result, Int)) {
        let (state, height) = result
        let size = String(format: L("Height: %d px"), height)
        switch state {
        case .first:
            panel?.setStatus(L("Scroll down slowly…"), warning: false)
        case .appended:
            stillFrames = 0
            panel?.setStatus(size, warning: false)
        case .noMotion:
            if autoScroll {
                stillFrames += 1
                if stillFrames >= 3 { finish() } // reached the end of the page
            }
        case .lost:
            panel?.setStatus(L("Too fast: scroll back up a little"), warning: true)
        case .full:
            panel?.setStatus(L("Maximum height reached"), warning: true)
            finish()
        }
    }

    // MARK: Auto-scroll

    func toggleAutoScroll() {
        autoScroll.toggle()
        stillFrames = 0
        panel?.setAutoScroll(autoScroll)
        if autoScroll {
            // Scroll events go to the window under the pointer.
            CGWarpMouseCursorPosition(CGPoint(x: displayFrame.minX + region.midX, y: displayFrame.minY + region.midY))
        }
    }

    private func postScroll() {
        let step = Int32(max(40, region.height * 0.55))
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                  wheel1: -step, wheel2: 0, wheel3: 0) else { return }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.post(tap: .cghidEventTap)
    }

    // MARK: Chrome

    private func showChrome() {
        let frame = regionOnScreen.insetBy(dx: -3, dy: -3)
        let border = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        border.isOpaque = false
        border.backgroundColor = .clear
        border.hasShadow = false
        border.ignoresMouseEvents = true
        border.level = .statusBar
        border.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        border.isReleasedWhenClosed = false
        border.contentView = RegionBorderView()
        border.orderFrontRegardless()
        self.border = border

        let panel = ScrollControlPanel(session: self)
        panel.place(near: regionOnScreen, in: screen.visibleFrame)
        panel.orderFrontRegardless()
        self.panel = panel

        // Esc cancels even though another app is frontmost (needs Accessibility, which the hotkey has).
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            if e.keyCode == 53 { MainActor.assumeIsolated { self?.cancel() } }
        }) { keyMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            guard e.keyCode == 53 else { return e }
            self?.cancel()
            return nil
        }) { keyMonitors.append(local) }
    }

    private func end(_ image: CGImage?, crop: CGRect? = nil) {
        keyMonitors.forEach(NSEvent.removeMonitor)
        keyMonitors.removeAll()
        border?.orderOut(nil)
        panel?.orderOut(nil)
        border = nil
        panel = nil
        onFinish?(image, crop)
        onFinish = nil
    }
}

private final class RegionBorderView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
        path.lineWidth = 2
        path.setLineDash([7, 4], count: 2, phase: 0)
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }
}

/// Floating HUD: status · auto-scroll · done · cancel.
private final class ScrollControlPanel: NSPanel {
    private weak var session: ScrollCaptureSession?
    private let status = NSTextField(labelWithString: "")
    private var autoButton: NSButton!

    init(session: ScrollCaptureSession) {
        self.session = session
        super.init(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: .vibrantDark)
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true

        status.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        status.textColor = .white
        status.lineBreakMode = .byTruncatingTail
        status.widthAnchor.constraint(equalToConstant: 230).isActive = true
        status.stringValue = L("Scroll down slowly…")

        autoButton = button("play.fill", tip: L("Auto-scroll"), #selector(toggleAuto))
        let done = button("checkmark", tip: L("Done (or press the hotkey again)"), #selector(done))
        done.contentTintColor = .systemGreen
        let cancel = button("xmark", tip: L("Cancel (Esc)"), #selector(cancelTapped))

        let stack = NSStackView(views: [status, autoButton, done, cancel])
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 6, right: 6)
        let size = stack.fittingSize
        stack.frame = CGRect(origin: .zero, size: size)
        effect.frame = stack.frame
        effect.addSubview(stack)
        contentView = effect
        setContentSize(size)
    }

    override var canBecomeKey: Bool { true }

    func place(near region: CGRect, in visible: CGRect) {
        let size = frame.size
        var origin = CGPoint(x: region.midX - size.width / 2, y: region.minY - size.height - 12)
        if origin.y < visible.minY {
            origin.y = region.maxY + 12                      // above the region
            if origin.y + size.height > visible.maxY {
                origin.y = region.minY + 12                  // inside, at the bottom
            }
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        setFrameOrigin(origin)
    }

    func setStatus(_ text: String, warning: Bool) {
        status.stringValue = text
        status.textColor = warning ? .systemOrange : .white
    }

    func setAutoScroll(_ on: Bool) {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        autoButton.image = NSImage(systemSymbolName: on ? "stop.fill" : "play.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        autoButton.toolTip = on ? L("Stop auto-scroll") : L("Auto-scroll")
    }

    private func button(_ symbol: String, tip: String, _ action: Selector) -> NSButton {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?.withSymbolConfiguration(config)
        let b = NSButton(image: image ?? NSImage(), target: self, action: action)
        b.isBordered = false
        b.contentTintColor = .white
        b.toolTip = tip
        b.widthAnchor.constraint(equalToConstant: 34).isActive = true
        b.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return b
    }

    @objc private func toggleAuto() { session?.toggleAutoScroll() }
    @objc private func done() { session?.finish() }
    @objc private func cancelTapped() { session?.cancel() }
}
