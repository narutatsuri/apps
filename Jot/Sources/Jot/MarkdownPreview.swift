import SwiftUI
import WebKit

/// Live markdown + LaTeX preview. KaTeX and marked are bundled into the app rather
/// than loaded from a CDN, so this renders with no network — which matters when the
/// point is to sit and read.
struct MarkdownPreview: NSViewRepresentable {
    let markdown: String
    /// The sticky's colour, so the rendered view sits on the same paper as the
    /// editor. Without it, toggling render flips the note to white and the
    /// colour stops being a usable label the moment you read a note.
    var paper: StickyColour = .yellow

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")   // let SwiftUI's surface show
        view.appearance = Theme.nsAppearance
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
        view.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.pending = markdown
        context.coordinator.palette = Self.palette()
        context.coordinator.flush(into: view)
    }

    /// The same colours the editor uses, in CSS. Handed over rather than left
    /// to a media query: this page sits on the sticky's paper, so it has to
    /// follow the app's theme and not the system's.
    static func palette() -> [String: String] {
        [
            "ink": Theme.css(Theme.ink),
            "ink-dim": Theme.css(Theme.dimmedInk(0.45)),
            "rule": Theme.css(Theme.dimmedInk(0.32)),
            "tint": Theme.css(Theme.codeTint),
            "tint-soft": Theme.css(Theme.codeTint.withAlphaComponent(
                Theme.codeTint.alphaComponent * 0.8)),
            "code-ink": Theme.css(Theme.codeInk),
            "link": Theme.css(Theme.linkInk),
            "scheme": Theme.current == .dark ? "dark" : "light",
        ]
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
        var palette: [String: String] = [:]
        private var ready = false
        private weak var view: WKWebView?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true
            view = webView
            flush(into: webView)
        }

        /// Held until the page has loaded, otherwise the first keystrokes are lost.
        func flush(into webView: WKWebView) {
            guard ready else { self.view = webView; return }
            let data = (try? JSONSerialization.data(withJSONObject: [pending])) ?? Data()
            let json = String(data: data, encoding: .utf8) ?? "[\"\"]"
            // The palette goes first, or the note is briefly drawn in the
            // stylesheet's defaults — a white flash on dark paper.
            if let vars = try? JSONSerialization.data(withJSONObject: palette),
               let text = String(data: vars, encoding: .utf8) {
                webView.evaluateJavaScript("window.applyTheme(\(text));")
            }
            // Passing through JSON avoids every quoting and newline hazard.
            webView.evaluateJavaScript("window.renderMarkdown(\(json)[0]);")
        }
    }
}
