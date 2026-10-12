import AppKit

/// Short non-activating message near the top of the screen that fades out by itself.
@MainActor
enum Toast {
    private static var current: NSPanel?

    static func show(_ text: String, swatch: NSColor? = nil, on screen: NSScreen?, seconds: Double = 1.4) {
        current?.orderOut(nil)

        let panel = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: .vibrantDark)
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true

        var views: [NSView] = []
        if let swatch {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.backgroundColor = swatch.cgColor
            dot.layer?.cornerRadius = 9
            dot.layer?.borderWidth = 1
            dot.layer?.borderColor = NSColor.white.withAlphaComponent(0.6).cgColor
            dot.widthAnchor.constraint(equalToConstant: 18).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 18).isActive = true
            views.append(dot)
        }
        let label = NSTextField(labelWithString: text)
        label.textColor = .white
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        views.append(label)

        let stack = NSStackView(views: views)
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 16)
        let size = stack.fittingSize
        stack.frame = CGRect(origin: .zero, size: size)
        effect.frame = stack.frame
        effect.addSubview(stack)
        panel.contentView = effect
        panel.setContentSize(size)

        let visible = (screen ?? NSScreen.main)?.visibleFrame ?? .zero
        panel.setFrameOrigin(CGPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 60))
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        current = panel

        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                panel.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated {
                    panel.orderOut(nil)
                    if current === panel { current = nil }
                }
            })
        }
    }
}

extension NSColor {
    /// "#RRGGBB" in sRGB.
    convenience init?(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6, let v = UInt32(digits, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}
