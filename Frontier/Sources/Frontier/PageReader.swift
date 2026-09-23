import AppKit
import WebKit

/// The text a browser actually shows for a page, rather than the text in the
/// HTML that was served.
///
/// Course pages increasingly ship a shell and build the schedule with
/// JavaScript. Stripping tags out of the served HTML then yields the navigation
/// and nothing else: measured, CMU 15-442 and 10-414 contributed 32–39 usable
/// lines against Stanford CS336's 130, so two of the six courses were barely
/// represented in a curriculum that claims to be their union. This loads the
/// page in a real WKWebView, lets its scripts run, and reads `innerText`.
///
/// "Let its scripts run" is not a fixed sleep: it polls, and stops when the text
/// has not grown for a while. A page that renders in 200 ms is not made to wait
/// three seconds, and a slow one is not cut off at one.
@MainActor
final class PageReader: NSObject {
    private let web: WKWebView
    private var completion: ((String?) -> Void)?
    private var best = ""
    private var stableTicks = 0
    private var deadline = Date.distantPast
    /// Readers in flight, so one is not deallocated mid-load.
    private static var live: Set<PageReader> = []

    private static let tick = 0.3
    /// Four quiet ticks — 1.2s — is "the page has stopped filling itself in".
    private static let quietTicksNeeded = 4

    override init() {
        let config = WKWebViewConfiguration()
        // Tall on purpose: a schedule table lazily rendered on scroll should be
        // inside the viewport from the start, since nothing here will scroll it.
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 4000),
                        configuration: config)
        web.customUserAgent = "Mozilla/5.0 (Macintosh) Frontier/1.0"
        super.init()
    }

    /// Main thread, run loop spinning (the app). The completion arrives later.
    static func read(_ url: URL, timeout: TimeInterval = 30,
                     completion: @escaping (String?) -> Void) {
        let reader = PageReader()
        live.insert(reader)
        reader.completion = { text in
            live.remove(reader)
            completion(text)
        }
        reader.deadline = Date().addingTimeInterval(timeout)
        reader.web.load(URLRequest(url: url, timeoutInterval: timeout))
        DispatchQueue.main.asyncAfter(deadline: .now() + tick) { reader.poll() }
    }

    /// Main thread, *no* run loop yet — a CLI command runs before
    /// `NSApplication.run`, so the web view would never make progress. Pump the
    /// run loop by hand until the read finishes.
    static func readPumping(_ url: URL, timeout: TimeInterval = 30) -> String? {
        _ = NSApplication.shared            // WebKit wants an app object to exist
        var out: String?
        var finished = false
        read(url, timeout: timeout) { out = $0; finished = true }
        let deadline = Date().addingTimeInterval(timeout + 5)
        while !finished, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return out
    }

    private func poll() {
        guard completion != nil else { return }
        if Date() >= deadline { finish(); return }
        web.evaluateJavaScript("document.body ? document.body.innerText : ''") { [weak self] value, _ in
            guard let self, self.completion != nil else { return }
            let text = (value as? String) ?? ""
            if text.count > self.best.count {
                self.best = text
                self.stableTicks = 0
            } else if !self.best.isEmpty {
                self.stableTicks += 1
            }
            if self.stableTicks >= Self.quietTicksNeeded { self.finish(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.tick) { self.poll() }
        }
    }

    private func finish() {
        let done = completion
        completion = nil
        // The web view is not reused; letting it go also stops its content process.
        web.stopLoading()
        done?(best.isEmpty ? nil : best)
    }
}
