import AppKit
import ImageIO

/// `PSE --render-test <out.png>`: renders sample annotations on a synthetic image (no permissions needed).
@MainActor
enum RenderSelfTest {
    /// Returns true when a test needs the run loop (it exits by itself when done).
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--web-probe"), i + 1 < args.count {
            Task { @MainActor in
                let r = WebPageRenderer(width: 1280, mobile: false)
                print(await r.probe(URL(string: args[i + 1])!))
                exit(0)
            }
            return true
        }
        if let i = args.firstIndex(of: "--web-test"), i + 2 < args.count {
            webTest(url: args[i + 1], out: args[i + 2], width: args.dropFirst(i + 3).first.flatMap { Double($0) } ?? 1280,
                    mobile: args.contains("mobile"))
            return true
        }
        if let i = args.firstIndex(of: "--loupe-test"), i + 1 < args.count { loupeTest(out: args[i + 1]) }
        if let i = args.firstIndex(of: "--highlight-test"), i + 1 < args.count { highlightTest(out: args[i + 1]) }
        if args.contains("--stitch-test") { stitchTest() }
        if let i = args.firstIndex(of: "--replay"), i + 1 < args.count { replay(URL(fileURLWithPath: args[i + 1])) }
        if let i = args.firstIndex(of: "--history-test"), i + 1 < args.count {
            historyTest(root: URL(fileURLWithPath: args[i + 1]))
        }
        guard let i = args.firstIndex(of: "--render-test"), i + 1 < args.count else { return false }
        let w = 1200, h = 700
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        for y in stride(from: 0, to: h, by: 50) {
            for x in stride(from: 0, to: w, by: 50) {
                ctx.setFillColor(red: CGFloat(x) / CGFloat(w), green: 0.6, blue: CGFloat(y) / CGFloat(h), alpha: 1)
                ctx.fill(CGRect(x: x, y: y, width: 50, height: 50))
            }
        }
        let model = EditorModel(image: ctx.makeImage()!, scale: 2)
        let u = model.unit
        let c = Palette.colors
        model.add(Annotation(kind: .arrow(CGPoint(x: 100, y: 600), CGPoint(x: 420, y: 220)), color: c[0], unit: u))
        model.add(Annotation(kind: .rect(CGRect(x: 450, y: 100, width: 300, height: 180)), color: c[4], unit: u))
        model.add(Annotation(kind: .highlight(CGRect(x: 120, y: 80, width: 260, height: 50)), color: c[2], unit: u))
        model.add(Annotation(kind: .pixelate(CGRect(x: 800, y: 380, width: 300, height: 200)), color: c[0], unit: u))
        model.add(Annotation(kind: .number(CGPoint(x: 470, y: 120), 1), color: c[0], unit: u))
        model.add(Annotation(kind: .number(CGPoint(x: 820, y: 400), 2), color: c[2], unit: u))
        model.add(Annotation(kind: .text(CGPoint(x: 460, y: 320), "Привет, PSE! ✓"), color: c[0], unit: u))
        model.add(Annotation(kind: .text(CGPoint(x: 460, y: 420), "White text"), color: c[7], unit: u))
        model.commit { model.crop = CGRect(x: 50, y: 50, width: 1100, height: 620) }
        let data = ImageExport.pngData(model.render(), scale: 2)!
        try? data.write(to: URL(fileURLWithPath: args[i + 1]))
        exit(0)
    }

    /// `PSE --history-test <empty dir>`: limit/pin/prune/persistence checks on a throwaway folder.
    private static func historyTest(root: URL) {
        func check(_ ok: Bool, _ msg: String) { print(ok ? "PASS" : "FAIL", msg); if !ok { exit(1) } }
        let ctx = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        ctx.setFillColor(NSColor.systemTeal.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        let image = ctx.makeImage()!

        UserDefaults.standard.removeObject(forKey: "historyLimit")
        let store = HistoryStore(root: root)
        check(store.limit == 10, "default limit is 10")
        store.limit = 3
        let first = store.add(image: image, scale: 2)
        store.togglePin(first)
        var added: [HistoryItem] = []
        for _ in 0..<5 { added.append(store.add(image: image, scale: 2)) }
        check(store.recent.count == 3, "keeps 3 unpinned (got \(store.recent.count))")
        check(store.pinned.map(\.id) == [first.id], "pinned survives pruning")
        check(store.recent.map(\.id) == added.suffix(3).reversed().map(\.id), "newest kept, oldest removed")

        let edits = EditState(annotations: [Annotation(kind: .arrow(.zero, CGPoint(x: 50, y: 50)), color: Palette.colors[4], unit: 2)],
                              crop: CGRect(x: 10, y: 10, width: 200, height: 100))
        let cropped = image.cropping(to: edits.crop)!
        store.update(added[4].id, edits: edits, rendered: cropped)
        store.flush()
        let dirs = (try? FileManager.default.contentsOfDirectory(atPath: root.path).filter { !$0.hasSuffix(".json") }) ?? []
        check(dirs.count == 4, "only 4 item folders on disk (got \(dirs.count))")

        let reloaded = HistoryStore(root: root)
        check(reloaded.items.count == 4 && reloaded.limit == 3, "index and limit persist")
        let item = reloaded.items.first { $0.id == added[4].id }!
        check(item.width == 200 && item.height == 100, "final size updated")
        let (orig, saved) = reloaded.loadForEditing(item)!
        check(orig.width == 400, "original kept uncropped")
        check(saved?.crop == edits.crop && saved?.annotations.count == 1, "edits reload")
        check(reloaded.thumbnail(item) != nil, "thumbnail on disk")
        reloaded.limit = 1
        check(reloaded.items.count == 2 && reloaded.pinned.count == 1, "lowering the limit prunes, pin stays")
        UserDefaults.standard.removeObject(forKey: "historyLimit")
        exit(0)
    }

    /// `PSE --stitch-test`: scrolls a synthetic page with a sticky header/footer and a flickering
    /// scroll indicator, and checks the stitched result pixel by pixel.
    private static func stitchTest() {
        func check(_ ok: Bool, _ msg: String) { print(ok ? "PASS" : "FAIL", msg); if !ok { exit(1) } }
        let w = 600, h = 500, header = 60, footer = 40, view = h - header - footer
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        func noise(_ a: Int, _ b: Int) -> UInt32 {
            var x = UInt32(truncatingIfNeeded: a &* 73856093 ^ b &* 19349663)
            x ^= x >> 13; x = x &* 0x5bd1e995; x ^= x >> 15
            return x
        }
        // Text-like content; rows 800..<950 are blank (uniform) to test ambiguity.
        func contentPixel(_ x: Int, _ y: Int) -> UInt32 {
            if (800..<950).contains(y) { return 0xFFFF_FFFF }
            return noise(x / 6, y / 2) % 3 == 0 ? 0xFF20_2020 : 0xFFF5_F5F5
        }
        func frame(offset o: Int, flicker: Int) -> CGImage {
            var px = [UInt32](repeating: 0, count: w * h)
            for y in 0..<h {
                for x in 0..<w {
                    let v: UInt32
                    if y < header { v = 0xFF33_66CC }
                    else if y >= h - footer { v = 0xFFCC_3333 }
                    else { v = contentPixel(x, o + y - header) }
                    px[y * w + x] = v
                }
                // overlay scroll indicator at the right edge, different every frame
                for x in (w - 12)..<(w - 4) { px[y * w + x] = noise(flicker, y / 40) | 0xFF00_0000 }
            }
            let data = Data(bytes: px, count: px.count * 4)
            return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: space,
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                           provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        }

        let stitcher = ScrollStitcher(scale: 2)
        // pauses, small and big steps, a step back up, a too-fast jump and recovery
        let offsets = [0, 0, 40, 40, 160, 400, 380, 650, 900, 1200, 2000, 1250, 1500, 1800, 1800, 2100, 2400]
        var results: [ScrollStitcher.Result] = []
        var accepted = 0
        for (i, o) in offsets.enumerated() {
            let r = stitcher.add(frame(offset: o, flicker: i))
            results.append(r)
            if case .appended = r { accepted = o }
        }
        print("results:", results.map { "\($0)" }.joined(separator: " "))
        check({ if case .first = results[0] { true } else { false } }(), "first frame")
        check({ if case .noMotion = results[1] { true } else { false } }(), "pause = no motion")
        check({ if case .lost = results[10] { true } else { false } }(), "too-fast jump detected")
        check(accepted == 2400, "recovered and reached the last offset (got \(accepted))")

        guard let out = stitcher.makeImage() else { return check(false, "image") }
        let expectedRows = header + accepted + view + footer
        check(out.height == expectedRows && out.width == w, "size \(out.width)x\(out.height), expected \(w)x\(expectedRows)")

        let bytes = CFDataGetBytePtr(out.dataProvider!.data)!
        var mismatches = 0
        for y in 0..<out.height {
            for x in 0..<(w - 24) {   // scroll-indicator strip is allowed to differ
                let expected: UInt32 = y < header ? 0xFF33_66CC
                    : y >= out.height - footer ? 0xFFCC_3333
                    : contentPixel(x, y - header)
                let i = (y * w + x) * 4
                let got = UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24
                if got != expected { mismatches += 1 }
            }
        }
        check(mismatches == 0, "pixel-exact page, header and footer once (\(mismatches) wrong pixels)")
        check(stitcher.suggestedColumns() == nil, "full-width content: no auto-crop")
        sidebarTest()
        exit(0)
    }

    /// Like 3dnews: a left menu that scrolls away, a fixed "back to top" button, a fixed right
    /// panel, thin scrolling slivers at both edges and the main column in the middle. Auto-crop should keep only the middle.
    private static func sidebarTest() {
        func check(_ ok: Bool, _ msg: String) { print(ok ? "PASS" : "FAIL", msg); if !ok { exit(1) } }
        let w = 700, h = 500
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        func noise(_ a: Int, _ b: Int) -> UInt32 {
            var x = UInt32(truncatingIfNeeded: a &* 73856093 ^ b &* 19349663)
            x ^= x >> 13; x = x &* 0x5bd1e995; x ^= x >> 15
            return x
        }
        let dark: UInt32 = 0xFF22_2222
        func frame(offset o: Int) -> CGImage {
            var px = [UInt32](repeating: dark, count: w * h)
            for y in 0..<h {
                let page = o + y
                for x in 0..<w {
                    var v = dark
                    if x < 10 || x >= 690 {
                        v = noise(x, page / 4) % 2 == 0 ? 0xFF2A_2A2A : 0xFF26_2626               // scrolling page edge
                    } else if x < 140 {
                        if page < 600, noise(x / 5, page / 3) % 3 == 0 { v = 0xFF66_99FF } // menu, scrolls away
                        if (380..<400).contains(y), (50..<90).contains(x) { v = 0xFFEE_EEEE } // fixed button
                    } else if (160..<580).contains(x) {
                        v = noise(x / 6, page / 2) % 3 == 0 ? 0xFFF0_F0F0 : 0xFF30_3040      // main column
                    } else if x >= 600 {
                        v = noise(x / 4, y / 3) % 2 == 0 ? 0xFF99_9999 : 0xFF44_4444          // fixed panel
                    }
                    px[y * w + x] = v
                }
            }
            let data = Data(bytes: px, count: px.count * 4)
            return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: space,
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                           provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        }
        let stitcher = ScrollStitcher(scale: 2)
        for o in stride(from: 0, through: 2400, by: 200) { _ = stitcher.add(frame(offset: o)) }
        let cols = stitcher.suggestedColumns()
        print("suggested columns:", cols.map { "\($0.lowerBound)..<\($0.upperBound)" } ?? "none")
        guard let cols else { return check(false, "auto-crop suggested") }
        check((130...160).contains(cols.lowerBound), "left menu + fixed button cut off")
        check((580...600).contains(cols.upperBound), "fixed right panel cut off")

    }

    /// `PSE --replay <dir> [scale]`: feeds saved debug frames to the stitcher and prints its decisions.
    private static func replay(_ dir: URL) {
        let args = CommandLine.arguments
        let scale = args.last.flatMap { Double($0) }.map { CGFloat($0) } ?? 2
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "png" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let stitcher = ScrollStitcher(scale: scale)
        var log: [String] = []
        for f in files {
            guard let src = CGImageSourceCreateWithURL(f as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
            log.append("\(f.lastPathComponent): \(stitcher.add(img)) h=\(stitcher.stitchedHeight)")
        }
        print(log.joined(separator: "\n"))
        print(stitcher.debugSummary())
        print("suggested:", stitcher.suggestedColumns().map { "\($0)" } ?? "none")
        if let out = stitcher.makeImage(), let data = ImageExport.pngData(out, scale: scale) {
            try? data.write(to: dir.appendingPathComponent("stitched.png"))
        }
        exit(0)
    }

    /// `PSE --web-test <url> <out.png> [width] [mobile]`: full-page render without UI.
    private static func webTest(url: String, out: String, width: Double, mobile: Bool) {
        Task { @MainActor in
            let start = Date()
            let renderer = WebPageRenderer(width: CGFloat(width), mobile: mobile)
            do {
                let (image, scale) = try await renderer.render(URL(string: url)!, scale: 2)
                try ImageExport.pngData(image, scale: scale)!.write(to: URL(fileURLWithPath: out))
                print("OK \(image.width)x\(image.height) scale \(scale) in \(Int(Date().timeIntervalSince(start)))s, passes: \(renderer.attempts)")
            } catch {
                print("ERROR", error.localizedDescription)
            }
            exit(0)
        }
    }

    /// `PSE --loupe-test <out.png>`: draws the overlay with the loupe over a synthetic screen.
    private static func loupeTest(out: String) {
        let w = 1600, h = 1000   // 800×500 pt at 2x
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        ("Pixel-perfect PSE" as NSString).draw(at: CGPoint(x: 200, y: 500), withAttributes: [
            .font: NSFont.systemFont(ofSize: 90, weight: .bold), .foregroundColor: NSColor.systemPurple])
        NSGraphicsContext.restoreGraphicsState()
        ctx.setFillColor(NSColor.systemOrange.cgColor)
        ctx.fill(CGRect(x: 1400, y: 60, width: 200, height: 200))

        let shot = DisplayShot(displayID: 0, image: ctx.makeImage()!, frame: CGRect(x: 0, y: 0, width: 800, height: 500))
        let controller = CaptureController()
        for (name, point) in [("middle", CGPoint(x: 160, y: 228)), ("edge", CGPoint(x: 760, y: 440))] {
            let view = OverlayView(shot: shot, windows: [], controller: controller, showToolbar: false)
            view.debugMovePointer(to: point)
            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: rep)
            let url = URL(fileURLWithPath: out.replacingOccurrences(of: ".png", with: "-\(name).png"))
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            print("wrote", url.path)
        }
        exit(0)
    }

    /// `PSE --highlight-test <out.png>`: yellow highlighter on a dark UI and on a light page.
    private static func highlightTest(out: String) {
        let w = 1400, h = 400
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        ctx.setFillColor(NSColor(srgbRed: 0.12, green: 0.12, blue: 0.13, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 700, height: h))
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 700, y: 0, width: 700, height: h))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let font = NSFont.systemFont(ofSize: 40, weight: .regular)
        ("Сетка теперь видна" as NSString).draw(at: CGPoint(x: 60, y: 220), withAttributes: [.font: font, .foregroundColor: NSColor(white: 0.85, alpha: 1)])
        ("Dark UI, light text" as NSString).draw(at: CGPoint(x: 60, y: 100), withAttributes: [.font: font, .foregroundColor: NSColor(white: 0.85, alpha: 1)])
        ("Сетка теперь видна" as NSString).draw(at: CGPoint(x: 760, y: 220), withAttributes: [.font: font, .foregroundColor: NSColor.black])
        ("Light page, dark text" as NSString).draw(at: CGPoint(x: 760, y: 100), withAttributes: [.font: font, .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()

        let model = EditorModel(image: ctx.makeImage()!, scale: 2)
        // image coordinates are top-left: the first line sits around y = 130..180
        model.add(Annotation(kind: .highlight(CGRect(x: 50, y: 125, width: 380, height: 60)), color: Palette.colors[2], unit: 2))
        model.add(Annotation(kind: .highlight(CGRect(x: 750, y: 125, width: 380, height: 60)), color: Palette.colors[2], unit: 2))
        model.add(Annotation(kind: .highlight(CGRect(x: 50, y: 245, width: 380, height: 60)), color: Palette.colors[3], unit: 2))
        model.add(Annotation(kind: .highlight(CGRect(x: 750, y: 245, width: 380, height: 60)), color: Palette.colors[3], unit: 2))
        try? ImageExport.pngData(model.render(), scale: 1)?.write(to: URL(fileURLWithPath: out))
        print("wrote", out)
        exit(0)
    }
}
