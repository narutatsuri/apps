import AppKit
import SwiftUI
import WebKit

/// FRONTIER_WEBPROBE=1 — two bare NSWindows, each a WKWebView on render.html,
/// no SwiftUI anywhere. The reading pane builds a full DOM into a correctly
/// placed, visible view and paints nothing; this splits the suspects. If the
/// plain window paints and the app's pane does not, the fault is in the SwiftUI
/// hosting. If the drawsBackground window differs from the plain one, it is the
/// private KVC. If neither paints, WKWebView compositing is broken app-wide.
enum WebProbe {
    static var keep: [NSWindow] = []
    static var views: [WKWebView] = []

    static func scheduleIfAsked() {
        if ProcessInfo.processInfo.environment["FRONTIER_WEBPROBE"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { run() }
        }
        // FRONTIER_INJECT=1 — a WKWebView added to the *main window's* content
        // view by plain AppKit, no SwiftUI in the path. Paints → the window is
        // fine and SwiftUI's attachment is the break; blank → this window
        // cannot composite an out-of-process web layer at all.
        if ProcessInfo.processInfo.environment["FRONTIER_INJECT"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { inject() }
        }
    }

    private static func inject() {
        guard let window = NSApp.windows.first(where: { $0.isVisible }),
              let content = window.contentView,
              let html = Bundle.main.url(forResource: "render", withExtension: "html",
                                         subdirectory: "web") else {
            NSLog("INJECT no window or page"); return
        }
        let web = WKWebView(frame: NSRect(x: content.bounds.midX - 200,
                                          y: content.bounds.midY - 150,
                                          width: 400, height: 300))
        content.addSubview(web)
        web.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
        views.append(web)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            web.evaluateJavaScript(
                "renderMarkdown('# Injected probe\\n\\nAppKit subview of the main window. $x^2$'); 1"
            ) { _, error in
                NSLog("INJECT rendered%@", error.map { " error=\($0.localizedDescription)" } ?? "")
            }
        }
    }

    private static func run() {
        guard let html = Bundle.main.url(forResource: "render", withExtension: "html",
                                         subdirectory: "web") else {
            NSLog("PROBE render.html missing"); return
        }
        for (i, transparent) in [false, true].enumerated() {
            let win = NSWindow(contentRect: NSRect(x: 200 + i * 560, y: 300,
                                                   width: 520, height: 420),
                               styleMask: [.titled], backing: .buffered, defer: false)
            win.title = transparent ? "probe-transparent" : "probe-plain"
            let web = WKWebView(frame: win.contentView!.bounds)
            web.autoresizingMask = [.width, .height]
            if transparent { web.setValue(false, forKey: "drawsBackground") }
            win.contentView!.addSubview(web)
            web.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
            win.orderFrontRegardless()
            keep.append(win)
            views.append(web)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            for (i, web) in views.enumerated() {
                web.evaluateJavaScript(
                    "renderMarkdown('# Probe \(i)\\n\\nIf you can read this, this web view paints. $x^2$'); 1"
                ) { _, error in
                    NSLog("PROBE %d rendered%@", i,
                          error.map { " error=\($0.localizedDescription)" } ?? "")
                }
            }
        }

        // Probe 3: a bare window WITH a unified toolbar and full-size content —
        // the main window's dressing. The main window composites no web view at
        // all, even one added by plain AppKit; the undressed probes all paint.
        // If this one goes blank, the toolbar treatment is the discriminator.
        let dressed = NSWindow(contentRect: NSRect(x: 760, y: 760, width: 520, height: 420),
                               styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                               backing: .buffered, defer: false)
        dressed.title = "probe-toolbar"
        dressed.toolbarStyle = .unified
        dressed.toolbar = NSToolbar(identifier: "probe")
        let dweb = WKWebView(frame: dressed.contentView!.bounds)
        dweb.autoresizingMask = [.width, .height]
        dressed.contentView!.addSubview(dweb)
        dweb.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
        dressed.orderFrontRegardless()
        keep.append(dressed)
        views.append(dweb)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            dweb.evaluateJavaScript(
                "renderMarkdown('# Probe toolbar\\n\\nUnified toolbar window. $x^2$'); 1"
            ) { _, error in
                NSLog("PROBE toolbar rendered%@",
                      error.map { " error=\($0.localizedDescription)" } ?? "")
            }
        }

        // Probe 2: the app's own ConceptPreview — the SwiftUI representable —
        // in a bare hosting view, outside the NavigationSplitView. Splits
        // "the representable cannot paint under SwiftUI" from "the split
        // view's detail column cannot composite it".
        let win = NSWindow(contentRect: NSRect(x: 200, y: 760, width: 520, height: 420),
                           styleMask: [.titled], backing: .buffered, defer: false)
        win.title = "probe-swiftui"
        win.contentView = NSHostingView(rootView: ConceptPreview(
            markdown: "# Probe SwiftUI\n\nIf you can read this, the representable paints. $x^2$"))
        win.orderFrontRegardless()
        keep.append(win)
    }
}
