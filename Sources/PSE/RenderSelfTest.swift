import AppKit

/// `PSE --render-test <out.png>`: renders sample annotations on a synthetic image (no permissions needed).
@MainActor
enum RenderSelfTest {
    static func runIfRequested() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--history-test"), i + 1 < args.count {
            historyTest(root: URL(fileURLWithPath: args[i + 1]))
        }
        guard let i = args.firstIndex(of: "--render-test"), i + 1 < args.count else { return }
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
}
