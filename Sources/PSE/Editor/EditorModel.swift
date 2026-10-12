import AppKit
import CoreImage
import Combine

@MainActor
final class EditorModel: ObservableObject {
    let image: CGImage
    let scale: CGFloat
    let base: NSImage
    var imageSize: CGSize { base.size }

    @Published var annotations: [Annotation] = []
    @Published var crop: CGRect
    @Published var selectedID: UUID?
    @Published var tool: Tool = .arrow { didSet { if tool != .select { selectedID = nil } } }
    @Published var color: NSColor = Palette.colors[0] { didSet { restyleSelection() } }
    @Published var size: StrokeSize = .m { didSet { restyleSelection() } }
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    /// Called after every committed change (used to refresh the pasteboard).
    var onCommit: (() -> Void)?

    private struct Snapshot {
        var annotations: [Annotation]
        var crop: CGRect
    }

    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private var cachedPixelated: NSImage?

    init(image: CGImage, scale: CGFloat) {
        self.image = image
        self.scale = scale
        base = NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
        crop = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    }

    var unit: CGFloat { scale * size.rawValue }

    var selected: Annotation? { annotations.first { $0.id == selectedID } }

    var nextNumber: Int {
        annotations.reduce(0) { n, a in
            if case let .number(_, k) = a.kind { return max(n, k) }
            return n
        } + 1
    }

    func pixelated() -> NSImage {
        if let cachedPixelated { return cachedPixelated }
        let ci = CIImage(cgImage: image)
        let output = ci.clampedToExtent()
            .applyingFilter("CIPixellate", parameters: [
                kCIInputScaleKey: max(10, 12 * scale),
                kCIInputCenterKey: CIVector(x: 0, y: 0),
            ])
            .cropped(to: ci.extent)
        let result: NSImage
        if let cg = CIContext().createCGImage(output, from: ci.extent) {
            result = NSImage(cgImage: cg, size: imageSize)
        } else {
            result = base
        }
        cachedPixelated = result
        return result
    }

    // MARK: Mutations (all undoable)

    func commit(_ change: () -> Void) {
        undoStack.append(Snapshot(annotations: annotations, crop: crop))
        redoStack.removeAll()
        change()
        didCommit()
    }

    func add(_ a: Annotation) {
        commit { annotations.append(a) }
    }

    /// Live edits (dragging a shape) mutate `annotations` directly and become one undo step.
    private var liveSnapshot: Snapshot?

    func beginLiveChange() {
        liveSnapshot = Snapshot(annotations: annotations, crop: crop)
    }

    func endLiveChange() {
        guard let s = liveSnapshot else { return }
        liveSnapshot = nil
        undoStack.append(s)
        redoStack.removeAll()
        didCommit()
    }

    func deleteSelected() {
        guard let id = selectedID else { return }
        commit { annotations.removeAll { $0.id == id } }
        selectedID = nil
    }

    func undo() {
        guard let s = undoStack.popLast() else { return }
        redoStack.append(Snapshot(annotations: annotations, crop: crop))
        restore(s)
    }

    func redo() {
        guard let s = redoStack.popLast() else { return }
        undoStack.append(Snapshot(annotations: annotations, crop: crop))
        restore(s)
    }

    private func restore(_ s: Snapshot) {
        annotations = s.annotations
        crop = s.crop
        if let id = selectedID, !annotations.contains(where: { $0.id == id }) { selectedID = nil }
        didCommit()
    }

    private func didCommit() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
        onCommit?()
    }

    private func restyleSelection() {
        guard let id = selectedID, let i = annotations.firstIndex(where: { $0.id == id }) else { return }
        commit {
            annotations[i].color = color
            annotations[i].unit = unit
        }
    }

    // MARK: Export

    func render() -> CGImage {
        let w = image.width, h = image.height
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return image }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        SceneRenderer.draw(base: base, pixelated: pixelated, annotations: annotations, deviceScale: 1)
        NSGraphicsContext.restoreGraphicsState()

        guard let full = ctx.makeImage() else { return image }
        return full.cropping(to: crop.integral) ?? full
    }
}
