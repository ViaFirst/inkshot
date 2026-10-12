import AppKit
import SwiftUI

@MainActor
final class HistoryWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    init(store: HistoryStore, onOpen: @escaping (HistoryItem) -> Void) {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 780, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = L("Screenshot History")
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: HistoryView(store: store, hover: HoverTracker(), onOpen: onOpen))
        window.setFrameAutosaveName("PSEHistory")
        if !window.setFrameUsingName("PSEHistory") { window.center() }
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
