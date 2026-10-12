import AppKit

enum CaptureMode {
    case area, window, scroll, webPage
}

/// Freezes all displays, shows an overlay per screen and hands the chosen region to the editor.
@MainActor
final class CaptureController {
    /// Image, its scale, the screen it came from, and an optional suggested crop (scrolling captures).
    var onCaptured: ((CGImage, CGFloat, NSScreen?, CGRect?) -> Void)?
    var onCancel: (() -> Void)?

    private(set) var mode: CaptureMode = .area
    private var overlays: [OverlayWindow] = []
    private var busy = false
    private var scrollSession: ScrollCaptureSession?
    private var previousApp: NSRunningApplication?
    private var webTask: Task<Void, Never>?

    func start(fullScreen: Bool = false) {
        // The hotkey during a scrolling capture means "done".
        if let scrollSession { return scrollSession.finish() }
        guard !busy, Permissions.ensureScreenCapture() else { return }
        busy = true
        previousApp = NSWorkspace.shared.frontmostApplication
        Task { @MainActor in
            do {
                let shots = try await ScreenGrabber.captureAllDisplays()
                let windows = WindowList.frontToBack()
                let mouseScreen = NSScreen.underMouse
                if fullScreen {
                    busy = false
                    if let shot = shots.first(where: { $0.displayID == mouseScreen?.displayID }) ?? shots.first {
                        onCaptured?(shot.image, shot.scale, mouseScreen, nil)
                    }
                } else {
                    present(shots: shots, windows: windows, mouseScreen: mouseScreen)
                }
            } catch {
                busy = false
                NSApp.activate(ignoringOtherApps: true)
                NSAlert(error: error).runModal()
            }
        }
    }

    func setMode(_ mode: CaptureMode) {
        self.mode = mode
        overlays.forEach { $0.overlayView.modeDidChange() }
    }

    func setPageWidth(_ width: PageWidth) {
        PageWidth.current = width
        overlays.forEach { $0.overlayView.modeDidChange() }
    }

    func finish(_ view: OverlayView, rect: CGRect) {
        let s = view.shot.scale
        let pixels = CGRect(x: rect.minX * s, y: rect.minY * s, width: rect.width * s, height: rect.height * s).integral
        let screen = view.window?.screen
        guard let image = view.shot.image.cropping(to: pixels) else { return cancel() }
        close()
        onCaptured?(image, s, screen, nil)
    }

    func cancel() {
        close()
        onCancel?()
    }

    /// Eyedropper: copies the colour under the pointer as #RRGGBB text.
    func pickColor(_ hex: String, screen: NSScreen?) {
        close()
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(hex, forType: .string)
        Toast.show(String(format: L("%@ copied"), hex), swatch: NSColor(hex: hex), on: screen)
        onCancel?()
    }

    /// Browser window picked in web-page mode: read the tab's address and render the whole page.
    func captureWebPage(_ view: OverlayView, window: WindowInfo, localRect: CGRect) {
        let screen = view.window?.screen
        let scale = view.shot.scale
        close()
        guard let app = NSRunningApplication(processIdentifier: window.pid) else { return cancel() }
        busy = true

        let url: URL
        do {
            url = try BrowserURL.frontTabURL(of: app)
        } catch {
            busy = false
            showError(error, automation: (error as? BrowserURL.Failure).map {
                if case .notAllowed = $0 { return true } else { return false }
            } ?? false)
            onCancel?()
            return
        }

        let width = PageWidth.current
        let viewport: CGFloat = switch width {
        case .window: max(500, window.frame.height - 90) // minus the browser's tab bar and toolbar
        case .desktop: 900
        case .mobile: 844
        }
        let renderer = WebPageRenderer(width: width.points(windowWidth: window.frame.width),
                                       viewportHeight: viewport, mobile: width == .mobile)
        let hud = ProgressHUD(text: String(format: L("Capturing %@…"), url.host ?? url.absoluteString),
                              onCancel: { renderer.cancel() })
        hud.show(on: screen)

        webTask = Task { @MainActor in
            defer {
                hud.close()
                busy = false
                webTask = nil
            }
            do {
                let (image, imageScale) = try await renderer.render(url, scale: scale)
                onCaptured?(image, imageScale, screen, nil)
            } catch is CancellationError {
                onCancel?()
            } catch {
                showError(error, automation: false)
                onCancel?()
            }
        }
    }

    private func showError(_ error: Error, automation: Bool) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("Full-page capture failed")
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: L("OK"))
        if automation { alert.addButton(withTitle: L("Open Settings")) }
        if alert.runModal() == .alertSecondButtonReturn { Permissions.openSettings(.automation) }
    }

    /// Window or area picked in scroll mode: hand focus back to the app being captured and
    /// start recording with auto-scroll on (the panel can pause it for manual scrolling).
    func beginScroll(_ view: OverlayView, rect: CGRect) {
        guard let screen = view.window?.screen else { return cancel() }
        let shot = view.shot
        close()
        busy = true
        if let previousApp, previousApp != NSRunningApplication.current { previousApp.activate() }

        let session = ScrollCaptureSession(displayID: shot.displayID, displayFrame: shot.frame,
                                           region: rect, scale: shot.scale, screen: screen)
        session.onFinish = { [weak self] image, crop in
            guard let self else { return }
            self.scrollSession = nil
            self.busy = false
            if let image {
                self.onCaptured?(image, shot.scale, screen, crop)
            } else {
                self.onCancel?()
            }
        }
        scrollSession = session
        session.start(autoScroll: true)
    }

    private func present(shots: [DisplayShot], windows: [WindowInfo], mouseScreen: NSScreen?) {
        mode = .area
        for screen in NSScreen.screens {
            guard let shot = shots.first(where: { $0.displayID == screen.displayID }) else { continue }
            overlays.append(OverlayWindow(screen: screen, shot: shot, windows: windows,
                                          controller: self, showToolbar: screen == mouseScreen))
        }
        guard !overlays.isEmpty else { busy = false; return }
        NSApp.activate(ignoringOtherApps: true)
        overlays.forEach { $0.orderFrontRegardless() }
        let key = overlays.first { $0.overlayView.hasToolbar } ?? overlays[0]
        key.makeKeyAndOrderFront(nil)
        key.makeFirstResponder(key.overlayView)
    }

    private func close() {
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
        busy = false
    }
}
