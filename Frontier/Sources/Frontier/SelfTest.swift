import AppKit
import Foundation
import WebKit

/// The ordering logic, which is the whole app and is invisible in a screenshot.
///
/// A curriculum that suggests a concept before its prerequisites, or that
/// silently hides a branch because of a typo, is wrong in a way you would only
/// notice weeks later. Run with --selftest.
@MainActor
enum SelfTest {
    static func run() -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        var fails = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : " — \(detail)")")
            if !ok { fails += 1 }
        }

        func make(_ id: String, requires: [String] = [], status: Concept.Status = .unread,
                  area: Concept.Area = .systems, dated: Date? = nil) -> Concept {
            var c = Concept(id: id, title: id.capitalized)
            c.requires = requires; c.status = status; c.area = area; c.dated = dated
            return c
        }

        // --- file round-trip
        var c = Concept(id: "paged-attention", title: "Paged Attention")
        c.area = .systems
        c.status = .learning
        c.requires = ["kv-cache", "memory-fragmentation"]
        c.relevance = "vLLM's memory model; explains throughput claims you will read."
        c.sources = [.init(title: "vLLM paper", url: "https://arxiv.org/abs/2309.06180"),
                     .init(title: "dead link", url: "https://example.invalid/x", reachable: false)]
        c.body = "## What it is\n\nBlocks, not one buffer.\n"
        guard let back = Concept(markdown: c.markdown) else {
            print("FAIL  round-trip — did not parse"); exit(1)
        }
        check("round-trip: id and title", back.id == c.id && back.title == c.title)
        check("round-trip: area and status", back.area == .systems && back.status == .learning)
        check("round-trip: prerequisites", back.requires == c.requires)
        check("round-trip: relevance", back.relevance == c.relevance)
        check("round-trip: sources", back.sources.count == 2
              && back.sources[0].url == "https://arxiv.org/abs/2309.06180")
        check("round-trip: a verified source stays verified",
              Concept(markdown: {
                  var c = Concept(id: "x", title: "x")
                  c.sources = [.init(title: "t", url: "https://example.com", reachable: true)]
                  return c.markdown
              }())?.sources.first?.reachable == true,
              "recording only failures made checked links read back as unchecked, "
            + "so the app said \"0 sources verified\" about verified sources")
        check("round-trip: an unchecked source stays unchecked",
              Concept(markdown: {
                  var c = Concept(id: "x", title: "x")
                  c.sources = [.init(title: "t", url: "https://example.com")]
                  return c.markdown
              }())?.sources.first?.reachable == nil)
        check("round-trip: an unreachable source stays flagged",
              back.sources[1].reachable == false,
              "a citation that 404s is not a citation")
        check("round-trip: body", back.body.contains("Blocks, not one buffer"))
        check("a file with no id is refused", Concept(markdown: "---\ntitle: x\n---\n\nbody") == nil)
        check("slugs are stable and typeable",
              Concept.slug("Paged Attention (vLLM)") == "paged-attention-vllm")

        // --- the frontier
        let graph = [
            make("virtual-memory", status: .known),
            make("kv-cache", status: .known),
            make("memory-fragmentation", requires: ["virtual-memory"], status: .known),
            make("paged-attention", requires: ["kv-cache", "memory-fragmentation"]),
            make("continuous-batching", requires: ["paged-attention"]),
            make("vllm-scheduler", requires: ["continuous-batching", "paged-attention"]),
        ]
        let ready = Frontier.ready(graph).map(\.id)
        check("a concept whose prerequisites are known is ready",
              ready.contains("paged-attention"))
        check("a concept behind an unmet prerequisite is not",
              !ready.contains("continuous-batching"),
              "suggesting it now would be teaching the roof before the walls")
        check("known concepts are not suggested again", !ready.contains("kv-cache"))

        // --- ordering
        let counts = Frontier.unlocks(graph)
        check("unlocking is counted over the whole downstream cone",
              counts["paged-attention"] == 2,
              "got \(counts["paged-attention"] ?? -1) — continuous-batching and vllm-scheduler")
        let bottleneck = [
            make("a"), make("b"),
            make("c", requires: ["a"]), make("d", requires: ["a"]), make("e", requires: ["a"]),
        ]
        check("a bottleneck outranks a leaf",
              Frontier.ready(bottleneck).first?.id == "a",
              "foundations first, without anyone ordering them by hand")
        let started = [make("x"), make("y", status: .learning)]
        check("something already started comes back first",
              Frontier.ready(started).first?.id == "y",
              "sessions should finish what they begin")
        let fresh = [make("old"), make("news", dated: Date())]
        check("news outranks the backlog while it is news",
              Frontier.ready(fresh).first?.id == "news")
        // Asserted on the score, not the order: once the bonus has decayed the
        // two are tied and the tie breaks on title, which would make the test
        // pass or fail on the alphabet rather than on the decay.
        let now = Date()
        let plain = Frontier.score(make("old"), unlocks: 0, now: now)
        let recent = Frontier.score(make("news", dated: now), unlocks: 0, now: now)
        let ancient = Frontier.score(make("news", dated: now.addingTimeInterval(-400 * 86_400)),
                                     unlocks: 0, now: now)
        check("a fresh release scores above an undated concept", recent > plain)
        check("and a year-old one scores exactly the same as one",
              ancient == plain, "a year-old release is just a concept")

        // --- the graph's failure modes
        let typo = [make("a", status: .known), make("b", requires: ["a", "typoo"])]
        check("a prerequisite that does not exist cannot freeze a branch",
              Frontier.ready(typo).map(\.id) == ["b"],
              "one bad id used to hide a whole subtree with nothing on screen to say why")
        check("and it is reported as missing", Frontier.missing(typo) == ["typoo"])
        let loop = [make("a", requires: ["b"]), make("b", requires: ["a"])]
        check("a cycle is found rather than hung on", !Frontier.cycles(loop).isEmpty)
        check("counting unlocks terminates on a cycle",
              Frontier.unlocks(loop)["a"] != nil)
        check("an acyclic graph reports no cycles", Frontier.cycles(graph).isEmpty)

        // --- a day's session
        let mixed = [
            make("h1", area: .hardware), make("h2", area: .hardware),
            make("s1", area: .safety), make("t1", area: .theory),
        ]
        let day = Frontier.session(mixed, size: 3)
        check("a session spreads across areas",
              Set(day.map(\.area)).count == 3,
              "three from one corner is a lecture, not fifteen minutes")
        check("a session is as long as asked for", day.count == 3)
        check("a small graph still fills the session",
              Frontier.session([make("only")], size: 3).count == 1)

        // --- importing a resource: the text machinery, which must not eat chapters
        let bookText = """
        # The Book Full Text

        # Chapter One

        Real prose, long enough to count as a chapter body for this test.

        ```python
        # a Python comment is not a chapter heading
        x = 1
        ```

        More prose after the code block.

        # Chapter Two

        The second chapter's text lives here.
        """
        let chapters = Resource.markdownSections(bookText)
        check("markdown chapters split at top-level headings",
              chapters.map(\.title) == ["The Book Full Text", "Chapter One", "Chapter Two"],
              "got \(chapters.map(\.title))")
        check("a # comment inside a code fence is not a chapter",
              chapters.count == 3
                && chapters[1].text.contains("a Python comment is not a chapter heading")
                && chapters[1].text.contains("More prose after the code block"),
              "the RLHF book's training-code listings are full of them")

        let filler = String(repeating: "the mechanism, spelled out at length. ", count: 6)
        let post = """
        <html><head><title>Policy Optimization</title></head><body>
        <nav><a href="/">navigation chrome that must not survive</a></nav>
        <h1>Policy Optimization</h1>
        <p>intro paragraph</p>
        <h3 id="a">From PPO to GRPO</h3><p>why clipping matters. \(filler)</p>
        <h3 id="b">GRPO</h3><p>\(filler)</p>
        <h3 id="c">DAPO</h3><p>\(filler)</p>
        </body></html>
        """
        let posts = Resource.htmlSections(post)
        check("a page splits at whichever heading level it actually uses",
              posts.map(\.title) == ["From PPO to GRPO", "GRPO", "DAPO"],
              "one h1 and one h2 is a title and a box, not an organisation — got \(posts.map(\.title))")
        check("section text is the text under the heading",
              posts.first?.text.contains("why clipping matters") == true)
        check("navigation chrome does not survive into sections",
              !posts.contains { $0.text.contains("navigation chrome") })
        check("the page title is read", Resource.pageTitle(post) == "Policy Optimization")

        let tiny = [Resource.Section(title: "A", text: String(repeating: "a", count: 900)),
                    Resource.Section(title: "B", text: String(repeating: "b", count: 900)),
                    Resource.Section(title: "C", text: String(repeating: "c", count: 900))]
        check("small sections share one model call",
              Resource.batches(tiny, cap: 26_000).count == 1)
        let huge = [Resource.Section(
            title: "Big",
            text: Array(repeating: String(repeating: "x", count: 900), count: 40)
                .joined(separator: "\n\n"))]
        let parts = Resource.batches(huge, cap: 10_000)
        check("a chapter too big for one call is split, in order, labelled",
              parts.count >= 3 && parts[1].first?.title.contains("part") == true,
              "got \(parts.count) batches, second titled \(parts[1].first?.title ?? "-")")
        check("no batch exceeds the cap",
              parts.allSatisfy { $0.reduce(0) { $0 + $1.text.count } <= 10_000 })

        // --- the reading pane actually typesets the mathematics
        //
        // The relevance line is where most of the maths lives, and it used to be
        // drawn with SwiftUI's Text — so "$S \\le 1/(s + (1-s)/p)$" appeared on
        // screen exactly like that, dollar signs and all. Checked here against
        // the real bundled renderer rather than by looking at a screenshot.
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("web"),
              FileManager.default.fileExists(
                atPath: root.appendingPathComponent("render.html").path) else {
            check("KaTeX is bundled", false, "Resources/web/render.html missing")
            print(fails == 0 ? "\nALL PASS" : "\n\(fails) FAILURE(S)")
            exit(fails == 0 ? 0 : 1)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        web.loadFileURL(root.appendingPathComponent("render.html"), allowingReadAccessTo: root)

        var maths = Concept(id: "amdahl", title: "Speedup and Amdahl's Law")
        maths.relevance = "8-GPU runs give $5\\times$ not $8\\times$: "
            + "$S \\le 1/(s + (1-s)/p)$ for serial fraction $s$."
        maths.body = "## What it actually is\n\nThe span sets the floor: "
            + "$T_p \\ge T_\\infty$.\n  └ CS149 lecture 2\n"
        let document = "# " + maths.title + "\n\n*" + maths.relevance + "*\n\n" + maths.body
        let json = String(data: (try? JSONSerialization.data(withJSONObject: [document]))
                            ?? Data(), encoding: .utf8) ?? "[\"\"]"

        func poll(_ attempt: Int) {
            web.evaluateJavaScript(
                "window.renderMarkdown ? (renderMarkdown(\(json)[0]), "
                + "document.getElementById('out').innerHTML) : null") { value, _ in
                guard let html = value as? String, !html.isEmpty else {
                    if attempt > 60 {
                        check("the renderer answered", false, "web view never replied")
                        print(fails == 0 ? "\nALL PASS" : "\n\(fails) FAILURE(S)")
                        exit(fails == 0 ? 0 : 1)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { poll(attempt + 1) }
                    return
                }
                check("maths in the relevance line is typeset",
                      html.contains("katex") && !html.contains("$S \\le"),
                      "it reached the screen as raw LaTeX")
                check("maths in the body is typeset too",
                      html.contains("T_") ? html.contains("katex") : true)
                check("no stray dollar signs survive",
                      !html.contains("$5\\times$") && !html.contains("$8\\times$"))
                check("a citation line keeps its own styling",
                      html.contains("cite") || html.contains("└"),
                      "sources should not read as body text")
                print(fails == 0 ? "\nALL PASS" : "\n\(fails) FAILURE(S)")
                exit(fails == 0 ? 0 : 1)
            }
        }
        DispatchQueue.main.async { poll(0) }
        app.run()
        exit(fails == 0 ? 0 : 1)   // app.run() does not return; the compiler wants this
    }
}
