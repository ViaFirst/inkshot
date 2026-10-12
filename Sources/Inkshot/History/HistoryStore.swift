import AppKit
import ImageIO
import UniformTypeIdentifiers

struct HistoryItem: Codable, Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
    var scale: CGFloat
    var pinned: Bool
    /// Pixel size of the edited (final) image.
    var width: Int
    var height: Int
    /// Bumped on every edit so views reload the thumbnail.
    var revision = 0
}

/// Editable state of a screenshot, saved next to the original image.
struct EditState: Codable {
    var annotations: [Annotation]
    var crop: CGRect
}

/// Screenshot history on disk: ~/Library/Application Support/Inkshot/History/<id>/
///   original.png  raw capture       final.png  with annotations
///   thumb.jpg     list thumbnail    edits.json annotations + crop (re-editable)
/// Keeps the newest `limit` unpinned items; pinned ones are never removed automatically.
@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    static let limitChoices = [5, 10, 20, 50, 100]
    private static let limitKey = "historyLimit"

    @Published private(set) var items: [HistoryItem] = []
    @Published var limit: Int {
        didSet {
            UserDefaults.standard.set(limit, forKey: Self.limitKey)
            prune()
        }
    }

    let root: URL
    private let io = DispatchQueue(label: "com.viafirst.inkshot.history", qos: .utility)
    private var thumbnails: [UUID: NSImage] = [:]

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Inkshot/History", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        let saved = UserDefaults.standard.integer(forKey: Self.limitKey)
        limit = saved > 0 ? saved : 10
        load()
    }

    var pinned: [HistoryItem] { items.filter(\.pinned) }
    var recent: [HistoryItem] { items.filter { !$0.pinned } }

    // MARK: Files

    func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    func finalURL(_ item: HistoryItem) -> URL { folder(item.id).appendingPathComponent("final.png") }
    private func originalURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("original.png") }
    private func thumbURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("thumb.jpg") }
    private func editsURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("edits.json") }
    private var indexURL: URL { root.appendingPathComponent("history.json") }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let saved = try? JSONDecoder().decode([HistoryItem].self, from: data) else { return }
        items = saved
            .filter { FileManager.default.fileExists(atPath: originalURL($0.id).path) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private func saveIndex() {
        let data = try? JSONEncoder().encode(items)
        let url = indexURL
        io.async { try? data?.write(to: url, options: .atomic) }
    }

    // MARK: Changes

    func add(image: CGImage, scale: CGFloat) -> HistoryItem {
        let item = HistoryItem(id: UUID(), createdAt: Date(), scale: scale, pinned: false,
                               width: image.width, height: image.height)
        items.insert(item, at: 0)
        let thumb = Self.makeThumbnail(image)
        thumbnails[item.id] = thumb.map { NSImage(cgImage: $0, size: .zero) }

        let dir = folder(item.id), original = originalURL(item.id), final = finalURL(item), thumbFile = thumbURL(item.id)
        io.async {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            Self.write(image, type: .png, scale: scale, to: original)
            try? FileManager.default.copyItem(at: original, to: final)
            if let thumb { Self.write(thumb, type: .jpeg, scale: 1, to: thumbFile) }
        }
        prune()
        saveIndex()
        return item
    }

    func update(_ id: UUID, edits: EditState, rendered: CGImage) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return } // deleted meanwhile
        items[i].width = rendered.width
        items[i].height = rendered.height
        items[i].revision += 1
        let item = items[i]
        let thumb = Self.makeThumbnail(rendered)
        thumbnails[id] = thumb.map { NSImage(cgImage: $0, size: .zero) }

        let dir = folder(id), final = finalURL(item), thumbFile = thumbURL(id), editsFile = editsURL(id)
        let json = try? JSONEncoder().encode(edits)
        io.async {
            guard FileManager.default.fileExists(atPath: dir.path) else { return }
            try? json?.write(to: editsFile, options: .atomic)
            Self.write(rendered, type: .png, scale: item.scale, to: final)
            if let thumb { Self.write(thumb, type: .jpeg, scale: 1, to: thumbFile) }
        }
        saveIndex()
    }

    func togglePin(_ item: HistoryItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i].pinned.toggle()
        prune()
        saveIndex()
    }

    func delete(_ item: HistoryItem) {
        items.removeAll { $0.id == item.id }
        removeFiles(item.id)
        saveIndex()
    }

    private func prune() {
        let unpinned = items.filter { !$0.pinned }
        guard unpinned.count > limit else { return }
        let doomed = Set(unpinned.dropFirst(limit).map(\.id))
        items.removeAll { doomed.contains($0.id) }
        doomed.forEach(removeFiles)
        saveIndex()
    }

    private func removeFiles(_ id: UUID) {
        thumbnails[id] = nil
        let dir = folder(id)
        io.async { try? FileManager.default.removeItem(at: dir) }
    }

    /// Waits for pending disk writes (used by the self-test).
    func flush() { io.sync {} }

    // MARK: Reading

    func thumbnail(_ item: HistoryItem) -> NSImage? {
        if let cached = thumbnails[item.id] { return cached }
        let image = NSImage(contentsOf: thumbURL(item.id))
        thumbnails[item.id] = image
        return image
    }

    /// Original capture + saved edits, for reopening in the editor.
    func loadForEditing(_ item: HistoryItem) -> (CGImage, EditState?)? {
        guard let src = CGImageSourceCreateWithURL(originalURL(item.id) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let edits = (try? Data(contentsOf: editsURL(item.id))).flatMap { try? JSONDecoder().decode(EditState.self, from: $0) }
        return (image, edits)
    }

    func copy(_ item: HistoryItem) {
        let url = finalURL(item)
        io.async { // after any pending write of this file
            guard let data = try? Data(contentsOf: url) else { return }
            DispatchQueue.main.async { ImageExport.copyPNGData(data) }
        }
    }

    func reveal(_ item: HistoryItem) {
        NSWorkspace.shared.activateFileViewerSelecting([finalURL(item)])
    }

    func revealFolder() {
        NSWorkspace.shared.open(root)
    }

    // MARK: Image helpers

    nonisolated private static func makeThumbnail(_ source: CGImage, maxSide: CGFloat = 480) -> CGImage? {
        // Tall (scrolling) captures: thumbnail of the top part instead of a thin strip.
        let maxHeight = Int(Double(source.width) * 1.25)
        let image = source.height > maxHeight
            ? source.cropping(to: CGRect(x: 0, y: 0, width: source.width, height: maxHeight)) ?? source
            : source
        let k = min(1, maxSide / CGFloat(max(image.width, image.height)))
        let w = max(1, Int(CGFloat(image.width) * k)), h = max(1, Int(CGFloat(image.height) * k))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    nonisolated private static func write(_ image: CGImage, type: UTType, scale: CGFloat, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { return }
        let props: [CFString: Any] = [
            kCGImagePropertyDPIWidth: 72 * scale,
            kCGImagePropertyDPIHeight: 72 * scale,
            kCGImageDestinationLossyCompressionQuality: 0.8,
        ]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        CGImageDestinationFinalize(dest)
    }
}
