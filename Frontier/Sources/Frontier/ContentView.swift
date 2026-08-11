import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: Model
    /// Remembered: which view you were last in is a preference, not a mode you
    /// should have to re-pick every launch.
    @AppStorage("frontier.showGraph") private var showGraph = false
    /// Which rendering of the concept you are reading. Remembered, because it
    /// is how you like to read rather than a per-concept choice.
    @AppStorage("frontier.walkthrough") private var walkedThrough = true
    @State private var showingImport = false

    /// FRONTIER_BARE=1/2/3 — content bisection levels for the compositing hunt.
    private var bareLevel: Int {
        Int(ProcessInfo.processInfo.environment["FRONTIER_BARE"] ?? "0") ?? 0
    }

    var body: some View {
        Group {
            switch bareLevel {
            case 1:
                ConceptPreview(markdown: "# L1\n\nPane alone under the shared modifiers. $x^2$")
            case 2:
                VStack(spacing: 0) {
                    controlBar
                    Divider()
                    ConceptPreview(markdown: "# L2\n\nPane plus control bar. $x^2$")
                }
            case 3:
                HStack(spacing: 0) {
                    sidebar.frame(width: 280)
                    Divider()
                    ConceptPreview(markdown: "# L3\n\nPane plus sidebar. $x^2$")
                }
            default:
                realBody
            }
        }
        .onAppear { model.load(); ClickDiagnose.scheduleIfAsked(model: model) }
        // FRONTIER_OVERLAY=1 — the same renderer, same window, *outside* the
        // split view's detail column. Paints here + blank in the pane = the
        // column; blank here too = the whole window cannot composite it.
        .overlay(alignment: .topTrailing) {
            if ProcessInfo.processInfo.environment["FRONTIER_OVERLAY"] == "1" {
                ConceptPreview(markdown: "# Overlay probe\n\nSame window, outside the detail column. $x^2$")
                    .frame(width: 320, height: 180)
                    .border(.red)
            }
        }
        .sheet(isPresented: $showingImport) { ImportSheet(model: model) }
        .alert("Frontier", isPresented: .constant(model.note != nil)) {
            Button("OK") { model.note = nil }
        } message: { Text(model.note ?? "") }
    }

    private var realBody: some View {
        // The controls live in a bar inside the content rather than in a scene
        // toolbar: this window is a plain NSWindow (the SwiftUI Window scene's
        // own window cannot composite a WKWebView on this macOS — see App.swift),
        // and a plain window has no SwiftUI toolbar to put them in.
        VStack(spacing: 0) {
            controlBar
            Divider()
            // A hand-rolled split. NavigationSplitView re-blanked the pane even
            // in a cleanly-created window — it restores column state during
            // setup, which resizes the window before its first commit, the
            // exact move that kills out-of-process compositing (see App.swift).
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 280)
                Divider()
                Group {
                    if showGraph {
                        ConceptGraphView(model: model)
                    } else if let concept = model.current {
                        reading(concept)
                    } else {
                        empty
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Control bar

    private var controlBar: some View {
        HStack(spacing: 10) {
            Picker("", selection: $showGraph) {
                Label("Read", systemImage: "text.alignleft").tag(false)
                Label("Graph", systemImage: "point.3.connected.trianglepath.dotted").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 160)
            .help("Read today's concept, or see the whole graph")

            Spacer()

            // A whole resource — a book, a course PDF, a long post — turned
            // into chained concepts and walked through end to end.
            Button { showingImport = true } label: {
                if model.busy == "import" {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.small)
                        Text(model.importProgress ?? "Importing…").lineLimit(1)
                    }
                } else {
                    Label("Import course", systemImage: "square.and.arrow.down")
                }
            }
            .help("Turn a whole book, course PDF, or long post into concepts and learn it end to end")
            .disabled(model.busy != nil)

            // Named, not just an icon. It spends a minute or two asking for
            // new concepts, which is not something to discover by pressing
            // an unlabelled button and waiting.
            Button { model.grow() } label: {
                if model.busy == "grow" {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.small)
                        Text("Extending…")
                    }
                } else {
                    Label("Extend graph", systemImage: "plus.diamond")
                }
            }
            .help("Ask for more concepts — fills gaps in the graph first. Takes a minute or two.")
            .disabled(model.busy != nil)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        // One membership set, not a nested `session` recomputation per row —
        // that pattern cost ~100 ms per click once the graph reached 275
        // concepts, because session walks the whole dependency graph.
        let todayIDs = Set(model.session.map(\.id))
        return List(selection: $model.selected) {
            Section("Today") {
                ForEach(model.session) { row($0) }
            }
            Section("Ready — \(model.ready.count)") {
                ForEach(model.ready.filter { !todayIDs.contains($0.id) }
                            .prefix(20)) { row($0) }
            }
            // Every imported or followed course, as the whole path in its own
            // reading order. This is where "where is the RLHF book and how do
            // I get through it" is answered — Today and Ready gate what to do
            // this morning, but the road itself was invisible before this.
            Section("Courses") {
                ForEach(courseGroups, id: \.name) { group in
                    DisclosureGroup {
                        ForEach(group.concepts) { row($0) }
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(group.name)
                                .font(.system(size: 11, weight: .medium)).lineLimit(1)
                            Text("\(group.done) of \(group.concepts.count) learned")
                                .font(.system(size: 9)).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            Section("Known — \(model.concepts.filter(\.isKnown).count)") {
                ForEach(model.concepts.filter(\.isKnown).prefix(20)) { row($0) }
            }
        }
        .listStyle(.inset)
    }

    private struct CourseGroup {
        let name: String
        let concepts: [Concept]
        let done: Int
    }

    /// Concepts grouped by the course that taught them, in the order they were
    /// added — which for an imported resource is its own reading order, front
    /// to back. Mark what you already know from the top and the frontier walks
    /// the rest of it in sequence.
    private var courseGroups: [CourseGroup] {
        var byCourse: [String: [Concept]] = [:]
        for c in model.concepts {
            for name in c.courses { byCourse[name, default: []].append(c) }
        }
        return byCourse
            .filter { $0.value.count >= 3 }
            .map { name, list in
                let ordered = list.sorted {
                    $0.addedOn == $1.addedOn ? $0.id < $1.id : $0.addedOn < $1.addedOn
                }
                return CourseGroup(name: name, concepts: ordered,
                                   done: list.filter(\.isKnown).count)
            }
            .sorted { $0.concepts.count > $1.concepts.count }
    }

    private func row(_ c: Concept) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Circle().fill(colour(c)).frame(width: 6, height: 6)
                Text(c.plainTitle).font(.system(size: 12))
                    .lineLimit(1)
            }
            Text(c.area.label.uppercased())
                .font(.system(size: 8, weight: .semibold)).tracking(0.5)
                .foregroundStyle(.tertiary)
        }
        .tag(c.id)
    }

    private func colour(_ c: Concept) -> Color {
        switch c.status {
        case .known: return .green
        case .learning: return .orange
        case .unread: return .secondary.opacity(0.5)
        }
    }

    // MARK: - Reading

    private func reading(_ concept: Concept) -> some View {
        // The entry fills the pane and scrolls itself.
        //
        // It used to be a fixed-width column inside a SwiftUI ScrollView, which
        // left it a narrow strip in the top-left corner of a fullscreen window,
        // and the web view — asked for its size inside a scroll view, where the
        // proposal is unbounded — fell back to a few hundred points and clipped
        // the entry. The renderer scrolls perfectly well on its own.
        VStack(alignment: .leading, spacing: 0) {
            if !concept.requires.isEmpty {
                Text("rests on " + concept.requires.joined(separator: " · "))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .padding(.horizontal, 22).padding(.top, 14)
            }

            if model.busy == concept.id {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Writing it, with sources — this takes a minute or two.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .padding(22)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if concept.isWritten {
                VStack(alignment: .leading, spacing: 0) {
                    modePicker(concept)
                    ConceptPreview(markdown: document(concept))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                // The one flexible child, forced to *accept* the pane's height.
                // Without this the web view reports its full document height —
                // logged at 3,471pt for a 10k-char walkthrough in a 731pt pane —
                // the stack inflates past the window, and the pane shows the
                // empty stretch of an off-screen document: a written concept
                // that reads as a completely blank screen. Same bug, same fix,
                // as PaperNotes' EditorPane; short entries never triggered it,
                // which is why the pane worked until the entries grew.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
            } else {
                // Unwritten: the heading and the reason it is on the list, then
                // the offer to write it — where you are looking, not stranded at
                // the bottom of an empty pane below a hundred points of nothing.
                VStack(alignment: .leading, spacing: 0) {
                    ConceptPreview(markdown: document(concept))
                        .frame(height: 150)
                    unwritten(concept)
                    Spacer(minLength: 0)
                }
            }

            Divider()
            HStack(spacing: 10) {
                Button("I know this") { model.mark(concept, .known) }
                    .disabled(concept.isKnown)
                Button("Still learning") { model.mark(concept, .learning) }
                Spacer()
                if !concept.sources.isEmpty { sourceSummary(concept) }
                if concept.isWritten {
                    Button("Rewrite") { model.write(concept) }
                        .disabled(model.busy != nil)
                }
            }
            .padding(.horizontal, 22).padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Reference or walkthrough.
    ///
    /// Two renderings of the same facts. The entry is dense on purpose — it is
    /// what you want on the fourth reading. The walkthrough introduces every
    /// term as it appears and shows the arithmetic, which is what you want on
    /// the first, and is the difference between reading a page and understanding
    /// it when the area is new.
    @ViewBuilder
    private func modePicker(_ concept: Concept) -> some View {
        HStack(spacing: 10) {
            if !concept.walkthrough.isEmpty {
                Picker("", selection: $walkedThrough) {
                    Text("Walk me through it").tag(true)
                    Text("Reference").tag(false)
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
            } else if model.busy == concept.id {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Working through it from the beginning — a couple of minutes.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            } else {
                Button { model.explain(concept) } label: {
                    Label("Walk me through it", systemImage: "figure.walk")
                }
                .controlSize(.small)
                .disabled(model.busy != nil)
                .help("Rewrite this assuming no background — every term defined as it "
                    + "appears, every number arrived at, nothing left out")
            }
            Spacer()
            if !concept.walkthrough.isEmpty, model.busy != concept.id {
                Button("Redo") { model.explain(concept) }
                    .controlSize(.small)
                    .disabled(model.busy != nil)
            }
        }
        .padding(.horizontal, 22).padding(.top, 10).padding(.bottom, 2)
    }

    /// What "Write it" means, said before it is pressed.
    ///
    /// A concept starts as a title, a reason and its prerequisites; the entry
    /// itself is generated on demand because it costs a minute or two and most
    /// of the graph is there to be navigated, not read.
    private func unwritten(_ concept: Concept) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("No entry yet")
                .font(.system(size: 13, weight: .medium))
            Text("Frontier will ask Claude for an explanation at your level — every "
                 + "claim followed by the source it came from, questions to check "
                 + "yourself against, and anything it could not source listed "
                 + "separately rather than smoothed over. Then it checks that each "
                 + "link resolves. A minute or two.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 460, alignment: .leading)
            Button {
                model.write(concept)
            } label: {
                Label("Write this entry", systemImage: "text.append")
            }
            .disabled(model.busy != nil)
            .help(model.busy == nil ? "Generate the entry, with sources"
                                    : "Busy writing something else")
        }
        .padding(.horizontal, 22)
        .padding(.top, 4)
    }

    /// Sources are listed inside the rendered entry; this is the one-line
    /// verdict on whether their links actually resolve.
    private func sourceSummary(_ c: Concept) -> some View {
        let checked = c.sources.filter { $0.reachable != nil }.count
        let broken = c.sources.filter { $0.reachable == false }.count
        return HStack(spacing: 5) {
            Image(systemName: broken > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(broken > 0 ? .orange : .green)
                .font(.system(size: 10))
            Text(broken > 0 ? "\(broken) of \(c.sources.count) links dead"
                            : "\(checked) source\(checked == 1 ? "" : "s") verified")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    /// The shared builder lives on Concept, so `--render` checks exactly what
    /// this pane shows.
    private func document(_ c: Concept) -> String {
        c.document(preferWalkthrough: walkedThrough)
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Text("Nothing in the graph yet.").font(.system(size: 13))
            Text("Frontier --seed <file> turns a list of half-understood terms into a curriculum.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A resource to learn end to end: a URL or a PDF.
private struct ImportSheet: View {
    @ObservedObject var model: Model
    @Environment(\.dismiss) private var dismiss
    @State private var entry = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import a course").font(.system(size: 14, weight: .semibold))
            TextField("URL or PDF path — e.g. https://rlhfbook.com/", text: $entry)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                Button("Choose PDF…") { pick() }
                if !entry.isEmpty, !entry.hasPrefix("http") {
                    Text((entry as NSString).lastPathComponent)
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Text("The whole resource becomes concepts, chained in its own reading "
                 + "order, so the daily session walks you through it front to back. "
                 + "A book is one model call per chapter — twenty minutes or so for "
                 + "a whole book, and progress lands as it goes.")
                .font(.system(size: 9)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Import") {
                    model.importResource(entry)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(entry.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 460)
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { entry = url.path }
    }
}
