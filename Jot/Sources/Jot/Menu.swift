import AppKit

/// The application menu.
///
/// Required, not decorative. On macOS the standard editing shortcuts — ⌘C, ⌘V,
/// ⌘X, ⌘Z, ⌘A — reach a text view by way of the main menu: `NSTextView`
/// implements `copy:` and `paste:`, but something has to turn the keystroke
/// into that selector, and that something is a menu item carrying the key
/// equivalent. This app is `LSUIElement` and never draws a menu bar, which is
/// how the menu came to be missing, and copy and paste silently did nothing.
/// An invisible menu still answers key equivalents, so the fix is to build one
/// anyway and never show it.
enum MainMenu {
    /// `target` receives the app-level items; the editing and format items go
    /// to the first responder, which is whichever note you are typing in.
    static func install(target: AnyObject) {
        let menu = NSMenu()

        // The first item's submenu is always treated as the app menu.
        let appItem = NSMenuItem()
        let app = NSMenu()
        app.addItem(withTitle: "About Jot",
                    action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                    keyEquivalent: "")
        app.addItem(.separator())
        add(to: app, "Open ~/jot", #selector(AppDelegate.menuFolder), target)
        app.addItem(.separator())
        add(to: app, "Quit Jot", #selector(AppDelegate.menuQuit), target, "q")
        appItem.submenu = app
        menu.addItem(appItem)

        let fileItem = NSMenuItem()
        let file = NSMenu(title: "File")
        add(to: file, "New Note", #selector(AppDelegate.menuNew), target, "n")
        file.addItem(withTitle: "Close Note", action: #selector(NSWindow.performClose(_:)),
                     keyEquivalent: "w")
        file.addItem(.separator())
        // No key equivalent: ⌃⌥S already does this from anywhere, and ⌘S in a
        // text field should not mean "hide my notes".
        add(to: file, "Show / Hide All", #selector(AppDelegate.menuToggle), target)
        fileItem.submenu = file
        menu.addItem(fileItem)

        // Edit — the reason this file exists.
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        // Everything here is plain text already, but the muscle memory is real.
        let plain = edit.addItem(withTitle: "Paste and Match Style",
                                 action: #selector(NSTextView.pasteAsPlainText(_:)),
                                 keyEquivalent: "v")
        plain.keyEquivalentModifierMask = [.command, .option, .shift]
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)),
                     keyEquivalent: "a")
        editItem.submenu = edit
        menu.addItem(editItem)

        // Format — writes markdown into the text rather than styling the note.
        let formatItem = NSMenuItem()
        let format = NSMenu(title: "Format")
        format.addItem(withTitle: "Bold", action: #selector(NSTextView.jotBold(_:)),
                       keyEquivalent: "b")
        format.addItem(withTitle: "Italic", action: #selector(NSTextView.jotItalic(_:)),
                       keyEquivalent: "i")
        let highlight = format.addItem(withTitle: "Highlight",
                                       action: #selector(NSTextView.jotHighlight(_:)),
                                       keyEquivalent: "h")
        highlight.keyEquivalentModifierMask = [.command, .shift]
        format.addItem(withTitle: "Code", action: #selector(NSTextView.jotCode(_:)),
                       keyEquivalent: "e")
        let strike = format.addItem(withTitle: "Strikethrough",
                                    action: #selector(NSTextView.jotStrike(_:)),
                                    keyEquivalent: "x")
        strike.keyEquivalentModifierMask = [.command, .shift]
        format.addItem(.separator())
        let math = format.addItem(withTitle: "Math", action: #selector(NSTextView.jotMath(_:)),
                                  keyEquivalent: "m")
        math.keyEquivalentModifierMask = [.command, .shift]
        formatItem.submenu = format
        menu.addItem(formatItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimise", action: #selector(NSWindow.performMiniaturize(_:)),
                       keyEquivalent: "m")
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
