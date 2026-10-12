import AppKit

enum CaptureMode {
    case area, window
}

/// Freezes all displays, shows an overlay per screen and hands the chosen region to the editor.
@MainActor
final class CaptureController {
    var onCaptured: ((CGImage, CGFloat, NSScreen?) -> Void)?
    var onCancel: (() -> Void)?

    private(set) var mode: CaptureMode = .area
    private var overlays: [OverlayWindow] = []
    private var busy = false

    func start(fullScreen: Bool = false) {
        guard !busy, Permissions.ensureScreenCapture() else { return }
        busy = true
        Task { @MainActor in
            do {
                let shots = try await ScreenGrabber.captureAllDisplays()
                let windows = WindowList.frontToBack()
                let mouseScreen = NSScreen.underMouse
                if fullScreen {
                    busy = false
                    if let shot = shots.first(where: { $0.displayID == mouseScreen?.displayID }) ?? shots.first {
                        onCaptured?(shot.image, shot.scale, mouseScreen)
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

    func finish(_ view: OverlayView, rect: CGRect) {
        let s = view.shot.scale
        let pixels = CGRect(x: rect.minX * s, y: rect.minY * s, width: rect.width * s, height: rect.height * s).integral
        let screen = view.window?.screen
        guard let image = view.shot.image.cropping(to: pixels) else { return cancel() }
        close()
        onCaptured?(image, s, screen)
    }

    func cancel() {
        close()
        onCancel?()
    }

    private func present(shots: [DisplayShot], windows: [CGRect], mouseScreen: NSScreen?) {
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
