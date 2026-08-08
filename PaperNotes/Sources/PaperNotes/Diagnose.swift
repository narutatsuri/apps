import AppKit

/// `PN_DUMP=1` — after the window exists, print where things actually ended up.
///
/// ImageRenderer cannot draw NavigationSplitView, so a layout fault in the wrapper is
/// invisible offscreen. This reads the live view tree instead: if a subview's frame
/// sits above the content view's bounds, that is content pushed off the top, measured
/// rather than guessed at.
enum Diagnose {
    /// PN_WINDOWS=1 prints the window inventory the reopen handler sees. Added
    /// because "clicking the Dock icon sometimes does nothing" is a claim about
    /// which NSWindow that handler picks, and guessing at it is how the handler
    /// got written wrong in the first place.
    static func scheduleWindowDump() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            print("NSApp.windows — \(NSApp.windows.count)")
            for w in NSApp.windows {
                print("  id=\(w.identifier?.rawValue ?? "nil")"
                      + "  title=\(w.title.isEmpty ? "(none)" : w.title)"
                      + "  canBecomeMain=\(w.canBecomeMain)"
                      + "  visible=\(w.isVisible)  mini=\(w.isMiniaturized)"
                      + "  class=\(type(of: w))")
            }
            print("\nreopen handler would pick: "
                  + (AppDelegate.mainWindow().map {
                        "id=\($0.identifier?.rawValue ?? "nil") title=\($0.title)"
                     } ?? "nothing — falls through to SwiftUI's own restore"))
            // Open the graph window through its own menu item, then compare what
            // the old selector picks against what the new one does. This is the
            // actual hypothesis: both auxiliary scenes can become main.
            func item(_ title: String) -> NSMenuItem? {
                for top in NSApp.mainMenu?.items ?? [] {
                    if let hit = top.submenu?.items.first(where: { $0.title == title }) { return hit }
                }
                return nil
            }
            guard let graph = item("Citation Graph") else {
                print("no Citation Graph menu item — cannot test"); exit(1)
            }
            _ = graph.menu?.performActionForItem(at: graph.menu!.index(of: graph))

            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                print("\nwith the graph window open — \(NSApp.windows.count) windows")
                for w in NSApp.windows where w.isVisible {
                    print("  id=\(w.identifier?.rawValue ?? "nil")  title=\(w.title)"
                          + "  canBecomeMain=\(w.canBecomeMain)")
                }
                let oldPick = NSApp.windows.first(where: { $0.canBecomeMain })
                print("\nold selector picks: \(oldPick?.title ?? "nothing")"
                      + "  (id=\(oldPick?.identifier?.rawValue ?? "nil"))")
                print("new selector picks: \(AppDelegate.mainWindow()?.title ?? "nothing")"
                      + "  (id=\(AppDelegate.mainWindow()?.identifier?.rawValue ?? "nil"))")

                // Now close the notes window and leave the graph up — the state a
                // Dock click has to recover from.
                AppDelegate.mainWindow()?.close()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    print("\nnotes window closed — \(NSApp.windows.filter(\.isVisible).count) visible")
                    let old2 = NSApp.windows.first(where: { $0.canBecomeMain })
                    print("old selector picks: \(old2?.title ?? "nothing")"
                          + "  -> handled=\(old2 != nil), so SwiftUI never restores the notes window")
                    let new2 = AppDelegate.mainWindow()
                    print("new selector picks: \(new2?.title ?? "nothing")"
                          + "  visible=\(new2?.isVisible ?? false)")
                    // Run the new handler for real and see whether the notes
                    // window actually comes back on screen.
                    if let w = new2 {
                        if w.isMiniaturized { w.deminiaturize(nil) }
                        w.makeKeyAndOrderFront(nil)
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        let w = AppDelegate.mainWindow()
                        print("after the new handler runs: notes window visible="
                              + "\(w?.isVisible ?? false)  key=\(w?.isKeyWindow ?? false)")
                        exit(0)
                    }
                }
            }
        }
    }

    static func scheduleDump() {
        // Select a paper first, or the detail pane shows the placeholder and the
        // editor never exists to be measured.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            MainActor.assumeIsolated {
                let model = AppModel.shared
                if let first = model.papers.first { model.select(first.arxivID) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
                  let content = window.contentView else {
                print("no window"); exit(1)
            }
            print("window frame:      \(fmt(window.frame))")
            print("contentView bounds:\(fmt(content.bounds))")
            print("contentLayoutRect: \(fmt(window.contentLayoutRect))")
            print("")
            walk(content, depth: 0, containerHeight: content.bounds.height)
            exit(0)
        }
    }

    private static func fmt(_ r: CGRect) -> String {
        String(format: " x=%.0f y=%.0f w=%.0f h=%.0f", r.origin.x, r.origin.y, r.width, r.height)
    }

    private static func walk(_ view: NSView, depth: Int, containerHeight: CGFloat) {
        guard depth < 20 else { return }
        for sub in view.subviews {
            let f = sub.frame
            let name = String(describing: type(of: sub))
            // Only the containers that carry actual content — scroll views, hosting
            // views, and the list — say anything about where the top edge landed.
            let interesting = name.contains("TextView") || name.contains("WKWebView")
                || name.contains("CoreHostingView")
            if let scroll = sub as? NSScrollView, f.height > 40 {
                // A scroll view's *own* frame is what is visible; its document view
                // being taller is just scrolling, not a layout fault. Measuring the
                // document view is what sent me chasing a phantom.
                // frame is in the superview's space; convert *that*. Converting
                // bounds from inside a scrolled hierarchy yields document space,
                // which produced a 1817pt height in a 910pt window.
                let inWindow = scroll.frame
                let parentH = scroll.superview?.bounds.height ?? 0
                let top = inWindow.origin.y + inWindow.height
                let underTitlebar = top > parentH + 1
                print(String(repeating: "  ", count: depth)
                      + "\(name.prefix(34))\(fmt(inWindow))"
                      + " inset.top=\(Int(scroll.contentInsets.top)) parentH=\(Int(scroll.superview?.bounds.height ?? 0))"
                      + (underTitlebar ? "   <-- TOP UNDER TITLEBAR" : ""))
            }
            if interesting, f.width > 40, f.height > 40 {
                // Converted into the window so the numbers are comparable to
                // contentLayoutRect rather than to whatever parent they sit in.
                let inWindow = sub.frame
                print(String(repeating: "  ", count: depth)
                      + "\(name.prefix(46))\(fmt(inWindow))")
            }
            walk(sub, depth: depth + 1, containerHeight: sub.bounds.height)
        }
    }
}
