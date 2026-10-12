import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    private let model: EditorModel
    private let canvas: CanvasView
    private var pasteboardWork: DispatchWorkItem?
    private let capturedAt = Date()

    private static let lastFolderKey = "lastSaveFolder"

    init(image: CGImage, scale: CGFloat, screen: NSScreen?) {
        model = EditorModel(image: image, scale: scale)
        canvas = CanvasView(model: model)

        let screen = screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let toolbarHeight: CGFloat = 46
        let points = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let size = CGSize(
            width: min(max(points.width + 32, 820), visible.width * 0.92),
            height: min(max(points.height + 32 + toolbarHeight, 360), visible.height * 0.92)
        )
        let window = NSWindow(
            contentRect: CGRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                                width: size.width, height: size.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "PSE — \(image.width) × \(image.height)"
        window.minSize = CGSize(width: 760, height: 320)
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self

        let toolbar = NSHostingView(rootView: EditorToolbar(
            model: model,
            onCopy: { [weak self] in self?.copyAndClose() },
            onSave: { [weak self] in self?.save() },
            onInteract: { [weak self] in self?.focusCanvas() }
        ))
        let content = NSView()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        canvas.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(toolbar)
        content.addSubview(canvas)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: content.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: toolbarHeight),
            canvas.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            canvas.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
        window.initialFirstResponder = canvas

        canvas.onCopyAndClose = { [weak self] in self?.copyAndClose() }
        canvas.onSave = { [weak self] in self?.save() }
        canvas.onClose = { [weak self] in self?.close() }
        model.onCommit = { [weak self] in self?.schedulePasteboardUpdate() }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        focusCanvas()
    }

    private func focusCanvas() {
        window?.makeFirstResponder(canvas)
    }

    // The pasteboard always holds the latest version, so closing with Esc is fine too.
    private func schedulePasteboardUpdate() {
        pasteboardWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            ImageExport.copyToPasteboard(self.model.render(), scale: self.model.scale)
        }
        pasteboardWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func copyAndClose() {
        pasteboardWork?.cancel()
        pasteboardWork = nil
        ImageExport.copyToPasteboard(model.render(), scale: model.scale)
        close()
    }

    func save() {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = ImageExport.defaultFileName(date: capturedAt)
        if let path = UserDefaults.standard.string(forKey: Self.lastFolderKey) {
            panel.directoryURL = URL(fileURLWithPath: path)
        } else {
            panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let image = self.model.render()
            do {
                guard let data = ImageExport.pngData(image, scale: self.model.scale) else { return }
                try data.write(to: url)
                UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: Self.lastFolderKey)
                ImageExport.copyToPasteboard(image, scale: self.model.scale)
                self.close()
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        // Flush a pending pasteboard update so the last edit isn't lost.
        if let work = pasteboardWork {
            pasteboardWork = nil
            work.cancel()
            ImageExport.copyToPasteboard(model.render(), scale: model.scale)
        }
        onClose?()
    }
}
