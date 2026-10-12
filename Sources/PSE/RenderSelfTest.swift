import AppKit

/// `PSE --render-test <out.png>`: renders sample annotations on a synthetic image (no permissions needed).
@MainActor
enum RenderSelfTest {
    static func runIfRequested() {
        let args = CommandLine.arguments
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
}
