import Foundation
import CoreGraphics

/// Exercises the parts that would fail silently: the markdown round-trip (a lossy
/// one would quietly eat your notes) and the citation graph (an empty one would look
/// like "no connections yet" rather than a bug). Run with --selftest.
enum SelfTest {
    @MainActor
    static func run() -> Never {
        // A private library for the whole run, set before anything touches
        // `Library.root` (which is lazy, and nothing touches it earlier than
        // this). The draft-loss probes below drive the real select/save path,
        // and that path must never write into — or commit to — the actual
        // notes repo. The temp folder is not a git repo, so the commit half of
        // a save fails harmlessly there.
        let tempLibrary = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pn-selftest-\(getpid())")
        setenv("PN_LIBROOT", tempLibrary.path, 1)

        var fails = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : " — \(detail)")")
            if !ok { fails += 1 }
        }

        // --- markdown round-trip
        var p = Paper(arxivID: "2510.23966")
        p.title = "A Pragmatic Way to Measure Chain-of-Thought Monitorability"
        p.authors = ["Emmons, Scott", "Zimmermann, Roland S."]
        p.year = 2025
        p.venue = "arXiv"
        p.readOn = Date(timeIntervalSince1970: 1_785_000_000)
        p.verdict = .solid
        p.tags = ["cot", "monitoring"]
        p.refs = ["2401.05566", "2312.06942"]
        p.pdfPath = "/tmp/example.pdf"
        // Deliberately exercises the characters that break naive round-trips:
        // math delimiters, backslashes, underscores and a blank line.
        p.body = """
        ## Claim, in my words

        Monitorability is measurable without assuming faithfulness, since
        $p(\\text{catch}) \\ge 1 - \\epsilon_{\\text{miss}}$ holds regardless.

        $$
        \\mathcal{L} = \\sum_{i=1}^{n} w_i \\log q_i
        $$

        ## What I didn't understand

        Why the proxy correlates at all.
        """

        guard let back = Paper(markdown: p.markdown) else {
            print("FAIL  markdown round-trip — did not parse at all"); exit(1)
        }
        check("round-trip: identity", back.arxivID == p.arxivID && back.title == p.title)
        check("round-trip: metadata",
              back.year == p.year && back.venue == p.venue && back.verdict == p.verdict,
              "year/venue/verdict")
        check("round-trip: lists",
              back.authors == p.authors && back.tags == p.tags && back.refs == p.refs,
              "\(back.authors.count) authors, \(back.refs.count) refs")
        check("round-trip: body byte-identical", back.body == p.body,
              "LaTeX, backslashes and blank lines all survive")
        check("round-trip: sections still parse",
              back.confusions == "Why the proxy correlates at all.",
              "headings still locate their text")
        check("round-trip: pdf path", back.pdfPath == p.pdfPath)

        // --- project tags
        //
        // The tag is a name in the paper's own frontmatter; projects.txt only
        // supplies its colour. So the field has to survive the file round-trip,
        // and an untagged paper must write no field at all — every note made
        // before this existed still round-trips byte-identically.
        var tagged = Paper(arxivID: "2507.14805")
        tagged.project = "CoT monitorability"
        check("round-trip: project survives",
              Paper(markdown: tagged.markdown)?.project == "CoT monitorability")
        check("an untagged paper carries no project field",
              !Paper(arxivID: "2507.14805").markdown.contains("project:"),
              "by default papers need no tag — the field exists only when set")
        check("absent means untagged", back.project.isEmpty)

        // --- the project registry
        let registry = Projects.parse("""
        # a comment, and a blank line below

        blue CoT monitorability
        Reasoning Robustness
        teal Self-improvement
        BLUE cot MONITORABILITY
        """)
        check("a colour word starts a line", registry.first?.colour == .blue
              && registry.first?.name == "CoT monitorability")
        check("a hand-written line without a colour is still a project",
              registry.count > 1 && registry[1].name == "Reasoning Robustness",
              "a registry that drops entries over a missing colour word loses "
            + "the projects it exists to keep")
        check("and it takes the least-used colour, not a duplicate",
              registry.count > 1 && registry[1].colour == .red,
              "got \(registry.count > 1 ? registry[1].colour.rawValue : "nothing")")
        check("duplicate names collapse, case-insensitively",
              registry.count == 3, "got \(registry.count)")
        check("the registry round-trips through its own file format",
              Projects.parse(Projects.serialise(registry)) == registry)
        check("eight projects get eight different colours",
              Set((0..<8).reduce(into: [Project]()) { acc, _ in
                  acc.append(Project(name: "p\(acc.count)",
                                     colour: Projects.nextColour(acc)))
              }.map(\.colour)).count == 8,
              "the least-used rule must cycle the palette before repeating")
        check("every colour pairs a fill with an ink",
              ProjectColour.allCases.allSatisfy { $0.fill != 0 && $0.ink != $0.fill })

        // --- the sidebar's project filter
        let mixedShelf: [Paper] = {
            var x = Paper(arxivID: "f1"); x.project = "CoT monitorability"
            var y = Paper(arxivID: "f2"); y.project = "Self-improvement"
            let z = Paper(arxivID: "f3")
            return [x, y, z]
        }()
        check("no filter shows the whole shelf",
              Projects.papers(mixedShelf, matching: nil).count == 3)
        check("a project filter shows that project, case-insensitively",
              Projects.papers(mixedShelf, matching: "cot MONITORABILITY").map(\.arxivID) == ["f1"],
              "the same rule the registry uses for duplicate names")
        check("the untagged filter shows only untagged papers",
              Projects.papers(mixedShelf, matching: "").map(\.arxivID) == ["f3"],
              "an empty name means no project, not every project")

        // --- the website graph export
        //
        // What leaves the machine is deliberately narrow: geometry, title, link,
        // and the note's claim section. A hollow node on the site is a paper
        // whose claim was never written — that distinction is data, so it is
        // pinned here rather than left to the renderer's goodwill.
        let webShelf: [Paper] = {
            var x = Paper(arxivID: "2501.00001"); x.title = "Probe One"
            x.year = 2025; x.citations = 100
            x.refs = ["2501.00002", "1111.11111"]
            x.body = "## Claim, in my words\n\nIt scales, but only sideways.\n\n## Evidence\n"
            var y = Paper(arxivID: "2501.00002"); y.title = "Probe Two"; y.year = 2024
            var z = Paper(arxivID: "2501.00003"); z.title = "Probe Three (archived)"
            z.archaic = true
            return [x, y, z]
        }()
        let graph = GraphExport.payload(for: webShelf)
        let gNodes = graph["nodes"] as? [[String: Any]] ?? []
        let gEdges = graph["edges"] as? [[Any]] ?? []
        check("archived papers stay out of the exported graph",
              gNodes.map { $0["id"] as? String } == ["2501.00001", "2501.00002"],
              "same rule as the graph window")
        check("a written claim travels as the summary",
              gNodes.first?["summary"] as? String == "It scales, but only sideways.")
        check("an unwritten note exports an empty summary, not the template",
              gNodes.last?["summary"] as? String == "",
              "the template's prompts are scaffolding; empty is what draws hollow")
        check("a free-form note's prose is its summary",
              { var p = Paper(arxivID: "x")
                p.body = "<!-- imported -->\n\nJust prose, no headings."
                return p.webSummary == "Just prose, no headings." }(),
              "79 notes are the old website summaries, imported without headings")
        check("a free-form note may use headings of its own",
              { var p = Paper(arxivID: "x")
                p.body = "## Setup\n\nThe old site summaries have structure."
                return p.webSummary == "The old site summaries have structure." }(),
              "only the template's own Claim heading marks a note as templated")
        check("working notes under other headings are not a summary",
              { var p = Paper(arxivID: "x")
                p.body = "## Claim, in my words\n\n## What I didn't understand\n\nwhy it converges"
                return p.webSummary.isEmpty }(),
              "confusions are candid and stay off the web")

        // --- the current template: Summary + Questions/Comments
        //
        // Five notes were hand-written in this shape before it became the
        // template, and under the old export rule their whole prose — candid
        // comments included — was headed for the website. The summary is the
        // Summary section, full stop.
        check("the fresh template is the two-heading one",
              Paper.template.contains("## Summary")
              && Paper.template.contains("## Questions/Comments")
              && !Paper.template.contains("Claim, in my words"))
        check("an untouched new template is not a note yet",
              !Paper(arxivID: "x").isSubstantive,
              "headings alone must not count as written")
        var newNote = Paper(arxivID: "2509.00001")
        newNote.body = "## Summary\n\nA tidy result about scaling.\n\n"
            + "## Questions/Comments\n\n- Why only 3B models?\n- This feels underpowered."
        check("the Summary section is the web summary — nothing else",
              newNote.webSummary == "A tidy result about scaling.",
              "questions and comments are working notes and stay off the web")
        check("questions and comments reach the grader whole",
              newNote.questions.confusionSection.contains("Why only 3B models?")
              && newNote.questions.confusionSection.contains("underpowered")
              && newNote.questions.count == 2,
              "a comment without a question mark is still worth an answer")
        check("questions without a summary draw hollow and leak nothing",
              { var p = Paper(arxivID: "x")
                p.body = "## Summary\n\n## Questions/Comments\n\n- What is the baseline?"
                return p.webSummary.isEmpty }())
        check("a metadata-less paper labels by its title, not a bare id",
              { var p = Paper(arxivID: "2507.14805")
                p.title = "GenEnv: Difficulty-Aligned Coevolution"; p.year = 2025
                return GraphExport.label(p) == "GenEnv 2025" }(),
              "the site showed '2507.14805 2025' as a label, which reads as a glitch")
        check("a short first word takes the next word with it",
              { var p = Paper(arxivID: "x"); p.title = "How Well Do Models Follow"
                return GraphExport.label(p) == "How Well" }(),
              "a graph dotted with 'How' and 'From' names nothing")
        check("a leading article is not a name",
              { var p = Paper(arxivID: "x"); p.title = "The Anatomy of Reward Hacking"
                return GraphExport.label(p) == "Anatomy" }())
        check("citing papers are connected",
              gEdges.contains { ($0[0] as? Int) == 0 && ($0[1] as? Int) == 1 },
              "got \(gEdges)")
        check("every node lands on the canvas",
              gNodes.allSatisfy {
                  let x = $0["x"] as? Double ?? -1, y = $0["y"] as? Double ?? -1
                  return x >= 0 && x <= 1000 && y >= 0 && y <= 620
              })
        check("the export is deterministic",
              GraphExport.text(for: webShelf, wrap: false)
                  == GraphExport.text(for: webShelf, wrap: false),
              "the same library must produce the same bytes, or every export is a diff")
        check("the .js wrapping assigns the global the site reads",
              GraphExport.text(for: webShelf, wrap: true)
                  .hasPrefix("window.READING_GRAPH = {"))

        // --- archived papers
        var archived = Paper(arxivID: "2010.06189")
        archived.archaic = true
        let archivedBack = Paper(markdown: archived.markdown)
        check("round-trip: archaic", archivedBack?.archaic == true)
        check("a paper is not archaic unless it says so",
              Paper(markdown: Paper(arxivID: "2507.14805").markdown)?.archaic == false)

        // --- publication order
        //
        // The date comes from the arXiv id, which carries the month and exists
        // even when the metadata fetch failed. Three papers had no year at all
        // and sorted below a 2016 paper, which reads as a broken list.
        check("the month comes out of the arXiv id",
              Paper(arxivID: "2507.14805").published == (2025, 7),
              "got \(Paper(arxivID: "2507.14805").published)")
        check("an old-style id falls back to the year field", {
            var old = Paper(arxivID: "cs/0601001"); old.year = 2006
            return old.published == (2006, 0)
        }())
        var undated = Paper(arxivID: "2507.14805")      // no year field at all
        var older = Paper(arxivID: "1611.04231")
        older.year = 2016
        let ordered = SortOrder.apply(.published, to: [older, undated])
        check("a 2025 paper with no year still sorts above a 2016 one",
              ordered.first?.arxivID == "2507.14805",
              "a missing year used to sink it to the bottom of the library")
        var june = Paper(arxivID: "2506.21734"); june.year = 2025
        var sept = Paper(arxivID: "2509.25123"); sept.year = 2025
        var live = Paper(arxivID: "2509.25123")
        var shelved = Paper(arxivID: "1710.04087"); shelved.archaic = true
        check("recommendations ignore archived papers",
              Recommender.eligible([live, shelved]).map(\.arxivID) == ["2509.25123"],
              "old cross-lingual work would otherwise drag every suggestion toward it")
        check("unless asked for",
              Recommender.eligible([live, shelved], includeArchaic: true).count == 2)
        check("archived papers sit the ranking out", {
            var current = Paper(arxivID: "2509.25123"); current.appraisalNote = "an idea"
            var past = Paper(arxivID: "1710.04087")
            past.appraisalNote = "an idea"; past.archaic = true
            return Ranker.rankable([current, past]).map(\.arxivID) == ["2509.25123"]
        }(), "33 archived papers were competing for the same GOLD and SOLID quotas")

        check("within a year, ordering is by month",
              SortOrder.apply(.published, to: [june, sept]).first?.arxivID == "2509.25123")
        check("template is not mistaken for a note",
              !Paper(arxivID: "1234.5678").isSubstantive,
              "an untouched template counts as unread")
        var written = Paper(arxivID: "1234.5678")
        written.body = Paper.template + "\nActually wrote something."
        check("prose counts as a note", written.isSubstantive)
        check("round-trip: read date", back.readOn.map {
            abs($0.timeIntervalSince(p.readOn!)) < 86400 } ?? false)

        // --- id handling
        check("version suffix stripped", PDFRefs.normalise("2510.23966v3") == "2510.23966")
        check("a .pdf extension is not part of an id",
              PDFRefs.normalise("2510.23966v2.pdf") == "2510.23966",
              "27 papers dragged in as '<id>.pdf' kept the extension in their key: "
            + "no metadata, no arXiv link, no citation edges")
        check("an ACL id is not eaten by the .pdf rule",
              PDFRefs.normalise("2021.emnlp-main.70") == "2021.emnlp-main.70")
        check("arXiv prefix stripped", PDFRefs.normalise("arXiv:2510.23966") == "2510.23966")
        check("id from descriptive filename",
              PDFRefs.idFromFilename("Adaptive_Attacks__2510.09462.pdf") == "2510.09462")
        check("id from bare filename",
              PDFRefs.idFromFilename("2412.04984v2.pdf") == "2412.04984")

        // --- non-arXiv keys. ACL Anthology work has no arXiv id at all, and
        //     keying strictly by arXiv locked nine written notes out of the library.
        check("arXiv id shapes are recognised",
              Paper.isArxivID("2510.23966") && Paper.isArxivID("2510.23966v2")
                && !Paper.isArxivID("2021.emnlp-main.70") && !Paper.isArxivID("P17-1042")
                && !Paper.isArxivID("rivest-sloan-1994") && !Paper.isArxivID("2510.23966v"))
        check("ACL id shapes are recognised, both eras",
              Paper.isACLID("2021.emnlp-main.70") && Paper.isACLID("P17-1042")
                && Paper.isACLID("D16-1250") && Paper.isACLID("N15-1104")
                && !Paper.isACLID("2510.23966") && !Paper.isACLID("rivest-sloan-1994"))
        check("normalise leaves an ACL id alone",
              PDFRefs.normalise("2021.emnlp-main.70") == "2021.emnlp-main.70",
              "digit truncation would have quietly turned it into \"2021.\"")
        check("a non-arXiv key round-trips under id:", {
            var acl = Paper(arxivID: "P17-1042")
            acl.title = "Learning bilingual word embeddings with (almost) no bilingual data"
            acl.year = 2017
            let text = acl.markdown
            return text.contains("id: P17-1042") && !text.contains("arxiv:")
                && Paper(markdown: text)?.arxivID == "P17-1042"
        }(), "written as id:, because calling it arxiv: in the file would be a lie")
        check("published falls back to the year for non-arXiv keys", {
            var acl = Paper(arxivID: "2021.emnlp-main.70"); acl.year = 2021
            return acl.published == (2021, 0)
        }(), "the id's leading digits look like YYMM but are not one")
        check("external links follow the id's shape",
              Paper(arxivID: "2510.23966").externalURL?.absoluteString
                    == "https://arxiv.org/abs/2510.23966"
                && Paper(arxivID: "2021.emnlp-main.70").externalURL?.absoluteString
                    == "https://aclanthology.org/2021.emnlp-main.70/"
                && Paper(arxivID: "rivest-sloan-1994").externalURL == nil,
              "a hand-made key gets no link — a dead link dressed as real is worse than none")

        // --- the graph, on known inputs. Deterministic, so a failure here is a bug
        //     in the scoring rather than a property of whatever is in Downloads.
        func made(_ id: String, _ title: String, _ refs: [String]) -> Paper {
            var p = Paper(arxivID: id); p.title = title; p.refs = refs; return p
        }
        let a = made("1111.11111", "Sparse autoencoders for feature discovery",
                     ["2222.22222", "3333.33333", "4444.44444"])
        let b = made("2222.22222", "Probing latent directions in transformers",
                     ["3333.33333", "4444.44444", "5555.55555"])
        let c = made("9999.99999", "Photonic lattice fabrication", ["8888.88888"])
        let synthetic = [a, b, c]

        let fromA = Relations.related(to: a, in: synthetic)
        check("A cites B is detected",
              fromA.first { $0.other.arxivID == b.arxivID }?.kind == .citedBy,
              "direct citation beats weaker signals")
        let fromB = Relations.related(to: b, in: synthetic)
        check("the reverse edge appears on B",
              fromB.first { $0.other.arxivID == a.arxivID }?.kind == .cites)
        check("unrelated paper gets no edge",
              Relations.related(to: c, in: synthetic).isEmpty,
              "different topic, no shared refs")

        // Coupling without a direct citation.
        let d = made("7777.77777", "Curvature estimates on Riemannian manifolds",
                     ["1010.10101", "2020.20202", "3030.30303"])
        let e = made("6666.66666", "Discrete Ricci flow on graphs",
                     ["1010.10101", "2020.20202", "3030.30303"])
        let coupled = Relations.related(to: d, in: [d, e]).first
        check("shared references make an edge",
              coupled?.kind == .coupling && coupled?.shared == 3,
              "3 shared refs, neither cites the other")
        check("edges are undirected and deduplicated",
              Relations.edges(in: [a, b, c]).count == 1,
              "A–B counted once, not twice")

        // The invariant that was broken: the graph must draw every relation the note
        // panel lists, or the two disagree about the same library.
        let weakA = made("4141.41411", "Sheaf cohomology of toric varieties",
                         ["1212.12121", "1313.13131", "5151.51511"])
        let weakB = made("4242.42422", "Tropical geometry and matroid subdivisions",
                         ["1212.12121", "1313.13131", "6161.61611"])
        let weakLibrary = [weakA, weakB]
        let panelPairs = Set(weakLibrary.flatMap { p in
            Relations.related(to: p, in: weakLibrary).map { [p.arxivID, $0.other.arxivID].sorted().joined(separator: "|") }
        })
        let graphPairs = Set(Relations.edges(in: weakLibrary)
            .map { [$0.0, $0.1].sorted().joined(separator: "|") })
        check("graph draws every relation the panel lists",
              panelPairs == graphPairs && !panelPairs.isEmpty,
              "\(panelPairs.count) in panel, \(graphPairs.count) in graph")

        // --- force layout
        let box = CGSize(width: 800, height: 600)
        let ids = ["a", "b", "c", "d", "e", "f"]
        // Two clusters, joined by nothing.
        let clusterEdges: [(String, String, Double)] = [
            ("a", "b", 1.0), ("b", "c", 1.0), ("a", "c", 1.0),
            ("d", "e", 1.0), ("e", "f", 1.0), ("d", "f", 1.0)
        ]
        let first = ForceLayout.layout(ids: ids, edges: clusterEdges, size: box)
        let second = ForceLayout.layout(ids: ids, edges: clusterEdges, size: box)

        check("layout is deterministic",
              ids.allSatisfy { first[$0]?.position == second[$0]?.position },
              "same library lays out the same way every time")
        check("no NaN escapes the simulation",
              first.values.allSatisfy { $0.position.x.isFinite && $0.position.y.isFinite })
        check("everything stays on canvas",
              first.values.allSatisfy {
                  $0.position.x >= 0 && $0.position.x <= box.width &&
                  $0.position.y >= 0 && $0.position.y <= box.height })

        func gap(_ p: String, _ q: String) -> Double {
            guard let a = first[p]?.position, let b = first[q]?.position else { return .infinity }
            return Double(hypot(a.x - b.x, a.y - b.y))
        }
        // The one property that makes the picture mean anything.
        let withinCluster = (gap("a", "b") + gap("b", "c") + gap("d", "e") + gap("e", "f")) / 4
        let acrossClusters = (gap("a", "d") + gap("b", "e") + gap("c", "f")) / 3
        check("connected papers land closer than unconnected ones",
              withinCluster < acrossClusters,
              String(format: "%.0fpt within vs %.0fpt across", withinCluster, acrossClusters))

        check("degree is counted", first["a"]?.degree == 2, "a has two edges")
        check("empty library doesn't crash",
              ForceLayout.layout(ids: [], edges: [], size: box).isEmpty)
        check("a lone paper is placed",
              ForceLayout.layout(ids: ["solo"], edges: [], size: box).count == 1)

        // --- live simulation. A force sim can explode, oscillate forever, or emit
        //     NaN; none of those are visible from a single frame.
        let simIDs = ["a", "b", "c", "d", "e", "f"]
        let simEdges: [(String, String, Double)] = [
            ("a", "b", 1.0), ("b", "c", 1.0), ("a", "c", 1.0),
            ("d", "e", 1.0), ("e", "f", 1.0), ("d", "f", 1.0)
        ]
        let simBox = CGSize(width: 800, height: 600)
        let centre = CGPoint(x: 400, y: 300)
        let sim = GraphSim()
        var masses: [String: Double] = [:]
        for id in simIDs { masses[id] = id == "a" ? 6.0 : 1.0 }   // "a" is heavy
        sim.load(ids: simIDs, edges: simEdges, masses: masses, size: simBox)

        let startAlpha = sim.alpha
        for _ in 0..<1200 { sim.step(centre: centre) }

        check("simulation cools", sim.alpha < startAlpha && sim.isSettled,
              String(format: "alpha %.4f", sim.alpha))
        check("no NaN in the simulation",
              sim.bodies.values.allSatisfy { $0.position.x.isFinite && $0.position.y.isFinite })
        let fastest = sim.bodies.values.map { hypot($0.velocity.x, $0.velocity.y) }.max() ?? 99
        check("it comes to rest", fastest < 1.0,
              String(format: "fastest body %.3f pt/frame", fastest))
        // Nothing should have escaped to infinity — gravity has to hold it in.
        let farthest = sim.bodies.values
            .map { hypot($0.position.x - centre.x, $0.position.y - centre.y) }.max() ?? 0
        check("nothing escapes", farthest < 2000, String(format: "farthest %.0f pt", farthest))

        func gapSim(_ p: String, _ q: String) -> Double {
            guard let a = sim.position(p), let b = sim.position(q) else { return .infinity }
            return Double(hypot(a.x - b.x, a.y - b.y))
        }
        let within = (gapSim("a", "b") + gapSim("d", "e")) / 2
        let across = (gapSim("a", "d") + gapSim("b", "e")) / 2
        check("clusters still form under physics", within < across,
              String(format: "%.0f within vs %.0f across", within, across))

        // Dragging pins a node exactly where it is held.
        sim.dragging = "c"
        sim.dragTarget = CGPoint(x: 123, y: 456)
        sim.step(centre: centre)
        let held = sim.position("c")
        check("a dragged node follows the cursor",
              abs((held?.x ?? 0) - 123) < 0.01 && abs((held?.y ?? 0) - 456) < 0.01)
        sim.dragging = nil

        // Releasing leaves momentum behind rather than stopping dead.
        let releasedSpeed = hypot(sim.bodies["c"]?.velocity.x ?? 0, sim.bodies["c"]?.velocity.y ?? 0)
        check("release carries momentum", releasedSpeed > 0,
              String(format: "%.1f pt/frame", releasedSpeed))

        // A fast drag across the canvas, then release. This is where a spring
        // simulation blows up: the held node outruns its neighbours, the springs
        // stretch, and everything is flung outward.
        let drag = GraphSim()
        drag.load(ids: simIDs, edges: simEdges, masses: masses, size: simBox)
        for _ in 0..<400 { drag.step(centre: centre) }
        drag.dragging = "a"
        for i in 0..<120 {
            // ~15 pt per frame, a brisk but ordinary drag.
            drag.dragTarget = CGPoint(x: 100 + CGFloat(i) * 15, y: 100 + CGFloat(i) * 8)
            drag.step(centre: centre)
        }
        drag.dragging = nil
        for _ in 0..<600 { drag.step(centre: centre) }

        let escaped = drag.bodies.values
            .map { hypot($0.position.x - centre.x, $0.position.y - centre.y) }.max() ?? 0
        check("a fast drag does not fling the graph away", escaped < 520,
              String(format: "farthest %.0f pt from centre after release", escaped))
        check("everything is still finite after a drag",
              drag.bodies.values.allSatisfy { $0.position.x.isFinite && $0.position.y.isFinite })
        let restSpeed = drag.bodies.values.map { hypot($0.velocity.x, $0.velocity.y) }.max() ?? 99
        check("it settles again after a drag", restSpeed < 1.0,
              String(format: "fastest %.3f pt/frame", restSpeed))

        // Distance has to mean something: a strongly related pair should end up
        // closer than a weakly related one, which is the whole premise of the picture.
        let simIDs2 = ["x", "y", "p", "q"]
        let strongWeak: [(String, String, Double)] = [("x", "y", 1.0), ("p", "q", 0.15)]
        let spacing = GraphSim()
        spacing.load(ids: simIDs2, edges: strongWeak,
                     masses: ["x": 1, "y": 1, "p": 1, "q": 1], size: simBox)
        for _ in 0..<1500 { spacing.step(centre: centre) }
        func span(_ a: String, _ b: String) -> Double {
            guard let pa = spacing.position(a), let pb = spacing.position(b) else { return 0 }
            return Double(hypot(pa.x - pb.x, pa.y - pb.y))
        }
        check("distance encodes similarity", span("x", "y") < span("p", "q"),
              String(format: "strong pair %.0f pt, weak pair %.0f pt", span("x", "y"), span("p", "q")))

        // --- viewport gesture. This is what actually sent the graph to Narnia:
        //     the simulation was contained the whole time.
        var vp = ViewportGesture()
        vp.began(hit: nil, currentPan: .zero)
        // A drag translates cumulatively: 10, 20, 30 as the cursor keeps moving.
        let p1 = vp.pan(for: CGSize(width: 10, height: 0))
        vp.began(hit: nil, currentPan: p1)          // the erroneous re-baseline
        let p2 = vp.pan(for: CGSize(width: 20, height: 0))
        vp.began(hit: nil, currentPan: p2)
        let p3 = vp.pan(for: CGSize(width: 30, height: 0))
        check("pan follows the cursor 1:1", p3.width == 30,
              String(format: "%.0f pt after a 30 pt drag (quadratic growth gives 60)", p3.width))
        check("the origin is captured once", vp.isPanning)

        vp.ended()
        vp.began(hit: "n1", currentPan: .zero)
        check("a hit starts a node drag, not a pan", vp.draggedNode == "n1" && !vp.isPanning)
        vp.began(hit: nil, currentPan: CGSize(width: 99, height: 99))
        check("mode cannot change mid-gesture", vp.draggedNode == "n1",
              "a wobble off the node must not turn a node drag into a pan")
        vp.ended()
        check("ending resets", vp.mode == .idle)

        // --- recommender
        func withRefs(_ id: String, _ refs: [String], starred: Bool = false) -> Paper {
            var q = Paper(arxivID: id); q.refs = refs; q.starred = starred; q.title = "T" + id
            return q
        }
        let recLib = [
            withRefs("1000.00001", ["9000.00001", "9000.00002", "1000.00002"]),
            withRefs("1000.00002", ["9000.00001", "9000.00003"]),
            withRefs("1000.00003", ["9000.00001", "9000.00002"])
        ]
        let cands = Recommender.candidates(from: recLib, minimumCiting: 2)
        check("recommends what the library keeps citing",
              cands.first?.arxivID == "9000.00001",
              "cited by \(cands.first?.citedByYours.count ?? 0) of 3")
        check("never recommends a paper already read",
              !cands.contains { $0.arxivID == "1000.00002" },
              "1000.00002 is cited by another paper but is already in the library")
        check("below-threshold candidates are dropped",
              !cands.contains { $0.arxivID == "9000.00003" }, "cited once, threshold 2")

        // Starring must actually change the ranking, or the thumbs-up is decorative.
        let starLib = [
            withRefs("1000.00001", ["9000.00007"], starred: true),
            withRefs("1000.00002", ["9000.00008"]),
            withRefs("1000.00003", ["9000.00008"])
        ]
        let starRanked = Recommender.candidates(from: starLib, minimumCiting: 2)
        check("starring outranks raw count",
              starRanked.first?.arxivID == "9000.00007",
              "one starred citer (weight 3) beats two unstarred (weight 2)")

        // --- appraisal
        let ap = Judge.parseAppraisal("SCORE: 88\nVERDICT: GOLD\nWHY: names emergent misalignment.")
        check("appraisal parses",
              ap?.verdict == .gold && ap?.note.contains("misalignment") == true && ap?.score == 88)
        check("a missing score is -1, not 0",
              Judge.parseAppraisal("VERDICT: THIN\nWHY: x")?.score == -1,
              "0 is a real score and must not stand in for absent")
        check("an out-of-range score is clamped",
              Judge.parseAppraisal("SCORE: 140\nVERDICT: GOLD\nWHY: x")?.score == 100)
        check("qualified appraisal takes the head word",
              Judge.parseAppraisal("VERDICT: SOLID (leaning MIXED)\nWHY: x")?.verdict == .solid)
        check("an unrecognised grade is dropped, not defaulted",
              Judge.parseAppraisal("VERDICT: EXCELLENT\nWHY: x") == nil,
              "a wrong label on the shelf is worse than an empty one")
        check("prose reply yields nothing",
              Judge.parseAppraisal("This paper is quite interesting overall.") == nil)
        check("the judge may not return unset",
              Judge.parseAppraisal("VERDICT: UNSET\nWHY: x") == nil)

        var appraised = Paper(arxivID: "2601.00001")
        appraised.appraisal = .gold
        appraised.appraisalNote = "Turns the usual framing inside out: reward hacking as a cause, not a symptom."
        check("your verdict wins when you have one",
              { var p = appraised; p.verdict = .thin; return p.effectiveVerdict == .thin }())
        check("Claude's stands in when you have not judged",
              appraised.effectiveVerdict == .gold)
        check("disagreement is detectable",
              { var p = appraised; p.verdict = .thin; return p.overridesAppraisal }())
        check("agreement is not disagreement",
              { var p = appraised; p.verdict = .gold; return !p.overridesAppraisal }())
        if let round = Paper(markdown: appraised.markdown) {
            check("appraisal survives the file round-trip",
                  round.appraisal == .gold && round.appraisalNote == appraised.appraisalNote)
            check("an appraisal alone leaves your verdict empty",
                  round.verdict == .unset, "the app never writes into your field")
        } else {
            check("appraisal survives the file round-trip", false, "did not parse back")
        }

        let byInterest = SortOrder.apply(.interest, to: [
            { var p = Paper(arxivID: "9000.00001"); p.year = 2026; return p }(),
            { var p = Paper(arxivID: "9000.00002"); p.year = 2020; p.appraisal = .gold; return p }(),
            { var p = Paper(arxivID: "9000.00003"); p.year = 2026; p.appraisal = .thin; return p }()
        ])
        check("most interesting sorts by grade, ungraded last",
              byInterest.map(\.arxivID) == ["9000.00002", "9000.00003", "9000.00001"],
              "an absent grade is not a low one")

        // --- recency, which is the thing the ordering turns on
        func daysAgo(_ n: Double) -> Date { Date().addingTimeInterval(-n * 86_400) }
        check("this week outranks last year at equal relevance",
              Recommender.recencyWeight(daysAgo(3)) > Recommender.recencyWeight(daysAgo(400)) * 8,
              "a year-old paper has usually reached you some other way")
        check("recency decays monotonically",
              [1.0, 20, 60, 120, 300, 900].map(daysAgo).map(Recommender.recencyWeight)
                == [1.0, 20, 60, 120, 300, 900].map(daysAgo).map(Recommender.recencyWeight)
                    .sorted(by: >))
        check("an unknown date is discounted, not dropped",
              Recommender.recencyWeight(nil) > 0 && Recommender.recencyWeight(nil) < 0.5,
              "no date is not the same as no relevance")
        check("age reads in human units",
              { var c = Recommender.Candidate(arxivID: "1", weight: 1)
                c.published = daysAgo(3); return c.ageLabel }() == "3 days ago")

        // --- the library's own vocabulary, which shortlists the arXiv firehose
        func titled(_ t: String, note: String = "") -> Paper {
            var p = Paper(arxivID: "9\(abs(t.hashValue % 100000)).00001")
            p.title = t
            p.body = note.isEmpty ? Paper.template : Paper.template + "\n" + note
            return p
        }
        let agenda = [
            titled("Emergent misalignment from reward hacking in production"),
            titled("Monitoring reasoning models for misbehavior"),
            titled("Chain-of-thought monitorability is fragile"),
            titled("Subliminal learning transmits traits through distillation"),
            titled("Reward hacking generalizes to emergent misalignment"),
            titled("Photonic lattice fabrication at scale"),
        ]
        // The flaw that let a ternary-quantization paper onto a list about reward
        // hacking: "learning" appears in more of the library than "misalignment"
        // does, so counting alone ranks the generic term higher.
        let genericVsRare = [
            titled("Emergent misalignment from reward hacking"),
            titled("Emergent misalignment in production training"),
            titled("Misalignment and learning dynamics"),
            titled("Subliminal learning through distillation"),
            titled("Curriculum learning for reasoning"),
            titled("Learning to verify with process rewards"),
        ]
        let background = (1...60).map { i in
            FeedPaper(arxivID: "8000.\(i)",
                      title: "Efficient learning for language models \(i)",
                      abstract: "We study learning and training for language models at scale.")
        }
        let naive = Vocabulary.build(from: genericVsRare)
        let idf = Vocabulary.build(from: genericVsRare, background: background)
        check("counting alone ranks the generic term at least as high",
              naive.weights["learning", default: 0] >= naive.weights["misalignment", default: 0],
              "learning \(naive.weights["learning"] ?? 0) vs misalignment \(naive.weights["misalignment"] ?? 0)")
        check("weighting by rarity flips it",
              idf.weights["misalignment", default: 0] > idf.weights["learning", default: 0],
              "learning is in every paper in the background corpus; misalignment in none")
        check("no background corpus degrades gracefully rather than scoring zero",
              !naive.weights.isEmpty && naive.score(title: "Emergent misalignment", abstract: "") > 0)
        check("Claude's appraisal prose is not your vocabulary",
              Vocabulary.build(from: [{
                  var p = Paper(arxivID: "7000.00001")
                  p.title = "Photonics"
                  p.appraisalNote = "This reframes the problem genuinely well."
                  return p
              }()]).weights["reframes"] == nil,
              "\"reframes\" and \"genuinely\" were top library terms, from the judge")

        let vocab = Vocabulary.build(from: agenda, background: background)
        let onTopic = vocab.score(
            title: "Emergent misalignment under reward hacking, revisited",
            abstract: "We study misalignment arising from reward hacking in reasoning models.")
        let offTopic = vocab.score(
            title: "A PAC bound for agnostic learning",
            abstract: "We prove an optimal agnostic PAC algorithm for finite hypothesis classes.")
        check("a paper on your topics scores above one that is not",
              onTopic > offTopic * 3, "\(onTopic) vs \(offTopic)")
        check("one paper does not make a term the library cares about",
              vocab.score(title: "Photonic lattice interference", abstract: "") < onTopic / 2,
              "photonic appears once in six papers")
        check("scores stay in range",
              (0...1).contains(onTopic) && (0...1).contains(offTopic))
        check("an empty library scores nothing rather than crashing",
              Vocabulary.build(from: []).score(title: "anything", abstract: "") == 0)

        // --- merging the sources
        func cand(_ id: String, _ src: Recommender.Source, _ w: Double, days: Double) -> Recommender.Candidate {
            var c = Recommender.Candidate(arxivID: id, weight: w)
            c.source = src
            c.published = daysAgo(days)
            return c
        }
        let merged = Recommender.merge([
            (.fresh, [cand("1000.00001", .fresh, 0.5, days: 2),
                      cand("1000.00002", .fresh, 0.4, days: 5)]),
            (.similar, [cand("1000.00003", .similar, 1, days: 40)]),
            (.author(""), [cand("1000.00004", .author("X"), 20, days: 90)]),
            (.cited, [cand("1000.00005", .cited, 25, days: 900)]),
        ], limit: 8)
        check("every source is represented, none crowds the others out",
              Set(merged.map(\.arxivID)).count == 5,
              "a single ranking would let the citation source win on raw weight")
        check("the newest paper leads the list",
              merged.first?.arxivID == "1000.00001")
        check("the year-old paper sinks despite the highest raw weight",
              merged.last?.arxivID == "1000.00005",
              "weight 25 against weight 0.5, and recency still wins")
        check("nothing is duplicated across sources",
              merged.count == Set(merged.map(\.arxivID)).count)

        // --- sidebar search
        func searchable(_ id: String, _ title: String, authors: [String] = [],
                        body: String = "", appraisal: String = "") -> Paper {
            var p = Paper(arxivID: id)
            p.title = title
            p.authors = authors
            p.appraisalNote = appraisal
            p.body = body.isEmpty ? Paper.template : Paper.template + "\n" + body
            return p
        }
        let shelf = [
            searchable("2507.14805", "Subliminal Learning: Language models transmit traits",
                       authors: ["Alex Cloud", "Owain Evans"]),
            searchable("2506.01926", "Steganographic chain-of-thought under process supervision",
                       authors: ["Joey Skaf"],
                       body: "The encoding survives filtering, which is the surprising part."),
            searchable("2604.25891", "Conditional misalignment",
                       authors: ["Jan Dubiński"],
                       appraisal: "Interventions merely gate misalignment behind training cues."),
            searchable("1234.56789", "Something unrelated about photonics")
        ]

        check("a title match wins over a body match",
              Search.matches("subliminal", in: shelf).first?.paper.arxivID == "2507.14805")
        check("your own note is searchable",
              Search.matches("surprising", in: shelf).map(\.paper.arxivID) == ["2506.01926"],
              "the whole reason to have search in a reading tool")
        check("a note hit is labelled as one",
              Search.matches("surprising", in: shelf).first?.field == .note)
        check("a note hit carries a snippet",
              Search.matches("surprising", in: shelf).first?.snippet.contains("surprising") == true)
        check("the appraisal is searchable and labelled",
              Search.matches("gate", in: shelf).first?.field == .appraisal)
        check("authors match",
              Search.matches("evans", in: shelf).map(\.paper.arxivID) == ["2507.14805"])
        check("accents fold",
              Search.matches("dubinski", in: shelf).map(\.paper.arxivID) == ["2604.25891"],
              "nobody types Dubiński")
        check("arXiv ids match", !Search.matches("2506.01926", in: shelf).isEmpty)
        check("two tokens narrow rather than widen",
              Search.matches("steganographic filtering", in: shelf).count == 1
                && Search.matches("steganographic photonics", in: shelf).isEmpty,
              "every token must land somewhere on the same paper")
        check("tokens may land in different fields",
              Search.matches("skaf filtering", in: shelf).count == 1,
              "author in one field, note in another")
        check("an empty query matches nothing",
              Search.matches("   ", in: shelf).isEmpty,
              "rather than returning the whole library as 62 hits")
        check("no match is no hit", Search.matches("quasicrystal", in: shelf).isEmpty)
        check("a partial word still completes",
              Search.matches("stegan", in: shelf).map(\.paper.arxivID) == ["2506.01926"],
              "typing half a word should find it")
        check("but a token does not match mid-word",
              Search.matches("raits", in: shelf).isEmpty,
              "searching an author surname like Tan otherwise matches \"important\"")
        check("template scaffolding is not searchable",
              Search.matches("as you'd tell a colleague", in: shelf).isEmpty,
              "the prompts are furniture, not your writing")
        check("a snippet never includes the comment prompts",
              !(Search.matches("surprising", in: shelf).first?.snippet.contains("<!--") ?? true))

        // Archived papers stay searchable — that is the deal archiving makes —
        // but they yield to current papers within the same match rank.
        var shelfWithArchived = shelf
        var crossLingual = searchable("1710.04087",
                                      "Subliminal word translation without parallel data")
        crossLingual.archaic = true
        shelfWithArchived.insert(crossLingual, at: 0)   // inserted FIRST, so order must be earned
        let subliminal = Search.matches("subliminal", in: shelfWithArchived)
        check("an archived paper is still findable",
              subliminal.contains { $0.paper.arxivID == "1710.04087" })
        check("but a current paper outranks it at the same field",
              subliminal.first?.paper.arxivID == "2507.14805",
              "both are title hits; the archived one was even listed first")

        // --- reading queue
        func lib(_ spec: [(String, Int)]) -> [Paper] {
            spec.map { var p = Paper(arxivID: $0.0); p.queuePosition = $0.1; return p }
        }
        func positions(_ changed: [Paper], over base: [Paper]) -> [(String, Int)] {
            var byID = Dictionary(uniqueKeysWithValues: base.map { ($0.arxivID, $0) })
            for c in changed { byID[c.arxivID] = c }
            return ReadingQueue.ordered(Array(byID.values))
                .map { ($0.arxivID, $0.queuePosition) }
        }

        let empty = lib([("1000.00001", -1), ("1000.00002", -1), ("1000.00003", -1)])
        let opened = ReadingQueue.adding(["1000.00002"], to: empty, atFront: true)
        check("queuing into an empty queue starts at 1",
              positions(opened, over: empty).map(\.1) == [1])

        let three = lib([("1000.00001", 1), ("1000.00002", 2), ("1000.00003", 3)])
        let jumped = ReadingQueue.adding(["1000.00003"], to: three, atFront: true)
        check("read-next on an already-queued paper moves it, not duplicates it",
              positions(jumped, over: three).map(\.0)
                == ["1000.00003", "1000.00001", "1000.00002"],
              "and the others shuffle down rather than sharing a position")
        check("positions stay dense after a move",
              positions(jumped, over: three).map(\.1) == [1, 2, 3])

        let many = ReadingQueue.adding(["1000.00003", "1000.00001"], to: three, atFront: true)
        check("queuing several keeps the order you gave them",
              positions(many, over: three).map(\.0)
                == ["1000.00003", "1000.00001", "1000.00002"])

        let appended = ReadingQueue.adding(["1000.00001"], to: three, atFront: false)
        check("adding to the end puts it last",
              positions(appended, over: three).map(\.0)
                == ["1000.00002", "1000.00003", "1000.00001"])

        let pulled = ReadingQueue.removing(["1000.00001"], from: three)
        check("removing closes the gap it left",
              positions(pulled, over: three).map(\.1) == [1, 2],
              "a queue numbered 1, 2, 4 sorts fine and still reports the wrong count")
        check("removing drops it from the queue entirely",
              !positions(pulled, over: three).contains { $0.0 == "1000.00001" })

        check("an id that is not in the library is ignored",
              ReadingQueue.adding(["9999.99999"], to: three, atFront: true).isEmpty)
        check("the same id twice in one request queues once",
              ReadingQueue.adding(["1000.00001", "1000.00001"], to: empty, atFront: true).count == 1)
        check("queuing what is already first changes nothing",
              ReadingQueue.adding(["1000.00001"], to: three, atFront: true).isEmpty,
              "no write, so no commit")
        check("queuing an unread paper clears its stamped read date", {
            var p = Paper(arxivID: "1000.00007")
            p.readOn = Date()                       // what add() stamps on arrival
            return ReadingQueue.adding(["1000.00007"], to: [p], atFront: true)
                .first.map { $0.readOn == nil && $0.queuePosition == 1 } ?? false
        }(), "queued-and-read is a contradiction; the queue wins for a virgin note")
        check("a paper with a real note keeps its read date when re-queued", {
            var p = Paper(arxivID: "1000.00008")
            p.readOn = Date()
            p.body = Paper.template + "\nActually wrote something."
            return ReadingQueue.adding(["1000.00008"], to: [p], atFront: true)
                .first?.readOn != nil
        }(), "a revisit is not a contradiction")

        let queueSorted = SortOrder.apply(.queue, to: lib([
            ("1000.00001", -1), ("1000.00002", 2), ("1000.00003", 1)]))
        check("the queue sort puts queued papers first, in order",
              Array(queueSorted.prefix(2)).map(\.arxivID) == ["1000.00003", "1000.00002"])

        var queued = Paper(arxivID: "2507.14805")
        queued.queuePosition = 4
        check("the queue position survives the file round-trip",
              Paper(markdown: queued.markdown)?.queuePosition == 4)
        check("an unqueued paper writes no queue field",
              !Paper(arxivID: "1234.5678").markdown.contains("queue:"))

        // --- grade report parsing
        let reply = """
        ANSWERS:
        - **Why shared init.** Because $\\theta^0_S = \\theta^0_T$ makes the
          zeroth-order term vanish.
        - The theorem is one step, not convergence.
        GRADE: THIN
        MISSED: The misalignment result, which is the load-bearing one.
        CHECK: "carries no semantic trace" is stated as established; the paper hedges.
        ASK: What was the control condition in the animal experiment?
        """
        let report = GradeReport.parse(reply)
        check("grade parses to a bare label", report.grade == "THIN")
        check("multi-line answers stay together",
              report.answers.contains("zeroth-order") && report.answers.contains("one step"),
              "a wrapped bullet must not be cut at the line break")
        check("each section lands in its own field",
              report.missed.contains("misalignment") && report.check.contains("hedges")
                && report.ask.contains("control condition"))
        check("a label mid-sentence does not split a section",
              !GradeReport.parse("MISSED: you should CHECK: this claim later")
                  .missed.isEmpty,
              "only a line-leading label starts a new section")
        check("a reply in no known shape is not silently eaten",
              GradeReport.parse("I think the notes are fine.").isEmpty,
              "the sheet falls back to showing it verbatim")
        check("loose preamble is kept",
              GradeReport.parse("Here you go.\nGRADE: SOLID").preamble == "Here you go.")
        check("the grade is not repeated in the rendered body",
              !report.markdown(rawFallback: "").contains("THIN"),
              "it is drawn as a badge instead")

        // Caching must key on everything the prompt depends on.
        var noteA = Paper(arxivID: "2507.14805")
        noteA.body = "## Claim\n\nSomething about number sequences."
        var noteB = noteA
        noteB.body += " And one more sentence."
        check("an unchanged note reuses its key",
              GradeCache.key(for: noteA) == GradeCache.key(for: noteA),
              "otherwise every press is a fresh call")
        check("editing the note invalidates the key",
              GradeCache.key(for: noteA) != GradeCache.key(for: noteB))
        check("a different paper is a different key",
              GradeCache.key(for: noteA)
                != GradeCache.key(for: { var p = noteA; p.arxivID = "2501.12948"; return p }()))

        // --- questions the grader must answer
        var asked = Paper(arxivID: "3000.00001")
        asked.body = """
        ## Claim, in my words

        Filler tokens carry real computation.

        ## Evidence — what convinced me, or didn't

        Is the depth-order result robust to longer sequences?

        ## What I didn't understand

        No idea why the probe recovers anything at all here.
        Also unclear how they rule out the tokenizer explaining it.

        ## Connections
        """
        let q = asked.questions
        check("the confusion section is taken whole",
              q.confusionSection.contains("why the probe recovers")
                && q.confusionSection.contains("rule out the tokenizer"),
              "a confusion with a full stop is still a question")
        check("a question elsewhere in the note is found",
              q.elsewhere == ["Is the depth-order result robust to longer sequences?"])
        check("headings and template comments are not questions",
              !q.elsewhere.contains { $0.hasPrefix("#") || $0.hasPrefix("<!--") })
        check("a confusion line is not counted twice",
              !q.elsewhere.contains { q.confusionSection.contains($0) })
        check("every question is counted, not every field",
              q.count == 3, "two confusions plus one question elsewhere, not 2")
        check("an empty note asks nothing",
              Paper(arxivID: "3000.00002").questions.isEmpty,
              "the template's own prompts must not read as questions")

        // --- trusted authors
        // arXiv author search is a text query, so it returns near-misses. Matching
        // loosely here would file a stranger's paper under someone you follow.
        check("exact name matches",
              TrustedAuthors.matches(name: "Owain Evans", in: ["Jan Betley", "Owain Evans"]))
        check("case and accents fold",
              TrustedAuthors.matches(name: "Owain Evans", in: ["OWAIN  EVANS"])
                && TrustedAuthors.matches(name: "Clement Dumas", in: ["Clément Dumas"]))
        check("initials match a full given name",
              TrustedAuthors.matches(name: "Jacob Steinhardt", in: ["J. Steinhardt"]))
        check("a different person with the same surname is rejected",
              !TrustedAuthors.matches(name: "Owain Evans", in: ["Richard Evans"]),
              "the whole reason matching is checked at all")
        check("surname alone is not a match",
              !TrustedAuthors.matches(name: "Owain Evans", in: ["Evans"]))
        check("a middle name is not silently ignored",
              !TrustedAuthors.matches(name: "Owain Evans", in: ["Owain Trevor Evans"]),
              "three names is a different string, not a fuzzy version of two")
        check("no authors, no match", !TrustedAuthors.matches(name: "Owain Evans", in: []))

        let feed = """
        <feed><entry>
          <id>http://arxiv.org/abs/2604.25891v1</id>
          <published>2026-04-30T17:00:00Z</published>
          <title>Conditional misalignment: common interventions
            can hide emergent misalignment</title>
          <author><name>Jan Dubinski</name></author>
          <author><name>Owain Evans</name></author>
        </entry></feed>
        """
        let feedPapers = TrustedAuthors.parse(feed)
        check("author feed parses one entry", feedPapers.count == 1)
        check("id drops the version suffix", feedPapers.first?.arxivID == "2604.25891")
        check("a title wrapped across lines is rejoined",
              feedPapers.first?.title == "Conditional misalignment: common interventions can hide emergent misalignment")
        check("every author is read, not just the first",
              feedPapers.first?.authors == ["Jan Dubinski", "Owain Evans"],
              "a trusted last author is the common case")
        check("publication date parses", feedPapers.first?.year == 2026)

        // Candidates must exclude what is already on the shelf.
        var have = Paper(arxivID: "2604.25891"); have.title = "Already read"
        let fresh = TrustedAuthors.Paper(arxivID: "2607.14345", title: "New one",
                                         authors: ["Owain Evans"], year: 2026, published: Date())
        let old = TrustedAuthors.Paper(arxivID: "1901.00001", title: "Ancient",
                                       authors: ["Owain Evans"], year: 2019,
                                       published: Date(timeIntervalSince1970: 0))
        let authored = Recommender.authorCandidates(
            from: [have],
            found: [("Owain Evans", feedPapers.map {
                TrustedAuthors.Paper(arxivID: $0.arxivID, title: $0.title,
                                     authors: $0.authors, year: $0.year, published: Date())
            } + [fresh, old])])
        check("a paper already in the library is not suggested",
              !authored.contains { $0.arxivID == "2604.25891" })
        check("stale work is not presented as news",
              !authored.contains { $0.arxivID == "1901.00001" }, "2019, past the window")
        check("new work by a followed author is suggested",
              authored.contains { $0.arxivID == "2607.14345" })
        check("the suggestion says who it came from",
              authored.first?.source == .author("Owain Evans"))

        // --- whole-library ranking
        let quota = Ranker.targetCounts(for: 69)
        check("band quotas account for every paper",
              quota.reduce(0) { $0 + $1.1 } == 69,
              quota.map { "\($0.0.label) \($0.1)" }.joined(separator: " "))
        check("quotas leave the top band scarce",
              (quota.first { $0.0 == .gold }?.1 ?? 0) <= 3, "a common GOLD means nothing")
        check("odd sizes still account exactly",
              [8, 13, 47, 101, 999].allSatisfy { n in
                  Ranker.targetCounts(for: n).reduce(0) { $0 + $1.1 } == n
              })
        check("a tiny library does not pretend to four bands",
              Ranker.targetCounts(for: 5).reduce(0) { $0 + $1.1 } == 5
                && (Ranker.targetCounts(for: 5).first { $0.0 == .gold }?.1 ?? 0) == 0)

        let known: Set<String> = ["2501.12948", "2402.03300", "2407.21783"]
        let placed = Ranker.parse("""
        Here is the ranking:
        2501.12948  GOLD  redirects the agenda outright
        9999.99999  GOLD  not in the library at all
        2402.03300  SOLID  the algorithm everything else runs on
        2501.12948  THIN  duplicate line, should be ignored
        2407.21783  THIN   a model card, nothing learned
        """, known: known)
        check("ranking parses in order",
              placed.map(\.arxivID) == ["2501.12948", "2402.03300", "2407.21783"])
        check("ranks are 1-based and contiguous",
              placed.map(\.rank) == [1, 2, 3],
              "a stray preamble line must not shift every rank")
        check("unknown ids are dropped", !placed.contains { $0.arxivID == "9999.99999" })
        check("a repeated id is not ranked twice",
              placed.filter { $0.arxivID == "2501.12948" }.count == 1)
        check("bands and comparative reasons survive",
              placed[0].band == .gold && placed[2].band == .thin
                && placed[2].reason.contains("nothing learned"))

        let parsed = Recommender.parseVerdict("VERDICT: ESSENTIAL\nWHY: introduces GRPO.")
        check("judge reply parses", parsed.verdict == "ESSENTIAL" && parsed.reason.contains("GRPO"))
        let junk = Recommender.parseVerdict("I think this paper is quite good actually")
        check("unparseable judge reply is flagged", junk.verdict == "UNRATED",
              "never silently presented as a real verdict")

        // A real reply from a run where the judge could not verify the paper.
        let hedged = Recommender.parseVerdict(
            "VERDICT: ESSENTIAL (PROVISIONAL)\nWHY: cited by 19 of their papers.")
        check("qualified verdict snaps back onto the scale",
              hedged.verdict == "ESSENTIAL" && Recommender.ranking[hedged.verdict] == 0,
              "otherwise it ranks below SKIP and shows up grey")
        check("the qualifier survives in the reason",
              hedged.reason.contains("PROVISIONAL"),
              "the hedge is information, not noise")

        // --- the judge's subprocess plumbing
        // A pipe nobody reads holds 64 KB and then blocks the writer forever.
        // 200 KB to stderr through the judge's own code path: if stderr is not
        // being drained, the child never reaches its echo, the ten-second
        // timeout fires, and this comes back nil instead of OK.
        let chatty = Judge.run(executable: "/bin/bash",
                               arguments: ["-c", "yes | head -c 200000 >&2; echo OK"],
                               stdin: "", timeout: 10)
        check("a child flooding stderr cannot deadlock the judge", chatty == "OK",
              "stdout and stderr each drain on their own queue")

        // --- sort orders
        func dated(_ id: String, _ year: Int?, cites: Int = 0, read: Bool = false) -> Paper {
            var q = Paper(arxivID: id); q.year = year; q.citations = cites
            q.title = "T" + id
            if read { q.body = Paper.template + "\nwrote something" }
            return q
        }
        let mixed = [dated("a", nil), dated("b", 2020, cites: 50), dated("c", 2026, cites: 1, read: true)]
        let byDate = SortOrder.apply(.published, to: mixed)
        check("undated papers sink", byDate.first?.arxivID == "c" && byDate.last?.arxivID == "a",
              "a nil year must not float to the top")
        check("most cited sorts correctly",
              SortOrder.apply(.citations, to: mixed).first?.arxivID == "b")
        check("unread first puts unread ahead of read",
              SortOrder.apply(.unread, to: mixed).last?.arxivID == "c",
              "c is the only one with a note written")

        // --- the graph, on real papers
        // Whichever of these has PDFs — directories get reorganised, and a test that
        // silently skips is worse than one that looks somewhere else.
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("Downloads/ai_safety_papers"),
            home.appendingPathComponent("Downloads/papers_to_skim"),
            home.appendingPathComponent("Downloads"),
            home.appendingPathComponent("Papers")
        ]
        var found: [URL] = []
        for dir in candidates {
            let items = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil)) ?? []
            let pdfs = items.filter { $0.pathExtension.lowercased() == "pdf" }
            if pdfs.count >= 4 { found = pdfs; break }
        }
        let pdfs = found.sorted { $0.lastPathComponent < $1.lastPathComponent }.prefix(30)

        if pdfs.isEmpty {
            print("SKIP  citation graph — no PDF corpus found in \(candidates.map(\.lastPathComponent))")
        } else {
            var corpus: [Paper] = []
            for url in pdfs {
                guard let id = PDFRefs.idFromFilename(url.lastPathComponent) else { continue }
                var paper = Paper(arxivID: id)
                paper.title = url.deletingPathExtension().lastPathComponent
                    .replacingOccurrences(of: "_", with: " ")
                paper.refs = PDFRefs.references(in: url, excluding: id)
                corpus.append(paper)
            }
            let withRefs = corpus.filter { !$0.refs.isEmpty }.count
            // This *is* a capability assertion: extraction working at all is the
            // thing the whole graph depends on.
            check("references extracted", withRefs == corpus.count,
                  "\(withRefs)/\(corpus.count) papers yielded references")

            // Density is deliberately NOT asserted. It depends on whether the corpus
            // is topically coherent, which is a property of the reading pile, not of
            // this code — an unrelated pile legitimately produces no edges.
            let edges = Relations.edges(in: corpus)
            var degree: [String: Int] = [:]
            for (a, b, _) in edges { degree[a, default: 0] += 1; degree[b, default: 0] += 1 }
            var direct = 0
            for paper in corpus {
                for r in Relations.related(to: paper, in: corpus, limit: 20)
                where r.kind == .cites || r.kind == .citedBy { direct += 1 }
            }
            print("""

              corpus observed (not asserted — density reflects the pile, not the code):
                papers      \(corpus.count)
                edges       \(edges.count)
                connected   \(degree.count)/\(corpus.count)
                direct cites \(direct)
            """)

            print("\n  sample edges:")
            for paper in corpus.prefix(3) {
                let rel = Relations.related(to: paper, in: corpus, limit: 3)
                print("   \(paper.arxivID) \(String(paper.title.prefix(44)))")
                for r in rel {
                    print("      ├─ \(r.explanation.padding(toLength: 22, withPad: " ", startingAt: 0))\(r.other.arxivID)")
                }
                if rel.isEmpty { print("      └─ (none)") }
            }
        }

        // --- unsaved edits survive leaving the note
        //
        // The bug this pins down: the draft lived only in memory and ⌘S was
        // the only path to disk, so clicking a different paper — or any
        // background refresh landing mid-sentence — silently reset the note
        // to the template. It cost a real note. These probes drive the actual
        // AppModel select/flush path, inside the temp library set up at the top.
        let model = AppModel.shared
        try? FileManager.default.createDirectory(at: Library.papersDir,
                                                 withIntermediateDirectories: true)
        var probeA = Paper(arxivID: "st-draft-a"); probeA.title = "Draft probe A"
        var probeB = Paper(arxivID: "st-draft-b"); probeB.title = "Draft probe B"
        for probe in [probeA, probeB] {
            try? probe.markdown.write(
                to: Library.papersDir.appendingPathComponent(probe.filename),
                atomically: true, encoding: .utf8)
        }
        Library.shared.reload()
        model.select("st-draft-a")
        check("the draft probe came up", model.draft?.arxivID == "st-draft-a")

        model.draft?.body = "words typed and never explicitly saved"
        model.draft?.verdict = .gold
        model.select("st-draft-b")
        let flushed = Library.shared.paper(withID: "st-draft-a")
        check("leaving a note writes the edits through",
              flushed?.body == "words typed and never explicitly saved",
              "clicking another paper used to discard the draft outright")
        check("the verdict travels with them", flushed?.verdict == .gold,
              "the picker wrote only to memory too")

        model.select("st-draft-a")
        check("coming back shows the words, not the template",
              model.draft?.body == "words typed and never explicitly saved")

        model.draft?.body = "a second burst of typing"
        model.refresh()
        check("a background refresh cannot clobber the draft",
              model.draft?.body == "a second burst of typing",
              "refresh reloads the draft from disk, so the flush must run first")

        // The flush writes only what the editor owns: a queue position that
        // landed on disk after the draft was loaded must survive the flush.
        if var q = Library.shared.paper(withID: "st-draft-a") {
            q.queuePosition = 3
            Library.shared.save(q, commit: false)
        }
        model.draft?.body = "a third burst"
        model.flushDraft()
        check("the flush does not write the draft's stale fields over disk",
              Library.shared.paper(withID: "st-draft-a")?.queuePosition == 3,
              "writing the whole draft would undo whatever landed since it loaded")

        // --- scoped recommendations
        //
        // The Next window can recommend for the whole library, one project,
        // or the trail from a single paper. The scope is what the sources,
        // the seeds and the judge all read, so it is pinned here.
        let scopedShelf: [Paper] = {
            var a = Paper(arxivID: "2501.11111"); a.project = "Chunky RL"
            var b = Paper(arxivID: "2501.22222"); b.project = "chunky rl"
            var c = Paper(arxivID: "2501.33333"); c.archaic = true
            let d = Paper(arxivID: "2501.44444")
            return [a, b, c, d]
        }()
        check("the library scope keeps the archaic filter",
              Recommender.scoped(scopedShelf, to: .library).map(\.arxivID)
                  == ["2501.11111", "2501.22222", "2501.44444"],
              "old reading is not evidence of what to read next")
        check("a project scope is its papers, case-insensitively",
              Recommender.scoped(scopedShelf, to: .project("CHUNKY rl")).map(\.arxivID)
                  == ["2501.11111", "2501.22222"])
        check("a paper scope is that paper, even archived",
              Recommender.scoped(scopedShelf, to: .paper("2501.33333v2")).map(\.arxivID)
                  == ["2501.33333"],
              "asking what follows a paper is a question about that paper")
        check("the citing bar drops with the scope",
              Recommender.minimumCiting(for: .library, count: 100) == 3
              && Recommender.minimumCiting(for: .paper("x"), count: 1) == 1
              && Recommender.minimumCiting(for: .project("p"), count: 2) == 1
              && Recommender.minimumCiting(for: .project("p"), count: 6) == 2,
              "one paper cannot agree with itself three times")

        // --- web pages as entries
        //
        // A blog post becomes a hand-keyed paper: URL-slug key, the page's own
        // title/author/date, and a stored source URL. The parsers are pure so
        // they run here against captured pages; the network half is what
        // --peek-url exists to check by hand.
        let lwURL = URL(string: "https://www.lesswrong.com/posts/munJKF7iWMsWJLAH2/"
            + "astra-and-fable-still-hack-on-simple-variants-of-alignment")!
        check("a blog URL is ingestable, an arXiv URL is not",
              WebIngest.ingestableURL(lwURL.absoluteString) != nil
              && WebIngest.ingestableURL("https://arxiv.org/abs/2510.23966") == nil
              && WebIngest.ingestableURL("2510.23966") == nil,
              "arXiv URLs must keep resolving to real paper keys")
        check("the key comes from the slug, not the random document id",
              WebIngest.key(for: lwURL) == "lesswrong-astra-and-fable-still-hack-on",
              "got \(WebIngest.key(for: lwURL))")
        check("the ForumMagnum post id is found",
              WebIngest.forumMagnumPostID(lwURL) == "munJKF7iWMsWJLAH2")

        // The actual reply the LessWrong API gave for that post, captured.
        let lwReply = """
        {"data":{"post":{"result":{"title":"Astra and Fable still hack on simple \
        variants of alignment evals from 2025 ","postedAt":"2026-09-08T15:05:00.657Z",\
        "user":{"displayName":"Dean Valentine"},"coauthors":[]}}}}
        """.data(using: .utf8)!
        let lw = WebIngest.parseForumMagnum(lwReply)
        check("the LessWrong reply parses whole",
              lw?.title == "Astra and Fable still hack on simple variants of alignment evals from 2025"
              && lw?.authors == ["Dean Valentine"]
              && lw?.published != nil,
              "got \(String(describing: lw))")

        let generic = """
        <html><head><title>Fallback &amp; Ignored</title>
        <script type="application/ld+json">
        {"@type":"BlogPosting","headline":"The Real Headline","datePublished":"2026-03-04",
         "author":[{"@type":"Person","name":"Ada Lovelace"},{"name":"Alan Turing"}]}
        </script></head></html>
        """
        let ld = WebIngest.metadata(fromHTML: generic)
        check("JSON-LD wins over the title element",
              ld.title == "The Real Headline" && ld.authors == ["Ada Lovelace", "Alan Turing"],
              "got \(ld.title) / \(ld.authors)")
        check("a plain date parses", ld.published != nil)

        let ogOnly = """
        <meta content="Reversed &#39;Order&#39; Post" property="og:title">
        <meta name="author" content="Grace Hopper">
        <meta property="article:published_time" content="2026-01-15T09:00:00Z">
        """
        let og = WebIngest.metadata(fromHTML: ogOnly)
        check("OpenGraph carries the day when there is no JSON-LD",
              og.title == "Reversed 'Order' Post" && og.authors == ["Grace Hopper"]
              && og.published != nil,
              "attribute order varies by site, and entities appear in real titles")
        check("a page with nothing declared still yields its title element",
              WebIngest.metadata(fromHTML: "<title>Just a Title</title>").title == "Just a Title")

        var web = Paper(arxivID: "lesswrong-astra-and-fable-still-hack-on")
        web.title = "Astra and Fable still hack"
        web.sourceURL = lwURL.absoluteString
        web.publishedOn = WebIngest.parseDate("2026-09-08T15:05:00.657Z")
        let webBack = Paper(markdown: web.markdown)
        check("round-trip: source URL and published date survive",
              webBack?.sourceURL == web.sourceURL && webBack?.publishedOn != nil)
        check("papers never grow url or published fields",
              !Paper(arxivID: "2510.23966").markdown.contains("url:")
              && !Paper(arxivID: "2510.23966").markdown.contains("published:"),
              "every pre-existing file must stay byte-identical")
        check("a web entry links to its source, labeled by host",
              web.externalURL?.absoluteString == lwURL.absoluteString
              && web.externalLinkLabel == "lesswrong.com")
        check("a web entry sorts by its declared month",
              web.published == (2026, 9),
              "the id carries no date, so without this it sinks to the bottom")

        // --- repairing a .pdf-keyed paper
        //
        // Offline (fetchMetadata: false): what must survive a re-key is the
        // note text, the project tag, and the file being replaced rather than
        // duplicated.
        var broken = Paper(arxivID: "2510.11111v2.pdf")
        broken.body = "## Summary\n\nWords that must survive the re-key."
        broken.project = "Chunky RL"
        try? broken.markdown.write(
            to: Library.papersDir.appendingPathComponent(broken.filename),
            atomically: true, encoding: .utf8)
        Library.shared.reload()
        let repair = Commands.repairCore(fetchMetadata: false)
        check("the broken key is repaired", repair.rekeyed == 1,
              "got \(repair)")
        let fixedPaper = Library.shared.paper(withID: "2510.11111")
        check("the repaired paper answers to its clean id",
              fixedPaper?.arxivID == "2510.11111"
              && fixedPaper?.isArxiv == true,
              "isArxiv is what turns the arXiv link and metadata lookups back on")
        check("its words and project tag survived",
              fixedPaper?.body.contains("Words that must survive") == true
              && fixedPaper?.project == "Chunky RL")
        check("the old file is gone, not duplicated",
              (try? FileManager.default.contentsOfDirectory(atPath: Library.papersDir.path))?
                  .filter { $0.hasPrefix("2510.11111") }.count == 1)
        check("running the repair again finds nothing to do",
              Commands.repairCore(fetchMetadata: false).rekeyed == 0)

        // --- projects can be recoloured and deleted after the fact
        var projProbe = Paper(arxivID: "st-proj-a"); projProbe.title = "Project probe"
        try? projProbe.markdown.write(
            to: Library.papersDir.appendingPathComponent(projProbe.filename),
            atomically: true, encoding: .utf8)
        Library.shared.reload()
        model.refresh()
        model.newProjectTargets = ["st-proj-a"]
        model.createProject(named: "Doomed", colour: .red)
        check("the project exists and its paper is tagged",
              model.project(named: "Doomed")?.colour == .red
              && Library.shared.paper(withID: "st-proj-a")?.project == "Doomed")
        model.recolour(project: "doomed", to: .teal)
        check("a project's colour can change after it is made, case-insensitively",
              model.project(named: "Doomed")?.colour == .teal
              && Projects.load().first { $0.name == "Doomed" }?.colour == .teal,
              "the registry on disk carries the new colour")
        check("deleting counts what it will untag",
              model.papers(inProject: "Doomed") == ["st-proj-a"])
        model.deleteProject(named: "Doomed")
        check("a deleted project is gone from the registry",
              model.project(named: "Doomed") == nil && !Projects.load().contains { $0.name == "Doomed" })
        check("and its papers are untagged, not deleted",
              Library.shared.paper(withID: "st-proj-a") != nil
              && Library.shared.paper(withID: "st-proj-a")?.project == "",
              "the tag leaves the file; the paper stays")

        model.draft = nil
        model.selectedID = nil
        try? FileManager.default.removeItem(at: tempLibrary)

        print(fails == 0 ? "\nALL PASS" : "\n\(fails) FAILURE(S)")
        exit(fails == 0 ? 0 : 1)
    }
}
