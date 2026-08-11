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

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } detail: {
            if showGraph {
                ConceptGraphView(model: model)
            } else if let concept = model.current {
                reading(concept)
            } else {
                empty
            }
        }
        .toolbar {
            ToolbarItem {
                Picker("", selection: $showGraph) {
                    Image(systemName: "text.alignleft").tag(false)
                    Image(systemName: "point.3.connected.trianglepath.dotted").tag(true)
                }
                .pickerStyle(.segmented)
                .help("Read today's concept, or see the whole graph")
            }
            ToolbarItem {
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
            }
            ToolbarItem {
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
        }
        .onAppear { model.load() }
        .sheet(isPresented: $showingImport) { ImportSheet(model: model) }
        .alert("Frontier", isPresented: .constant(model.note != nil)) {
            Button("OK") { model.note = nil }
        } message: { Text(model.note ?? "") }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $model.selected) {
            Section("Today") {
                ForEach(model.session) { row($0) }
            }
            Section("Ready — \(model.ready.count)") {
                ForEach(model.ready.filter { c in !model.session.contains { $0.id == c.id } }
                            .prefix(20)) { row($0) }
            }
            Section("Known — \(model.concepts.filter(\.isKnown).count)") {
                ForEach(model.concepts.filter(\.isKnown).prefix(20)) { row($0) }
            }
        }
        .listStyle(.sidebar)
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

    /// The concept as one markdown document, so a single renderer typesets all
    /// of it — heading, the one-line reason it is on the list, and the entry.
    private func document(_ c: Concept) -> String {
        var out = "# " + c.title + "\n\n"
        if !c.relevance.isEmpty { out += "*" + c.relevance + "*\n\n" }
        if !c.courses.isEmpty {
            out += "<div class=\"cite\">taught by " + c.courses.joined(separator: " · ") + "</div>\n\n"
        }
        let chosen = (walkedThrough && !c.walkthrough.isEmpty) ? c.walkthrough : c.body
        out += chosen
        if !c.sources.isEmpty {
            out += "\n\n## Sources\n\n"
            for source in c.sources {
                let mark = source.reachable == false ? " — **link does not resolve**"
                         : (source.reachable == true ? "" : " — unchecked")
                out += "- [\(source.title)](\(source.url))\(mark)\n"
            }
        }
        return out
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
