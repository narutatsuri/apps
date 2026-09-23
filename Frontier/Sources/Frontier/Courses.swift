import Foundation

/// Syllabi from courses that already solved this problem.
///
/// The point is not to follow any one of them. Each is shaped by its own
/// department: CS149 and 15-418 teach parallel hardware to people who will write
/// CUDA, 6.5940 teaches efficiency to people shrinking models, CS336 teaches
/// building an LM end to end, and the ML-systems courses sit between. What this
/// reader needs is the union, ordered by dependency rather than by semester —
/// which is exactly what a graph can express and a syllabus cannot.
///
/// Fetched rather than hard-coded so the curriculum can be refreshed when the
/// courses are, and so the source of every claim about "what a course covers" is
/// a page you can open.
enum Courses {
    struct Course {
        var name: String
        var url: String
    }

    static let all: [Course] = [
        .init(name: "MIT 6.5940 — TinyML and Efficient Deep Learning Computing",
              url: "https://hanlab.mit.edu/courses/2024-fall-65940"),
        .init(name: "Stanford CS149 — Parallel Computing",
              url: "https://gfxcourses.stanford.edu/cs149/fall24"),
        .init(name: "CMU 15-418/618 — Parallel Computer Architecture and Programming",
              url: "https://www.cs.cmu.edu/~418/schedule.html"),
        .init(name: "CMU 10-414/714 — Deep Learning Systems",
              url: "https://dlsyscourse.org/lectures/"),
        // Not stanford-cs336.github.io: that now redirects to *http*
        // cs336.stanford.edu, and a cleartext redirect is refused by both
        // URLSession and WebKit under ATS — so the course that used to
        // contribute the most lines was silently contributing none. Caught by
        // `--courses`, which is why it prints per-course counts.
        .init(name: "Stanford CS336 — Language Modeling from Scratch",
              url: "https://cs336.stanford.edu/spring2025/"),
        // The schedule page, not the landing page. The landing page is a
        // paragraph about the course and a nav bar; it was never thin because
        // of JavaScript, it just did not contain a syllabus.
        .init(name: "CMU 15-442/642 — Machine Learning Systems",
              url: "https://mlsyscourse.org/schedule"),
    ]

    /// The readable text of a syllabus page, trimmed to the lines that look like
    /// topics. Crude on purpose: the model reads this, and a lecture list
    /// surrounded by navigation chrome is still a lecture list.
    ///
    /// Read two ways — the served HTML with its tags stripped, and the page as a
    /// real web view renders it (`PageReader`) — and the longer result wins.
    ///
    /// The rendering was added on the theory that these courses build their
    /// schedules with JavaScript. Measured, that is mostly not why they were
    /// thin: five of the six read better from the served HTML, and the course
    /// that was contributing *nothing* (CS336) was doing so because its URL had
    /// started redirecting to cleartext http. Rendering wins on exactly one page
    /// today. It is kept because it costs seconds against a model call that
    /// costs minutes, it cannot lose (the longer reading wins), and course sites
    /// are drifting towards script-built schedules — but it was not the fix.
    static func topics(of course: Course) -> [String] {
        guard let url = URL(string: course.url) else { return [] }
        // Whichever reading yields more, rather than a rule about which ought
        // to. Rendering was expected to win everywhere and does not: on a plain
        // HTML schedule, tag-stripping produces one line per element and beats
        // innerText's collapsed paragraphs (100 lines against 63 for MIT
        // 6.5940). It wins where the page is genuinely built by script. Since
        // both readings are cheap next to the model call that consumes them,
        // take both and keep the better one — which also means a page that
        // changes shape in either direction repairs itself.
        let rendered = renderedBody(url).map(topicLines) ?? []
        let raw = rawTopics(url)
        return rendered.count > raw.count ? rendered : raw
    }

    /// The rendered text, fetched on the main thread whichever thread asks.
    ///
    /// A WKWebView is main-thread only, and this is called from both a CLI
    /// command (main thread, before `NSApplication.run`, so nothing is pumping
    /// the run loop) and from the Extend-graph button's detached task (a
    /// background thread, with the app's run loop already spinning). Those need
    /// opposite treatment: pump it yourself, or wait for someone else to.
    private static func renderedBody(_ url: URL) -> String? {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { PageReader.readPumping(url) }
        }
        // Locked rather than a bare captured `var`: this thread gives up after
        // 40s and reads the result, and if the reader is late it writes at the
        // same moment on the main thread. The reader's own deadline is 30s so
        // that should not happen, and "should not happen" is not a memory model.
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                PageReader.read(url) { text in
                    box.set(text)
                    done.signal()
                }
            }
        }
        _ = done.wait(timeout: .now() + 40)
        return box.get()
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?
        func set(_ v: String?) { lock.lock(); value = v; lock.unlock() }
        func get() -> String? { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// Lines that could plausibly be a topic: long enough not to be a nav label,
    /// short enough not to be a paragraph, and each one only once.
    static func topicLines(_ text: String) -> [String] {
        var seen: Set<String> = []
        // Tabs as well as newlines: `innerText` renders a schedule table row as
        // one tab-separated line, so "3  Sep 12  Vectorisation and SIMD" arrives
        // as a single string that the length filter would then throw away.
        return text.components(separatedBy: CharacterSet(charactersIn: "\n\t"))
            .map { $0.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                     .trimmingCharacters(in: .whitespaces) }
            .filter { $0.count > 12 && $0.count < 120 && seen.insert($0).inserted }
    }

    /// Both readings separately, so `--courses` can show what each is worth
    /// rather than only the winner — a claim about an improvement is worth what
    /// its baseline is worth.
    static func bothReadings(_ course: Course) -> (raw: [String], rendered: [String]) {
        guard let url = URL(string: course.url) else { return ([], []) }
        return (rawTopics(url), renderedBody(url).map(topicLines) ?? [])
    }

    private static func rawTopics(_ url: URL) -> [String] {
        var request = URLRequest(url: url, timeoutInterval: 40)
        request.setValue("Mozilla/5.0 (Macintosh) Frontier/1.0", forHTTPHeaderField: "User-Agent")

        let done = DispatchSemaphore(value: 0)
        var body: String?
        URLSession.shared.dataTask(with: request) { data, _, _ in
            body = data.flatMap { String(data: $0, encoding: .utf8) }
            done.signal()
        }.resume()
        guard done.wait(timeout: .now() + 45) == .success, var text = body else { return [] }

        for pattern in ["<script[^>]*>[\\s\\S]*?</script>", "<style[^>]*>[\\s\\S]*?</style>"] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: "<[^>]+>", with: "\n", options: .regularExpression)
        return topicLines(text)
    }
}
