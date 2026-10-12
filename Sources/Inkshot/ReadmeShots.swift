import AppKit
import ImageIO
import SwiftUI

/// `Inkshot --readme-shots <desktop.png> <mobile.png> [outDir]`: renders the README screenshots from
/// Inkshot's real windows (editor, capture overlay, history) plus a full-page web capture pair.
/// The two inputs are full-page renders from `--web-test` (desktop 1280 and mobile 390, @2x).
@MainActor
enum ReadmeShots {
    static func run(demoDesktop: String, demoMobile: String, out: String) {
        Task { @MainActor in
            do {
                try await generate(desktopURL: URL(fileURLWithPath: demoDesktop),
                                   mobileURL: URL(fileURLWithPath: demoMobile),
                                   out: URL(fileURLWithPath: out, isDirectory: true))
                exit(0)
            } catch {
                print("ERROR", error)
                exit(1)
            }
        }
    }

    private static func load(_ url: URL) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw NSError(domain: "Inkshot", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot read \(url.path)"])
        }
        return img
    }

    private static func generate(desktopURL: URL, mobileURL: URL, out: URL) async throws {
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let desktop = try load(desktopURL), mobile = try load(mobileURL)
        // The "screen": the top 1280×800 pt of the desktop page.
        let screen = desktop.cropping(to: CGRect(x: 0, y: 0, width: 2560, height: 1600))!

        // 1. Editor with annotations.
        let store = HistoryStore(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("inkshot-readme-\(UUID().uuidString)"))
        let shot = screen.cropping(to: CGRect(x: 160, y: 120, width: 2240, height: 1360))!
        let item = store.add(image: shot, scale: 2)
        let c = Palette.colors, u: CGFloat = 2 * StrokeSize.m.rawValue
        let edits = EditState(annotations: [
            Annotation(kind: .rect(CGRect(x: 690, y: 540, width: 880, height: 300)), color: c[0], unit: u),
            Annotation(kind: .arrow(CGPoint(x: 1960, y: 1220), CGPoint(x: 1600, y: 860)), color: c[0], unit: u),
            Annotation(kind: .number(CGPoint(x: 690, y: 540), 1), color: c[0], unit: u),
            Annotation(kind: .highlight(CGRect(x: 480, y: 918, width: 1320, height: 76)), color: c[2], unit: u),
            Annotation(kind: .number(CGPoint(x: 480, y: 918), 2), color: c[1], unit: u),
            Annotation(kind: .text(CGPoint(x: 1690, y: 1260), "New headline"), color: c[7], unit: u),
        ], crop: CGRect(x: 0, y: 0, width: shot.width, height: shot.height))
        let editor = EditorWindowController(item: item, image: shot, edits: edits, history: store, screen: nil)
        let editorImage = try await capture(editor.window!, size: CGSize(width: 1180, height: 790))
        try write(framed(editorImage, title: "Inkshot — 2240 × 1360"), to: out.appendingPathComponent("editor.png"))

        // 2. Capture overlay: selection, toolbar, loupe.
        let display = DisplayShot(displayID: 0, image: screen, frame: CGRect(x: 0, y: 0, width: 1280, height: 800))
        let controller = CaptureController()
        let overlay = OverlayView(shot: display, windows: [], controller: controller, showToolbar: true)
        overlay.debugSelect(CGRect(x: 178, y: 196, width: 650, height: 148))
        overlay.debugMovePointer(to: CGPoint(x: 828, y: 344))
        let overlayWindow = hostWindow(size: display.frame.size)
        overlayWindow.contentView = overlay
        let overlayImage = try await capture(overlayWindow, size: display.frame.size)
        try write(rounded(overlayImage), to: out.appendingPathComponent("overlay.png"))

        // 3. History: a few captures, one pinned.
        for (i, y) in [0, 1600, 3200, 4800, 6400].enumerated() {
            let crop = desktop.cropping(to: CGRect(x: 0, y: y, width: 2560, height: 1600))!
            let added = store.add(image: crop, scale: 2)
            if i == 2 { store.togglePin(added) }
        }
        store.flush()
        let history = HistoryWindowController(store: store) { _ in }
        let historyImage = try await capture(history.window!, size: CGSize(width: 980, height: 640))
        try write(framed(historyImage, title: L("Screenshot History")), to: out.appendingPathComponent("history.png"))

        // 4. Full web page: desktop next to mobile, both whole pages.
        try write(webPair(desktop: desktop, mobile: mobile), to: out.appendingPathComponent("webpage.png"))

        print("wrote", out.path)
    }

    // MARK: Rendering windows

    private static func hostWindow(size: CGSize) -> NSWindow {
        let w = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        return w
    }

    /// Shows the window below the desktop (unseen), lets it render, then draws its content
    /// view's layer tree at 2x. SwiftUI and visual-effect views only paint fully this way.
    private static func capture(_ window: NSWindow, size: CGSize) async throws -> CGImage {
        let origin = NSScreen.screens.first?.frame.origin ?? .zero
        window.setContentSize(size)
        window.setFrameOrigin(origin)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        window.ignoresMouseEvents = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.orderFrontRegardless()
        guard let view = window.contentView else { throw NSError(domain: "Inkshot", code: 2) }
        view.wantsLayer = true
        view.layoutSubtreeIfNeeded()
        view.needsDisplay = true
        try await Task.sleep(nanoseconds: 900_000_000)
        view.displayIfNeeded()

        let scale: CGFloat = 2
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard let layer = view.layer,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else {
            throw NSError(domain: "Inkshot", code: 3)
        }
        ctx.setFillColor(NSColor(srgbRed: 0.12, green: 0.12, blue: 0.13, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        // Flipped views (SwiftUI hosting, the overlay) lay their layers out top-down.
        if view.isFlipped {
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        layer.render(in: ctx)
        window.orderOut(nil)
        return ctx.makeImage()!
    }

    // MARK: Decoration

    /// Window chrome for README: title bar with traffic lights, rounded corners, soft shadow.
    private static func framed(_ content: CGImage, title: String) -> CGImage {
        let s: CGFloat = 2, bar = 28 * s, pad = 40 * s, radius = 12 * s
        let cw = CGFloat(content.width), ch = CGFloat(content.height)
        let W = Int(cw + pad * 2), H = Int(ch + bar + pad * 2)
        let ctx = transparentContext(W, H)
        let win = CGRect(x: pad, y: pad, width: cw, height: ch + bar)
        let path = CGPath(roundedRect: win, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -12 * s), blur: 30 * s, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.addPath(path)
        ctx.setFillColor(NSColor(srgbRed: 0.17, green: 0.17, blue: 0.18, alpha: 1).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.draw(content, in: CGRect(x: pad, y: pad, width: cw, height: ch))
        ctx.setFillColor(NSColor(srgbRed: 0.2, green: 0.2, blue: 0.21, alpha: 1).cgColor)
        ctx.fill(CGRect(x: pad, y: pad + ch, width: cw, height: bar))
        ctx.restoreGState()
        for (i, hex) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
            ctx.setFillColor(NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                                     blue: CGFloat(hex & 0xFF) / 255, alpha: 1).cgColor)
            ctx.fillEllipse(in: CGRect(x: pad + (14 + CGFloat(i) * 20) * s, y: pad + ch + 8 * s, width: 12 * s, height: 12 * s))
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13 * s, weight: .semibold),
                                                    .foregroundColor: NSColor(white: 0.85, alpha: 1)]
        let t = title as NSString, ts = t.size(withAttributes: attrs)
        t.draw(at: CGPoint(x: pad + (cw - ts.width) / 2, y: pad + ch + (bar - ts.height) / 2), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()!
    }

    private static func rounded(_ content: CGImage) -> CGImage {
        let s: CGFloat = 2, pad = 40 * s
        let cw = CGFloat(content.width), ch = CGFloat(content.height)
        let ctx = transparentContext(Int(cw + pad * 2), Int(ch + pad * 2))
        let rect = CGRect(x: pad, y: pad, width: cw, height: ch)
        let path = CGPath(roundedRect: rect, cornerWidth: 14 * s, cornerHeight: 14 * s, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -12 * s), blur: 30 * s, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.addPath(path)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.draw(content, in: rect)
        return ctx.makeImage()!
    }

    /// The top of the desktop and mobile full-page captures side by side, at the same scale
    /// (2400 pt of page each), so the mobile layout keeps its real proportions.
    private static func webPair(desktop fullDesktop: CGImage, mobile fullMobile: CGImage) -> CGImage {
        let pageRows = 4800 // 2400 pt @2x
        let desktop = fullDesktop.cropping(to: CGRect(x: 0, y: 0, width: fullDesktop.width, height: min(pageRows, fullDesktop.height)))!
        let mobile = fullMobile.cropping(to: CGRect(x: 0, y: 0, width: fullMobile.width, height: min(pageRows, fullMobile.height)))!
        let height: CGFloat = 2000
        let dw = CGFloat(desktop.width) * height / CGFloat(desktop.height)
        let mw = CGFloat(mobile.width) * height / CGFloat(mobile.height)
        let gap: CGFloat = 80, pad: CGFloat = 60
        let ctx = transparentContext(Int(dw + mw + gap + pad * 2), Int(height + pad * 2))
        ctx.interpolationQuality = .high
        for (img, rect) in [(desktop, CGRect(x: pad, y: pad, width: dw, height: height)),
                            (mobile, CGRect(x: pad + dw + gap, y: pad, width: mw, height: height))] {
            let path = CGPath(roundedRect: rect, cornerWidth: 16, cornerHeight: 16, transform: nil)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: NSColor.black.withAlphaComponent(0.3).cgColor)
            ctx.addPath(path)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillPath()
            ctx.restoreGState()
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            ctx.draw(img, in: rect)
            ctx.restoreGState()
        }
        return ctx.makeImage()!
    }

    private static func transparentContext(_ w: Int, _ h: Int) -> CGContext {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    private static func write(_ image: CGImage, to url: URL) throws {
        // README images: at most 1600 px wide, so the repo stays light.
        let maxWidth: CGFloat = 1600
        var img = image
        if CGFloat(image.width) > maxWidth {
            let k = maxWidth / CGFloat(image.width)
            let ctx = transparentContext(Int(maxWidth), Int(CGFloat(image.height) * k))
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: maxWidth, height: CGFloat(image.height) * k))
            img = ctx.makeImage()!
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
        print("wrote", url.lastPathComponent, img.width, "x", img.height)
    }
}
