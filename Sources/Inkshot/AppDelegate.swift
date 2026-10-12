import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static var shared: AppDelegate { NSApp.delegate as! AppDelegate }

    private var statusItem: NSStatusItem!
    private let hotKey = HotKeyMonitor()
    private let capture = CaptureController()
    private var editors: [EditorWindowController] = []
    private var historyWindow: HistoryWindowController?
    private let history = HistoryStore.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Inkshot")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        capture.onCaptured = { [weak self] image, scale, screen, crop in
            guard let self else { return }
            ImageExport.copyToPasteboard(image, scale: scale)
            let item = self.history.add(image: image, scale: scale)
            self.openEditor(item: item, image: image, edits: nil, screen: screen, suggestedCrop: crop)
        }
        capture.onCancel = { [weak self] in self?.restoreFocusIfIdle() }

        hotKey.onTrigger = { [weak self] in self?.capture.start() }
        hotKey.start()
    }

    // MARK: Status menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(item(L("Take Screenshot"), "rectangle.dashed", #selector(menuCapture)))
        menu.addItem(item(L("Full Screen"), "display", #selector(menuCaptureFull)))
        menu.addItem(.separator())
        addHistoryItems(to: menu)
        menu.addItem(.separator())

        let hint = NSMenuItem(title: L("Hotkey: Right ⌘ + ⇧ + P"), action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        if !hotKey.isActive {
            menu.addItem(item(L("⚠︎ Grant Accessibility Access…"), nil, #selector(openAccessibility)))
        }
        if !CGPreflightScreenCaptureAccess() {
            menu.addItem(item(L("⚠︎ Grant Screen Recording Access…"), nil, #selector(openScreenRecording)))
        }

        menu.addItem(.separator())
        let login = item(L("Launch at Login"), nil, #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("Quit Inkshot"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func item(_ title: String, _ symbol: String?, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        if let symbol { i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return i
    }

    // Wait for the status menu to disappear before freezing the screen.
    @objc private func menuCapture() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.capture.start() }
    }

    @objc private func menuCaptureFull() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.capture.start(fullScreen: true) }
    }

    @objc private func openAccessibility() {
        hotKey.requestAccess()
        Permissions.openSettings(.accessibility)
    }

    @objc private func openScreenRecording() {
        CGRequestScreenCaptureAccess()
        Permissions.openSettings(.screenRecording)
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    // MARK: History

    private func addHistoryItems(to menu: NSMenu) {
        let recent = NSMenuItem(title: L("Recent"), action: nil, keyEquivalent: "")
        recent.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
        let sub = NSMenu()
        let latest = history.items.prefix(5)
        if latest.isEmpty {
            let empty = NSMenuItem(title: L("No screenshots yet"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            sub.addItem(empty)
        }
        for entry in latest {
            let title = entry.createdAt.formatted(date: .omitted, time: .shortened)
                + (entry.pinned ? "  📌" : "")
            let i = NSMenuItem(title: title, action: #selector(openRecent(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = entry.id
            i.image = history.thumbnail(entry).map { menuThumbnail($0) }
            sub.addItem(i)
        }
        recent.submenu = sub
        menu.addItem(recent)
        menu.addItem(item(L("Show History…"), "square.grid.2x2", #selector(showHistory)))
    }

    private func menuThumbnail(_ image: NSImage) -> NSImage {
        let box = CGSize(width: 64, height: 40)
        let k = min(box.width / image.size.width, box.height / image.size.height)
        let size = CGSize(width: image.size.width * k, height: image.size.height * k)
        return NSImage(size: size, flipped: false) { rect in
            image.draw(in: rect)
            return true
        }
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let entry = history.items.first(where: { $0.id == id }) else { return }
        openFromHistory(entry)
    }

    @objc private func showHistory() {
        if historyWindow == nil {
            let controller = HistoryWindowController(store: history) { [weak self] in self?.openFromHistory($0) }
            controller.onClose = { [weak self] in
                self?.historyWindow = nil
                self?.restoreFocusIfIdle()
            }
            historyWindow = controller
        }
        bringToFront(historyWindow)
    }

    private func openFromHistory(_ entry: HistoryItem) {
        if let open = editors.first(where: { $0.itemID == entry.id }) {
            return bringToFront(open)
        }
        guard let (image, edits) = history.loadForEditing(entry) else { return }
        history.copy(entry)
        openEditor(item: entry, image: image, edits: edits, screen: NSScreen.underMouse)
    }

    // MARK: Editors

    private func openEditor(item: HistoryItem, image: CGImage, edits: EditState?, screen: NSScreen?,
                            suggestedCrop: CGRect? = nil) {
        let editor = EditorWindowController(item: item, image: image, edits: edits, history: history,
                                            screen: screen, suggestedCrop: suggestedCrop)
        editor.onClose = { [weak self, weak editor] in
            guard let self, let editor else { return }
            self.editors.removeAll { $0 === editor }
            self.restoreFocusIfIdle()
        }
        editors.append(editor)
        bringToFront(editor)
    }

    private func bringToFront(_ controller: NSWindowController?) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        controller?.showWindow(nil)
        controller?.window?.makeKeyAndOrderFront(nil)
    }

    // Back to a menu-bar-only app and hand focus to whatever was in front before.
    private func restoreFocusIfIdle() {
        guard editors.isEmpty, historyWindow == nil else { return }
        NSApp.setActivationPolicy(.accessory)
        NSApp.hide(nil)
    }
}
