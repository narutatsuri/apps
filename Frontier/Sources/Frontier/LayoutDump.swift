import AppKit
import WebKit

/// FRONTIER_DUMP=1 — after the window exists, print where the web view and its
/// ancestors actually ended up, in window coordinates. The pane renders a full
/// DOM into a blank screen; whether the view is zero-sized, off-screen, or
/// covered is a question about frames, and frames are printable.
enum LayoutDump {
    static func scheduleIfAsked() {
        guard ProcessInfo.processInfo.environment["FRONTIER_DUMP"] == "1" else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            guard let window = NSApp.windows.first(where: { $0.isVisible }),
                  let content = window.contentView else {
                NSLog("DUMP no window"); return
            }
            NSLog("DUMP window content bounds: %@", "\(content.bounds)")
            describe(window, label: "main")
            walk(content, depth: 0, window: window)
        }
    }

    /// The window- and layer-level facts that could distinguish the one window
    /// where web content never composites from the ones where it always does.
    static func describe(_ window: NSWindow, label: String) {
        NSLog("DUMPW %@ class=%@ opaque=%d depth=%d sharing=%d collection=%d",
              label, String(describing: type(of: window)),
              window.isOpaque ? 1 : 0, window.depthLimit.rawValue,
              window.sharingType.rawValue, Int(window.collectionBehavior.rawValue))
        if let content = window.contentView {
            var chain: [String] = []
            var v: NSView? = content
            while let view = v {
                let l = view.layer
                chain.append(String(describing: type(of: view))
                    + "(layer=\(l == nil ? "nil" : String(describing: type(of: l!))),"
                    + "mask=\(l?.mask != nil ? 1 : 0),clip=\(l?.masksToBounds == true ? 1 : 0),"
                    + "r=\(l?.cornerRadius ?? 0),filters=\(l?.filters?.count ?? 0),"
                    + "comp=\(l?.compositingFilter != nil ? 1 : 0))")
                v = view.superview
            }
            NSLog("DUMPW %@ content-to-frame chain: %@", label, chain.joined(separator: " <- "))
            // And downward: every layer with a mask, filter, or clip under content.
            func scan(_ view: NSView, depth: Int) {
                if let l = view.layer,
                   l.mask != nil || l.compositingFilter != nil || (l.filters?.count ?? 0) > 0 {
                    NSLog("DUMPW %@ special layer at %@: %@ mask=%d filters=%d comp=%@",
                          label, String(describing: type(of: view)),
                          String(describing: type(of: l)),
                          l.mask != nil ? 1 : 0, l.filters?.count ?? 0,
                          String(describing: l.compositingFilter ?? "nil"))
                }
                for s in view.subviews where depth < 24 { scan(s, depth: depth + 1) }
            }
            scan(content, depth: 0)
        }
    }

    private static func walk(_ view: NSView, depth: Int, window: NSWindow) {
        guard depth < 24 else { return }
        for sub in view.subviews {
            let name = String(describing: type(of: sub))
            let inWindow = sub.convert(sub.bounds, to: nil)
            let interesting = sub is WKWebView || name.contains("Hosting")
                || name.contains("SplitView") || sub is NSScrollView
            if interesting {
                NSLog("DUMP %@%@  frame(window)=%@  hidden=%d alpha=%.2f",
                      String(repeating: "  ", count: depth), name,
                      "\(inWindow)", sub.isHiddenOrHasHiddenAncestor ? 1 : 0,
                      Float(sub.alphaValue))
            }
            walk(sub, depth: depth + 1, window: window)
        }
    }
}
