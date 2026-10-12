import CoreGraphics
import Foundation

/// Glues consecutive frames of a scrolling region into one tall image.
///
/// Each frame row is hashed in a few vertical bands (edges skipped, so the overlay scroll indicator
/// doesn't matter). Rows that are distinctive in the previous frame vote for the scroll offset
/// `dy = rowInPrevious - rowInNew`; a band that doesn't move (fixed sidebar) votes 0 and is outvoted
/// by bands that do. Rows at the bottom that never move (sticky footer / cookie bar) are detected on
/// the first motion and added only once, at the end. Only downward scrolling grows the image.
/// Not thread-safe: the capture session only touches it from its serial stitch queue.
final class ScrollStitcher: @unchecked Sendable {
    enum Result {
        case first, appended, noMotion, lost, full
    }

    private let scale: CGFloat
    private let bands = 3
    private let maxBytes = 160_000_000

    private var width = 0
    private var height = 0
    private var colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private var hashColumns = 0..<0

    private var previous: [UInt8] = []
    private var previousHashes: [UInt64] = []
    private var output = Data()
    private var footer = 0
    private var moving = false

    init(scale: CGFloat) {
        self.scale = scale
    }

    /// Height of the result so far, in pixels.
    var stitchedHeight: Int { moving ? output.count / (width * 4) + footer : height }

    func add(_ image: CGImage) -> Result {
        if width == 0 { setUp(for: image) }
        guard image.width == width, image.height == height, let pixels = pixels(of: image) else { return .lost }
        let hashes = rowHashes(pixels)

        if previous.isEmpty {
            previous = pixels
            previousHashes = hashes
            return .first
        }

        guard let dy = offset(from: previousHashes, to: hashes) else { return .lost }
        guard dy > 0 else { return .noMotion }

        let rowBytes = width * 4
        if !moving {
            var f = 0
            while f < height / 4, rowsEqual(hashes, previousHashes, row: height - 1 - f) { f += 1 }
            footer = f
            moving = true
            append(previous, rows: 0..<(height - footer))
        }

        let end = height - footer
        let start = max(0, end - dy)
        guard output.count + (end - start + footer) * rowBytes <= maxBytes else { return .full }
        append(pixels, rows: start..<end)
        previous = pixels
        previousHashes = hashes
        return .appended
    }

    func makeImage() -> CGImage? {
        guard width > 0, !previous.isEmpty else { return nil }
        var data = moving ? output : Data(previous)
        if moving {
            let rowBytes = width * 4
            data.append(contentsOf: previous[((height - footer) * rowBytes)..<(height * rowBytes)])
        }
        let rows = data.count / (width * 4)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: colorSpace, bitmapInfo: Self.bitmapInfo, provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: Internals

    private static let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
        | CGBitmapInfo.byteOrder32Little.rawValue)

    private func setUp(for image: CGImage) {
        width = image.width
        height = image.height
        if let space = image.colorSpace, space.model == .rgb { colorSpace = space }
        // Skip the left edge and the right strip where the overlay scroll indicator appears.
        let left = Int(4 * scale), right = Int(22 * scale)
        hashColumns = width > left + right + 40 ? left..<(width - right) : 0..<width
    }

    /// BGRA bytes, drawn in the image's own colour space so pixels stay exact.
    private func pixels(of image: CGImage) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: colorSpace, bitmapInfo: Self.bitmapInfo.rawValue)
            else { return false }
            ctx.setBlendMode(.copy)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? buffer : nil
    }

    /// `bands` hashes per row, stored band-major: index = band * height + row.
    private func rowHashes(_ pixels: [UInt8]) -> [UInt64] {
        var hashes = [UInt64](repeating: 0, count: bands * height)
        let columns = hashColumns
        let bandWidth = max(1, columns.count / bands)
        pixels.withUnsafeBytes { raw in
            let px = raw.bindMemory(to: UInt32.self)
            for row in 0..<height {
                let base = row * width
                for band in 0..<bands {
                    let from = columns.lowerBound + band * bandWidth
                    let to = band == bands - 1 ? columns.upperBound : from + bandWidth
                    var h: UInt64 = 0xcbf2_9ce4_8422_2325 &+ UInt64(band)
                    for x in from..<to {
                        h = (h ^ UInt64(px[base + x])) &* 0x0000_0100_0000_01b3
                    }
                    hashes[band * height + row] = h
                }
            }
        }
        return hashes
    }

    private func rowsEqual(_ a: [UInt64], _ b: [UInt64], row: Int) -> Bool {
        (0..<bands).allSatisfy { a[$0 * height + row] == b[$0 * height + row] }
    }

    /// Best scroll offset in pixels (0 = no motion), or nil when the frames can't be matched.
    private func offset(from old: [UInt64], to new: [UInt64]) -> Int? {
        // Positions of distinctive rows (appearing at most twice) in the previous frame.
        var positions: [UInt64: [Int]] = [:]
        for (i, h) in old.enumerated() {
            positions[h, default: []].append(i % height)
        }
        positions = positions.filter { $0.value.count <= 2 }

        var votes: [Int: Int] = [:]
        var candidates = 0
        for (i, h) in new.enumerated() {
            guard let rows = positions[h] else { continue }
            candidates += 1
            for p in rows { votes[p - i % height, default: 0] += 1 }
        }

        // The strongest offset wins; on a tie "no motion" wins (repeated rows also vote for ±1).
        // A negative winner means the user scrolled back up: nothing to add.
        let threshold = max(6, candidates / 20)
        guard let best = votes.max(by: { $0.value < $1.value || ($0.value == $1.value && $1.key == 0) }),
              best.value >= threshold else { return old == new ? 0 : nil }
        if best.value == votes[0] { return 0 }
        return best.key
    }

    private func append(_ pixels: [UInt8], rows: Range<Int>) {
        guard !rows.isEmpty else { return }
        let rowBytes = width * 4
        output.append(contentsOf: pixels[(rows.lowerBound * rowBytes)..<(rows.upperBound * rowBytes)])
    }
}
