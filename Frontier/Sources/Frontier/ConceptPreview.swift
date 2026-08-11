import SwiftUI
import WebKit

/// Live markdown + LaTeX preview. KaTeX and marked are bundled into the app rather
/// than loaded from a CDN, so this renders with no network — which matters when the
/// point is to sit and read.
struct ConceptPreview: NSViewRepresentable {
    let markdown: String

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")   // let SwiftUI's surface show
        view.allowsMagnification = false
        // Belt and braces alongside sizeThatFits: never push back against the size
        // the layout wants to give.
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        guard let html = Bundle.main.url(forResource: "render", withExtension: "html",
                                         subdirectory: "web")
            ?? Bundle.main.url(forResource: "render", withExtension: "html") else {
            view.loadHTMLString("<p>render.html missing from the bundle</p>", baseURL: nil)
            return view
        }
        // Read access to the enclosing directory, so katex.min.js and the fonts resolve.
        context.coordinator.page = html
        view.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.pending = markdown
        context.coordinator.flush(into: view)
    }

    /// Accept whatever size the layout offers instead of reporting the rendered
    /// document's height.
    ///
    /// Without this, WKWebView answers with its full content height — measured at
    /// 1583pt inside an 858pt window. The enclosing HStack adopted that, so the
    /// editor and preview were both ~1570pt tall and centred, putting roughly 350pt
    /// off the top of the window and 350pt off the bottom. Enlarging the window
    /// revealed more of it, which is exactly how the bug presented.
    func sizeThatFits(_ proposal: ProposedViewSize,
                      nsView: WKWebView,
                      context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 320, height: proposal.height ?? 320)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var pending: String = ""
        var page: URL?
        private var ready = false
        private weak var view: WKWebView?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true
            view = webView
            flush(into: webView)
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
            // Passing through JSON avoids every quoting and newline hazard.
            webView.evaluateJavaScript("window.renderMarkdown(\(json)[0]);")
        }
    }
}
