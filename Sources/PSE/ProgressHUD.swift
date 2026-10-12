import AppKit

/// Small floating "working…" panel with a spinner and a cancel button. Non-activating.
@MainActor
final class ProgressHUD {
    private let panel: NSPanel
    private let onCancel: () -> Void
    private var keyMonitor: Any?

    init(text: String, onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
        panel = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: .vibrantDark)
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)

        let label = NSTextField(labelWithString: text)
        label.textColor = .white
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.lineBreakMode = .byTruncatingMiddle
        label.widthAnchor.constraint(lessThanOrEqualToConstant: 320).isActive = true

        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        let cancel = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) ?? NSImage(), target: nil, action: nil)
        cancel.isBordered = false
        cancel.contentTintColor = .white
        cancel.toolTip = L("Cancel (Esc)")

        let stack = NSStackView(views: [spinner, label, cancel])
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 10)
        let size = stack.fittingSize
        stack.frame = CGRect(origin: .zero, size: size)
        effect.frame = stack.frame
        effect.addSubview(stack)
        panel.contentView = effect
        panel.setContentSize(size)

        cancel.target = self
        cancel.action = #selector(cancelTapped)
    }

    func show(on screen: NSScreen?) {
        let visible = (screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let size = panel.frame.size
        panel.setFrameOrigin(CGPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 60))
        panel.orderFrontRegardless()
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { MainActor.assumeIsolated { self?.cancelTapped() } }
        }
    }

    func close() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panel.orderOut(nil)
    }

    @objc private func cancelTapped() {
        onCancel()
    }
}
