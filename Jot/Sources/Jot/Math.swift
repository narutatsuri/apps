import AppKit
import WebKit

/// Typesets `$x+y=1$` into something you can actually read.
///
/// KaTeX in an offscreen web view, snapshotted to an image that goes into the
/// text as an attachment. There is no native TeX layout on macOS, and the
/// alternatives are worse: styling the source differently is not rendering it,
/// and shelling out to a TeX distribution would put a 4GB dependency behind a
/// scratch-notes app. KaTeX is already bundled for the rendered view, so this
/// costs nothing extra on disk.
///
/// Rendering is asynchronous — the web view has to lay the equation out before
/// it can be measured — so callers get a cached image or nothing, and are told
/// when one arrives. The cache is what makes typing next to an equation cheap:
/// the same TeX is only ever rendered once per colour and size.
@MainActor
final class MathRenderer: NSObject {
    static let shared = MathRenderer()

    /// Posted when a new equation finishes rendering, so open notes can pick it
    /// up without rebuilding their text and losing the caret.
    static let didRender = Notification.Name("jot.math.didRender")

    struct Rendered {
        var image: NSImage
        /// How far below the text baseline the image hangs.
        var descent: CGFloat
    }

    private struct Key: Hashable {
        var tex: String
        var display: Bool
        var size: CGFloat
        var ink: String
        var paper: String
    }

    private var web: WKWebView?
    private var isLoaded = false
    private var waiting: [() -> Void] = []
    private var cache: [Key: Rendered] = [:]
    private var inFlight: Set<Key> = []
    /// Renders run one at a time. There is a single web view with a single
    /// element in it, and both steps of a render — typeset, then capture — are
    /// asynchronous, so two overlapping renders race on the same DOM: the
    /// second equation overwrites the first before the first is captured, and
    /// the first equation ends up wearing the second one's picture, squashed
    /// into its own measured size. Every equation looked plausible; two of them
    /// were the same one.
    private var queue: [Key] = []
    private var isRendering = false
    /// Rendered to PDF rather than snapshotted to a bitmap. takeSnapshot on a
    /// web view that is not on screen returns a correctly sized blank image —
    /// it passes every check except looking at it — because nothing ever paints.
    /// createPDF draws from the render tree instead, so it works offscreen, and
    /// the result is vector: crisp at any scale, with no oversampling to undo.

    /// The cached rendering, or nil — in which case one is started and
    /// `didRender` will be posted when it lands.
    func rendering(tex: String, display: Bool, size: CGFloat,
                   ink: NSColor, paper: NSColor) -> Rendered? {
        let key = Key(tex: tex, display: display, size: size,
                      ink: Self.css(ink), paper: Self.css(paper))
        if let hit = cache[key] { return hit }
        guard !inFlight.contains(key) else { return nil }
        inFlight.insert(key)
        queue.append(key)
        whenLoaded { [weak self] in self?.pump() }
        return nil
    }

    private func start() {
        isLoaded = true
        let queued = waiting
        waiting = []
        for body in queued { body() }
    }

    private func pump() {
        guard !isRendering, !queue.isEmpty else { return }
        isRendering = true
        let key = queue.removeFirst()
        render(key) { [weak self] in
            guard let self else { return }
            self.isRendering = false
            self.pump()
        }
    }

    // MARK: - The web view

    private func whenLoaded(_ body: @escaping () -> Void) {
        if isLoaded { body(); return }
        waiting.append(body)
        guard web == nil else { return }

        guard let root = Bundle.main.resourceURL?.appendingPathComponent("web") else { return }
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 2400, height: 1200))
        view.navigationDelegate = self
        // Snapshots of a view that has never been in a window come back blank on
        // some macOS versions. An offscreen window costs nothing and is never
        // ordered front, so it cannot steal focus.
        let host = NSWindow(contentRect: view.frame, styleMask: [.borderless],
                            backing: .buffered, defer: false)
        host.contentView?.addSubview(view)
        host.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        host.orderBack(nil)
        holder = host
        web = view
        view.loadFileURL(root.appendingPathComponent("math.html"), allowingReadAccessTo: root)
    }

    private var holder: NSWindow?

    private func render(_ key: Key, _ done: @escaping () -> Void) {
        guard let web else { done(); return }
        // callAsyncJavaScript, not evaluateJavaScript, because it awaits the
        // promise: the fonts have to have arrived before the equation is
        // measured or captured. Arguments are passed as values rather than
        // interpolated into source — TeX is nothing but backslashes and quotes.
        let script = """
            place(tex, display, px, colour, background);
            await document.fonts.ready;
            return measure();
            """
        let arguments: [String: Any] = [
            "tex": key.tex, "display": key.display, "px": key.size,
            "colour": key.ink, "background": key.paper,
        ]

        web.callAsyncJavaScript(script, arguments: arguments, in: nil,
                                in: .page) { [weak self] result in
            guard let self else { return }
            let value = try? result.get()
            guard let json = value as? String,
                  let data = json.data(using: .utf8),
                  let box = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let w = box["w"] as? Double, let h = box["h"] as? Double,
                  let baseline = box["baseline"] as? Double else {
                self.inFlight.remove(key)
                done()
                return
            }

            // The web view is deliberately oversized for measuring, and the
            // equation sits at its top-left. Rather than reason about whether a
            // capture rect is measured from the top or the bottom — get it
            // wrong and the PDF is a perfectly sized picture of empty page —
            // shrink the view to the equation and capture all of it.
            web.frame = NSRect(x: 0, y: 0, width: w, height: h)
            web.layoutSubtreeIfNeeded()
            let config = WKPDFConfiguration()
            web.createPDF(configuration: config) { result in
                self.inFlight.remove(key)
                web.frame = NSRect(x: 0, y: 0, width: 2400, height: 1200)
                defer { done() }
                if let dump = ProcessInfo.processInfo.environment["JOT_MATH_DUMP"],
                   case .success(let raw) = result {
                    try? raw.write(to: URL(fileURLWithPath: dump))
                }
                guard case .success(let data) = result,
                      let image = NSImage(data: data), image.size.width > 0 else { return }
                image.size = NSSize(width: w, height: h)
                // Display maths sits on its own line, so it wants no descent;
                // inline maths hangs below the baseline by whatever KaTeX put
                // there, or subscripts would sit on top of the next line.
                let descent = key.display ? 0 : max(0, h - baseline)
                self.cache[key] = Rendered(image: image, descent: descent)
                NotificationCenter.default.post(name: Self.didRender, object: nil)
            }
        }
    }

    private static func css(_ colour: NSColor) -> String {
        let c = colour.usingColorSpace(.sRGB) ?? colour
        return String(format: "#%02x%02x%02x", Int(c.redComponent * 255),
                      Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}

extension MathRenderer: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            // Loaded is not the same as ready: the fonts come after the page,
            // and an equation captured before them is missing glyphs.
            webView.callAsyncJavaScript("return await warm();", arguments: [:], in: nil,
                                        in: .page) { [weak self] _ in
                Task { @MainActor in self?.start() }
            }
        }
    }
}
