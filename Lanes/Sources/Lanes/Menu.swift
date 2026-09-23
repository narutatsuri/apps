import AppKit

/// The application menu — the Format section is Jot's exactly, so ⌘B, ⌘I,
/// ⌘E, ⌘⇧H, ⌘⇧X and ⌘⇧M reach the column you are typing in through the
/// responder chain, the same selectors the shared editor implements.
enum MainMenu {
    static func install(target: AnyObject) {
        let menu = NSMenu()

        let appItem = NSMenuItem()
        let app = NSMenu()
        app.addItem(withTitle: "About Lanes",
                    action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                    keyEquivalent: "")
        app.addItem(.separator())
        add(to: app, "Open Lanes Folder", #selector(AppDelegate.menuFolder), target)
        app.addItem(.separator())
        add(to: app, "Quit Lanes", #selector(AppDelegate.menuQuit), target, "q")
        appItem.submenu = app
        menu.addItem(appItem)

        let fileItem = NSMenuItem()
        let file = NSMenu(title: "File")
        add(to: file, "New Lane", #selector(AppDelegate.menuNew), target, "n")
        file.addItem(.separator())
        // Rebuilt each time it opens, from whatever is in _vault/ right then.
        let restoreItem = NSMenuItem(title: "Restore from Vault", action: nil, keyEquivalent: "")
        let restore = NSMenu(title: "Restore from Vault")
        restore.delegate = target as? NSMenuDelegate
        restoreItem.submenu = restore
        file.addItem(restoreItem)
        add(to: file, "Open Vault Folder", #selector(AppDelegate.menuVaultFolder), target)
        file.addItem(.separator())
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)),
                     keyEquivalent: "w")
        fileItem.submenu = file
        menu.addItem(fileItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let plain = edit.addItem(withTitle: "Paste and Match Style",
                                 action: #selector(NSTextView.pasteAsPlainText(_:)),
                                 keyEquivalent: "v")
        plain.keyEquivalentModifierMask = [.command, .option, .shift]
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)),
                     keyEquivalent: "a")
        editItem.submenu = edit
        menu.addItem(editItem)

        let formatItem = NSMenuItem()
        let format = NSMenu(title: "Format")
        format.addItem(withTitle: "Bold", action: #selector(NSTextView.jotBold(_:)), keyEquivalent: "b")
        format.addItem(withTitle: "Italic", action: #selector(NSTextView.jotItalic(_:)), keyEquivalent: "i")
        let highlight = format.addItem(withTitle: "Highlight",
                                       action: #selector(NSTextView.jotHighlight(_:)), keyEquivalent: "h")
        highlight.keyEquivalentModifierMask = [.command, .shift]
        format.addItem(withTitle: "Code", action: #selector(NSTextView.jotCode(_:)), keyEquivalent: "e")
        let strike = format.addItem(withTitle: "Strikethrough",
                                    action: #selector(NSTextView.jotStrike(_:)), keyEquivalent: "x")
        strike.keyEquivalentModifierMask = [.command, .shift]
        format.addItem(.separator())
        let math = format.addItem(withTitle: "Math", action: #selector(NSTextView.jotMath(_:)),
                                  keyEquivalent: "m")
        math.keyEquivalentModifierMask = [.command, .shift]
        formatItem.submenu = format
        menu.addItem(formatItem)

        let viewItem = NSMenuItem()
        let view = NSMenu(title: "View")
        let dark = add(to: view, "Toggle Dark Mode", #selector(AppDelegate.menuToggleTheme), target, "d")
        dark.keyEquivalentModifierMask = [.command, .shift]
        viewItem.submenu = view
        menu.addItem(viewItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimise", action: #selector(NSWindow.performMiniaturize(_:)),
                       keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowItem.submenu = window
        menu.addItem(windowItem)

        NSApp.mainMenu = menu
    }

    @discardableResult
    private static func add(to menu: NSMenu, _ title: String, _ action: Selector,
                            _ target: AnyObject, _ key: String = "") -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = target
        return item
    }
}
