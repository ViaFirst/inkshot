import AppKit

/// Main menu shown while an editor window is open. Its key equivalents (⌘Z, ⌘S, ⌘C…) travel the
/// responder chain, so the canvas and the text field both get the standard behaviour.
enum MainMenu {
    static func make() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("Hide PSE"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("Quit PSE"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(appMenu, title: "PSE", to: main)

        let file = NSMenu(title: L("File"))
        file.addItem(withTitle: L("Save…"), action: #selector(CanvasView.saveDocument(_:)), keyEquivalent: "s")
        file.addItem(withTitle: L("Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        add(file, title: L("File"), to: main)

        let edit = NSMenu(title: L("Edit"))
        edit.addItem(withTitle: L("Undo"), action: #selector(CanvasView.undo(_:)), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: L("Redo"), action: #selector(CanvasView.redo(_:)), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: L("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        add(edit, title: L("Edit"), to: main)

        return main
    }

    private static func add(_ submenu: NSMenu, title: String, to main: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        main.addItem(item)
    }
}
