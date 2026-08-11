import SwiftUI
import WebKit

/// FRONTIER_WEBLOG=1 — narrates the preview's load-and-render pipeline to
/// stderr, because a blank pane has half a dozen distinct causes (load never
/// finished, load failed, JS threw, DOM filled but view invisible) that all
/// look identical from the outside.
func weblog(_ message: @autoclosure () -> String) {
    if ProcessInfo.processInfo.environment["FRONTIER_WEBLOG"] == "1" {
        NSLog("WEB %@", message())
    }
}

/// Live markdown + LaTeX preview. KaTeX and marked are bundled into the app rather
/// than loaded from a CDN, so this renders with no network — which matters when the
/// point is to sit and read.
///
/// The extra hosting level is load-bearing, chosen by measurement rather than
/// taste. In this window's NavigationSplitView detail column, a WKWebView
/// hosted by SwiftUI goes blank while everything measurable says it should
/// not: the DOM holds the full document (FRONTIER_WEBLOG), the layout dump
/// puts the view at exactly the pane's frame, visible, alpha 1 — and the pane
/// paints nothing, not even dark-on-dark (pixel-checked). The same web view
/// in a bare NSWindow paints (FRONTIER_WEBPROBE probes 0 and 1), and the same
/// representable under a bare NSHostingView paints (probe 2). Only the split
/// view's detail fails to composite it. So the split view is handed an
/// NSHostingView — a view it composites correctly — and the web view lives
/// one hosting level down, where it demonstrably paints.
struct ConceptPreview: NSViewRepresentable {
    let markdown: String

    func makeNSView(context: Context) -> NSHostingView<WebPane> {
        NSHostingView(rootView: WebPane(markdown: markdown))
    }

    func updateNSView(_ view: NSHostingView<WebPane>, context: Context) {
        view.rootView = WebPane(markdown: markdown)
    }

    func sizeThatFits(_ proposal: ProposedViewSize,
                      nsView: NSHostingView<WebPane>,
                      context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 320, height: proposal.height ?? 320)
    }
}

/// The actual web view, one hosting level down.
struct WebPane: NSViewRepresentable {
    let markdown: String

    /// Keeps its one subview at its own size through real layout, because an
    /// autoresizing mask applied to a view that started at 0×0 multiplies
    /// zeros and leaves the subview at 0×0 forever.
    final class FillContainer: NSView {
        override func layout() {
            super.layout()
            subviews.first?.frame = bounds
        }
    }

    func makeNSView(context: Context) -> NSView {
        let container = FillContainer()
        let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        view.navigationDelegate = context.coordinator
        // FRONTIER_OPAQUE=1 keeps the web view's own background, to test whether
        // the transparent-over-material arrangement is what fails to composite.
        if ProcessInfo.processInfo.environment["FRONTIER_OPAQUE"] != "1" {
            view.setValue(false, forKey: "drawsBackground")   // let SwiftUI's surface show
        }
        view.allowsMagnification = false
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        context.coordinator.webView = view

        guard let html = Bundle.main.url(forResource: "render", withExtension: "html",
                                         subdirectory: "web")
            ?? Bundle.main.url(forResource: "render", withExtension: "html") else {
            view.loadHTMLString("<p>render.html missing from the bundle</p>", baseURL: nil)
            return container
        }
        // Read access to the enclosing directory, so katex.min.js and the fonts resolve.
        context.coordinator.page = html
        view.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard let view = context.coordinator.webView else { return }
        view.frame = container.bounds
        weblog("update: container=\(container.frame) web=\(view.frame) markdown=\(markdown.count) chars")
        context.coordinator.pending = markdown
        context.coordinator.flush(into: view)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var pending: String = ""
        var page: URL?
        weak var webView: WKWebView?
        private var ready = false
        private weak var view: WKWebView?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            weblog("didFinish — flushing \(pending.count) pending chars")
            ready = true
            view = webView
            flush(into: webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                     withError error: Error) {
            weblog("didFail: \(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            weblog("didFailProvisional: \(error.localizedDescription)")
        }

        /// WebKit's content process can die out from under the view — under
        /// memory pressure, or a GPU hiccup — and what that looks like on
        /// screen is the reading pane going permanently, silently blank.
        /// Reload the page; didFinish then replays the pending document.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            ready = false
            guard let page else { return }
            webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        }

        /// Held until the page has loaded, otherwise the first keystrokes are lost.
        func flush(into webView: WKWebView) {
            guard ready else { self.view = webView; return }
            // "└ NVIDIA whitepaper" lines are citations, not prose. Marked up
            // here rather than in the stylesheet, because only this side knows
            // that a line beginning with └ means "where the claim above came
            // from" — and a citation set in body text reads as an afterthought.
            let marked = pending.components(separatedBy: "\n").map { line -> String in
                let t = line.trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix("└") else { return line }
                return "<div class=\"cite\">" + t + "</div>"
            }.joined(separator: "\n")
            let data = (try? JSONSerialization.data(withJSONObject: [marked])) ?? Data()
            let json = String(data: data, encoding: .utf8) ?? "[\"\"]"
            // Passing through JSON avoids every quoting and newline hazard. The
            // trailing expression hands back the rendered length, so a failure
            // has an error and a success has a number — a blank pane stops
            // being indistinguishable from a successful render of nothing.
            webView.evaluateJavaScript(
                "window.renderMarkdown(\(json)[0]); document.getElementById('out').innerHTML.length"
            ) { value, error in
                weblog("render: out=\((value as? Int).map(String.init) ?? "nil") chars"
                       + (error.map { " error=\($0.localizedDescription)" } ?? ""))
            }
        }
    }
}
