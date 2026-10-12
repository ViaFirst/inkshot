import AppKit
import UniformTypeIdentifiers

/// Localized UI string. English text is the key, so a missing translation falls back to English.
/// Translations: Resources/Localization/<lang>.lproj/Localizable.strings
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

enum Permissions {
    enum Pane: String {
        case accessibility = "Privacy_Accessibility"
        case screenRecording = "Privacy_ScreenCapture"
        case automation = "Privacy_Automation"
    }

    static func openSettings(_ pane: Pane) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// True when screen capture is allowed; otherwise asks and explains what to do.
    @MainActor
    static func ensureScreenCapture() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        CGRequestScreenCaptureAccess()
        let alert = NSAlert()
        alert.messageText = L("Screen Recording access is required")
        alert.informativeText = L("Open System Settings → Privacy & Security → Screen Recording, turn on Inkshot, then restart Inkshot.")
        alert.addButton(withTitle: L("Open Settings"))
        alert.addButton(withTitle: L("Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { openSettings(.screenRecording) }
        return false
    }
}

enum ImageExport {
    /// PNG tagged with the real DPI, so a Retina capture pastes at its logical size.
    static func pngData(_ image: CGImage, scale: CGFloat) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        return rep.representation(using: .png, properties: [:])
    }

    /// Puts the image on the pasteboard lazily: PNG/TIFF are only encoded when another app actually
    /// pastes, so editing a tall capture (which refreshes the pasteboard on every change) costs nothing.
    @MainActor
    static func copyToPasteboard(_ image: CGImage, scale: CGFloat, pasteboard pb: NSPasteboard = .general) {
        let provider = LazyImageProvider(image: image, scale: scale)
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.png, .tiff])
        pb.clearContents()
        pb.writeObjects([item])
        LazyImageProvider.current = provider
    }

    static func copyPNGData(_ png: Data) {
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        if let tiff = NSBitmapImageRep(data: png)?.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([item])
    }

    static func defaultFileName(date: Date = Date()) -> String {
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        let time = DateFormatter()
        time.dateFormat = "HH.mm.ss"
        return String(format: L("Screenshot %@ at %@.png"), day.string(from: date), time.string(from: date))
    }
}

/// Encodes the pasteboard image on demand. Kept alive by `current` until the pasteboard lets go.
final class LazyImageProvider: NSObject, NSPasteboardItemDataProvider {
    @MainActor static var current: LazyImageProvider?

    private let image: CGImage
    private let scale: CGFloat
    private var png: Data?

    init(image: CGImage, scale: CGFloat) {
        self.image = image
        self.scale = scale
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        if png == nil { png = ImageExport.pngData(image, scale: scale) }
        guard let png else { return }
        if type == .png {
            item.setData(png, forType: .png)
        } else if type == .tiff, let tiff = NSBitmapImageRep(data: png)?.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
    }

    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
        MainActor.assumeIsolated {
            if Self.current === self { Self.current = nil }
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    static var underMouse: NSScreen? {
        let p = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(p, $0.frame, false) } ?? main
    }
}

extension NSColor {
    var isLight: Bool {
        guard let c = usingColorSpace(.sRGB) else { return false }
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent > 0.65
    }
}

extension CGRect {
    init(from a: CGPoint, to b: CGPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}

extension CGPoint {
    func distance(to p: CGPoint) -> CGFloat { hypot(x - p.x, y - p.y) }
}
