import AppKit

/// Main menu shown while an editor window is open. Its key equivalents (⌘Z, ⌘S, ⌘C…) travel the
/// responder chain, so the canvas and the text field both get the standard behaviour.
enum MainMenu {
    static func make() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Скрыть PSE", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Выйти из PSE", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(appMenu, title: "PSE", to: main)

        let file = NSMenu(title: "Файл")
        file.addItem(withTitle: "Сохранить…", action: #selector(CanvasView.saveDocument(_:)), keyEquivalent: "s")
        file.addItem(withTitle: "Закрыть", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        add(file, title: "Файл", to: main)

        let edit = NSMenu(title: "Правка")
        edit.addItem(withTitle: "Отменить", action: #selector(CanvasView.undo(_:)), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Повторить", action: #selector(CanvasView.redo(_:)), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Вырезать", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Копировать", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Вставить", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Выбрать всё", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        add(edit, title: "Правка", to: main)

        return main
    }

    private static func add(_ submenu: NSMenu, title: String, to main: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        main.addItem(item)
    }
}
