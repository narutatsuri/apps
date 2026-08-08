import SwiftUI
import AppKit

/// `--snapshot <path.png> [width height]`
///
/// Renders the editor offscreen with ImageRenderer. Screen recording is not permitted
/// on this machine, so `screencapture` cannot verify layout; this can. Every layout
/// bug so far — the title overlapping the note, the editor pushed off the top — was
/// invisible to every other check available.
enum Snapshot {
    @MainActor
    static func run(_ arguments: [String]) -> Never {
        let path = arguments.first ?? "/tmp/papernotes.png"
        let width = arguments.count > 1 ? Double(arguments[1]) ?? 1200 : 1200
        let height = arguments.count > 2 ? Double(arguments[2]) ?? 800 : 800

        Library.shared.bootstrap()
        let model = AppModel.shared
        model.refresh()
        // The paper with the most relations, not simply the first: the related strip
        // is only present when there are relations, so selecting an unconnected paper
        // measures the one case that cannot show the fault.
        // An explicit id wins, so a specific paper's header can be looked at; the
        // default is the paper with the most relations, not simply the first.
        let requested = arguments.dropFirst(3).first { PDFRefs.normalise($0).contains(".") }
        let richest = requested.flatMap { Library.shared.paper(withID: PDFRefs.normalise($0)) }
            ?? model.papers.max {
                Relations.related(to: $0, in: model.papers).count
                    < Relations.related(to: $1, in: model.papers).count
            }
        if let richest {
            model.select(richest.arxivID)
            print("selected \(richest.arxivID) with \(model.related.count) relation(s)")
        }

        // The editor pane, not ContentView: NavigationSplitView rasterises as a
        // prohibition glyph under ImageRenderer, and the layout under test is in here.
        let width0 = Binding.constant(CGFloat(width * 0.45))

        // height <= 0 measures instead of clamping: constrain only the width and see
        // what height the layout *demands*. A demand far above the window is exactly
        // what pushes content out of view, and clamping the frame hides it.
        if height <= 0 {
            // Every paper, because the reported fault appears when the selection
            // changes. A height that varies between papers is the layout shifting
            // under the reader; a constant one means the pane is stable.
            // The header, not the whole pane. The pane's intrinsic height varies
            // with how much you have written, which is correct — the flexible
            // middle child absorbs that. What must never vary is the chrome above
            // it, because that is what shifts the editor under the cursor when you
            // click a different paper.
            var heights: [Double] = []
            for paper in model.papers {
                model.select(paper.arxivID)
                let probe = NoteHeader(model: model, paper: paper).frame(width: width - 32)
                let sizer = ImageRenderer(content: probe)
                sizer.scale = 1
                let h = Double(sizer.nsImage?.size.height ?? 0)
                heights.append(h)
                print(String(format: "  %-12s %4.0f pt header  %2d relation(s)  %@",
                             (paper.arxivID as NSString).utf8String!, h,
                             model.related.count, String(paper.title.prefix(38))))
            }
            let spread = (heights.max() ?? 0) - (heights.min() ?? 0)
            print(String(format: "\nspread across papers: %.0f pt", spread))
            print(spread < 1
                  ? "stable — selecting a different paper does not move the editor"
                  : "UNSTABLE — the header resizes, which shifts everything below it")
            exit(0)
        }

        // `recommend` stands the list up on fabricated candidates. The real ones need
        // a judge and several minutes; what a snapshot can check is whether a long
        // title, a long reason and a badge lay out together, and that needs no judge.
        if arguments.contains("recommend") {
            model.recommendations = Snapshot.sampleCandidates
        }
        if arguments.contains("grade") {
            model.gradeResult = Snapshot.sampleGrade
        }

        let view = AnyView(
            arguments.contains("graph")
                ? AnyView(GraphView(model: model).frame(width: width, height: height))
                : arguments.contains("grade")
                ? AnyView(GradeSheet(model: model).frame(width: width, height: height))
                : arguments.contains("recommend")
                ? AnyView(RecommendationsView(model: model, scrolls: false).frame(width: width, height: height))
                : AnyView(EditorPane(model: model, leftWidth: width0).frame(width: width, height: height))
        )
        .background(Color(nsColor: .windowBackgroundColor))

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("render failed"); exit(1)
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("wrote \(path)  \(Int(width))x\(Int(height))  papers=\(model.papers.count)")
        } catch {
            print("write failed: \(error.localizedDescription)"); exit(1)
        }
        exit(0)
    }

    /// A real reply, shortened. The markdown body renders in a WKWebView that
    /// ImageRenderer cannot draw, so what a snapshot checks here is the native
    /// chrome around it — badge, title, footer — and that the body gets the space.
    static let sampleGrade = """
    ANSWERS:
    - **Why only under shared initialization.** When $\\theta^0_S = \\theta^0_T$ the
      student already predicts what the un-finetuned teacher predicts, so the
      zeroth-order term of its gradient vanishes.
    - **One step, not convergence.** Theorem 1 is a directional claim about a single
      infinitesimal gradient step, with no statement about iterating.
    GRADE: THIN
    MISSED: The misalignment transmission, which is what turns this from an owl
    curiosity into a claim that filtering cannot make distillation safe.
    CHECK: "the numbers carry no semantic trace" is stated as established, but the
    paper hedges it twice and calls its own definition "not a rigorous definition".
    ASK: What was the control condition in the animal experiment, and which
    alternative explanation does it eliminate?
    """

    /// Real ids and real verdicts from a recommender run, so the widths in the
    /// snapshot are the widths you will actually see.
    static let sampleCandidates: [Recommender.Candidate] = [
        // One from each source, so the snapshot shows both row shapes.
        .init(arxivID: "2604.25891", weight: 22, citedByYours: [],
              source: .author("Owain Evans"),
              title: "Conditional misalignment: common interventions can hide emergent misalignment",
              authors: ["Jan Dubiński", "Jan Betley", "Anna Sztyber-Betley", "Daniel Tan"],
              year: 2026, citations: 0, verdict: "ESSENTIAL",
              reason: "Directly extends the emergent-misalignment thread your library is built around, and nothing in it cites this yet."),
        .init(arxivID: "2501.12948", weight: 25, citedByYours: Array(repeating: "x", count: 25),
              title: "DeepSeek-R1: Incentivizing Reasoning Capability in LLMs via Reinforcement Learning",
              authors: ["DeepSeek-AI", "Daya Guo", "Dejian Yang", "Haowei Zhang"], year: 2025,
              citations: 0, verdict: "ESSENTIAL",
              reason: "The foundational RLVR paper underlying 25 of their papers — none of which actually is it; their library studies R1-style reasoning without the primary source."),
        .init(arxivID: "2505.09388", weight: 17, citedByYours: Array(repeating: "x", count: 17),
              title: "Qwen3 Technical Report",
              authors: ["An Yang", "Anfeng Li", "Baosong Yang", "Beichen Zhang"], year: 2025,
              citations: 98, verdict: "USEFUL",
              reason: "Base-model card for the workhorse backbone in most of their RL papers — worth skimming for training details, not novel science."),
        .init(arxivID: "2407.21783", weight: 12, citedByYours: Array(repeating: "x", count: 12),
              title: "The Llama 3 Herd of Models",
              authors: ["Aaron Grattafiori", "Abhimanyu Dubey", "Abhinav Jauhri"], year: 2024,
              citations: 0, verdict: "SKIP",
              reason: "A model card they can consult when needed; reading it end to end buys nothing for this agenda.")
    ]
}
