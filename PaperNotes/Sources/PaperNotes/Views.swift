import SwiftUI
import UniformTypeIdentifiers

/// Two panes with a draggable divider.
///
/// Deliberately free of GeometryReader: it is greedy in both axes and reports no
/// sensible ideal size, so inside a VStack it shoves its siblings out of the frame —
/// which is what pushed the editor off the top of the window. The left pane carries
/// an explicit width in points and the right one takes what remains, which is plain
/// enough that the parent VStack can lay it out correctly.
struct SplitPane<Left: View, Right: View>: View {
    @Binding var leftWidth: CGFloat
    @ViewBuilder let left: Left
    @ViewBuilder let right: Right

    @State private var widthAtDragStart: CGFloat?

    var body: some View {
        HStack(spacing: 0) {
            left
                .frame(width: leftWidth)
                .frame(maxHeight: .infinity)
                .clipped()
            Divider()
                .overlay(
                    Rectangle().fill(Color.clear)
                        .frame(width: 9)
                        .contentShape(Rectangle())
                        .onHover { inside in
                            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                        }
                        .gesture(
                            DragGesture(minimumDistance: 1)
                                .onChanged { g in
                                    let base = widthAtDragStart ?? leftWidth
                                    if widthAtDragStart == nil { widthAtDragStart = leftWidth }
                                    leftWidth = min(1000, max(300, base + g.translation.width))
                                }
                                .onEnded { _ in widthAtDragStart = nil }
                        )
                )
            right
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Window scene ids. `openWindow(id:)` with an id no scene declares fails silently
/// at runtime, and nothing on this machine can drive the UI to catch that — so the
/// two sides are made to share one symbol instead.
enum WindowID {
    static let main = "main"
    static let graph = "graph"
    static let recommend = "recommend"
}

struct OpenWindowButton: View {
    let id: String
    let title: String
    let icon: String
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            openWindow(id: id)
            NSApp.activate(ignoringOtherApps: true)
        } label: {
            Label(title, systemImage: icon)
        }
        .controlSize(.small)
    }
}

/// In the window's own status bar rather than the toolbar — the graph is the point
/// of the app and a menu-only shortcut hid it completely.
struct GraphButton: View {
    var body: some View {
        OpenWindowButton(id: WindowID.graph, title: "Graph", icon: "circle.hexagongrid")
    }
}

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var editorWidth: CGFloat = 520
    /// The sidebar's selection. Multi-select so the queue action can take several
    /// papers at once; the editor still follows whichever one is the anchor.
    @State private var selection: Set<String> = []
    @State private var query = ""

    /// The selection in the order the list shows it, so queuing three papers
    /// reads them top-to-bottom rather than in Set order — which is arbitrary and
    /// would look like the queue shuffled itself.
    private func orderedSelection() -> [String] {
        model.papers.map(\.arxivID).filter { selection.contains($0) }
    }

    var body: some View {
        // The status bar is a sibling in a VStack, not a safeAreaInset on the split
        // view. Applying safeAreaInset to a NavigationSplitView overrides the
        // automatic title-bar safe area that both panes inherit, which ran the
        // sidebar list and the editor 44pt up underneath the title bar — measured,
        // not guessed: ListCoreScrollView reached y=902 against a content rect of 858.
        VStack(spacing: 0) {
            splitView
            Divider()
            statusBar
        }
        .frame(minWidth: 980, minHeight: 600)
        .sheet(isPresented: $model.showingAdd) { AddPaperSheet(model: model) }
        .sheet(isPresented: Binding(get: { model.gradeResult != nil },
                                    set: { if !$0 { model.gradeResult = nil } })) {
            GradeSheet(model: model)
        }
        .alert("Delete this paper?",
               isPresented: Binding(get: { model.confirmDelete != nil },
                                    set: { if !$0 { model.confirmDelete = nil } })) {
            Button("Cancel", role: .cancel) { model.confirmDelete = nil }
            Button("Delete", role: .destructive) {
                if let p = model.confirmDelete { model.delete(p) }
                model.confirmDelete = nil
            }
        } message: {
            Text(model.confirmDelete.map {
                "\"\($0.title.isEmpty ? $0.arxivID : $0.title)\" and its stored PDF will be removed. The note is in git, so it can be recovered from history."
            } ?? "")
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in model.ingest(fileURL: url) }
                }
            }
            return true
        }
        .onChange(of: selection) { _, new in
            // One row selected drives the editor; a wider selection leaves the
            // editor where it was rather than flickering between papers.
            if new.count == 1, let id = new.first { model.select(id) }
        }
        .task { model.bootstrap() }
    }

    private var splitView: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            if model.draft != nil { editor } else { placeholder }
        }
        // Single-line title, no subtitle: a subtitle makes the macOS title bar two
        // lines tall without the panes' safe area following.
        .navigationTitle("Paper Notes")
        .searchable(text: $query, placement: .sidebar,
                    prompt: "Title, author, id, or anything you wrote")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { model.showingAdd = true } label: { Label("Add paper", systemImage: "plus") }
            }
            ToolbarItem {
                if model.isBusy { ProgressView().controlSize(.small) }
            }
            ToolbarItem {
                if let d = model.draft, !d.pdfPath.isEmpty {
                    Button { model.startReading(d) } label: {
                        Label("Read", systemImage: "doc.richtext")
                    }
                    .help("Open the PDF and move this window to another display")
                }
            }
        }
    }

    private var sidebar: some View {
        // Multi-select, because queuing is the one action you want to do to
        // several papers at once. A single id still drives the editor; the wider
        // selection only feeds the context menu.
        List(selection: $selection) {
            Section {
                Picker("Sort", selection: Binding(
                    get: { model.sort },
                    set: { model.sort = $0; model.refresh() })) {
                    ForEach(SortOrder.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .labelsHidden()
            }
            if !query.isEmpty {
                let hits = Search.matches(query, in: model.papers)
                Section(hits.isEmpty ? "No matches" : "\(hits.count) match\(hits.count == 1 ? "" : "es")") {
                    ForEach(hits, id: \.paper.arxivID) { hit in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hit.paper.title.isEmpty ? hit.paper.arxivID : hit.paper.title)
                                .font(.system(size: 12)).lineLimit(2)
                            if !hit.snippet.isEmpty {
                                Text(hit.snippet)
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            HStack(spacing: 6) {
                                Text(hit.paper.arxivID).font(.system(size: 9).monospaced())
                                if !hit.field.label.isEmpty {
                                    Text(hit.field.label).font(.system(size: 9))
                                }
                            }
                            .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 1)
                        .tag(hit.paper.arxivID)
                        .contextMenu { rowMenu(hit.paper) }
                    }
                }
            } else if !model.upNext.isEmpty {
                Section("Up next · \(model.upNext.count)") {
                    ForEach(model.upNext) { p in
                        HStack(spacing: 7) {
                            Text("\(p.queuePosition)")
                                .font(.system(size: 9, weight: .bold).monospacedDigit())
                                .foregroundStyle(.white)
                                .frame(width: 15, height: 15)
                                .background(Circle().fill(Color(hex: 0x2A78D6)))
                            Text(p.title.isEmpty ? p.arxivID : p.title)
                                .font(.system(size: 12)).lineLimit(1)
                        }
                        .tag(p.arxivID)
                        .contextMenu {
                            Button("Remove from queue") { model.unqueue([p.arxivID]) }
                            if !p.pdfPath.isEmpty {
                                Button("Open PDF") { model.startReading(p) }
                            }
                        }
                    }
                }
            }
            if query.isEmpty {
            Section("Read · \(model.papers.filter(\.isSubstantive).count) of \(model.papers.count)") {
                ForEach(model.papers) { p in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.title.isEmpty ? p.arxivID : p.title)
                            .font(.system(size: 12, weight: p.isSubstantive ? .regular : .light))
                            .foregroundStyle(p.isSubstantive ? .primary : .secondary)
                            .lineLimit(2)
                        HStack(spacing: 6) {
                            if p.starred {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 8))
                                    .foregroundStyle(Color(hex: 0xEDA100))
                            }
                            // Claude's grade until you write your own over it, so the
                            // list is sorted by interest from the moment a paper
                            // lands rather than only after you have read it.
                            if p.effectiveVerdict != .unset {
                                Text(p.effectiveVerdict.label)
                                    .font(.system(size: 8, weight: .semibold))
                                    .padding(.horizontal, 4).padding(.vertical, 1)
                                    .background(Capsule().fill(
                                        p.verdict == .unset ? AnyShapeStyle(.quinary)
                                                            : AnyShapeStyle(.quaternary)))
                            }
                            if model.appraising.contains(p.arxivID) {
                                ProgressView().controlSize(.small).scaleEffect(0.4)
                                    .frame(width: 10, height: 10)
                            }
                            Text(p.arxivID).font(.system(size: 9).monospaced())
                            if !p.refs.isEmpty { Text("\(p.refs.count) refs").font(.system(size: 9)) }
                            if !p.pdfPath.isEmpty { Image(systemName: "doc").font(.system(size: 8)) }
                        }
                        .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                    .tag(p.arxivID)
                    .contextMenu { rowMenu(p) }
                }
            }
            }
        }
        .frame(minWidth: 250)
    }

    /// Shared by the library list and the search results, so an action available
    /// on a paper does not depend on how you found it.
    @ViewBuilder
    private func rowMenu(_ p: Paper) -> some View {
        // Acts on the whole selection when this row is part of it, so
        // right-clicking one of five selected papers queues all five rather than
        // silently just the one under the cursor.
        let targets = selection.contains(p.arxivID) ? orderedSelection() : [p.arxivID]
        if p.isQueued {
            Button("Remove from queue") { model.unqueue(targets) }
        } else {
            Button(targets.count > 1 ? "Read these \(targets.count) next" : "Read next") {
                model.queue(targets)
            }
            Button("Add to end of queue") { model.queue(targets, atFront: false) }
        }
        Divider()
        Button(p.starred ? "Remove star" : "Star this paper") { model.toggleStar(p) }
        if !p.pdfPath.isEmpty {
            Button("Open PDF") { model.startReading(p) }
        }
        Divider()
        // Destructive, and it takes the stored PDF with it, so it asks first
        // rather than relying on undo that does not exist.
        Button("Delete…", role: .destructive) { model.confirmDelete = p }
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 30)).foregroundStyle(.tertiary)
            Text("Add a paper to begin").foregroundStyle(.secondary)
            Text("Drop a PDF here, or right-click one in Finder →\nServices → Add to Paper Notes.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var editor: some View {
        EditorPane(model: model, leftWidth: $editorWidth)
    }
}

/// Extracted so it can be rendered offscreen on its own. ImageRenderer cannot draw a
/// NavigationSplitView — it needs a real window and rasterises as a prohibition
/// glyph — but it renders ordinary SwiftUI content faithfully, which makes this the
/// only way to actually see a layout on a machine without screen-recording access.
struct EditorPane: View {
    @Bindable var model: AppModel
    @Binding var leftWidth: CGFloat

    var body: some View {
        if let draft = model.draft {
            VStack(spacing: 0) {
                NoteHeader(model: model, paper: draft)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 14)
                Divider()
                // Write on the left, see it rendered on the right. Live inline
                // rendering would fight the text cursor; a split does not.
                //
                // Hand-rolled rather than HSplitView: that legacy AppKit container
                // does not honour the window's safe area, which let the editor slide
                // up under the title bar.
                SplitPane(leftWidth: $leftWidth) {
                    TextEditor(text: Binding(
                        get: { model.draft?.body ?? "" },
                        set: { model.draft?.body = $0 }))
                        .font(.system(size: 12.5, design: .monospaced))
                        .lineSpacing(2)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                } right: {
                    MarkdownPreview(markdown: draft.body)
                }
                // layoutPriority(1) makes this the one flexible child: it absorbs
                // whatever the header and related strip leave, and — crucially — is
                // forced to *accept* that height rather than inflating the VStack
                // with an ideal size of its own. Without it a greedy child (a web
                // view reporting its full document height, a text view sized to its
                // content) makes the stack taller than the window, and the overflow
                // goes off the top.
                //
                // No minHeight here: a floor is exactly what lets it exceed the
                // window in the first place.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
                Divider()
                RelatedPanel(model: model).padding(14)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

extension ContentView {
    private var statusBar: some View {
        HStack(spacing: 10) {
            Text(model.status).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if model.unpushed > 0 {
                Text("\(model.unpushed) unpushed").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Toggle("Push to GitHub", isOn: Binding(
                get: { Prefs.pushEnabled },
                set: { Prefs.pushEnabled = $0; if $0 { model.pushIfEnabled() } }))
                .toggleStyle(.checkbox)
                .font(.system(size: 10))
            GraphButton()
            OpenWindowButton(id: WindowID.recommend, title: "Next", icon: "sparkles")
            Button("Save") { model.save() }
                .keyboardShortcut("s", modifiers: .command)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(.bar)
    }
}

struct NoteHeader: View {
    @Bindable var model: AppModel
    let paper: Paper

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(paper.title.isEmpty ? paper.arxivID : paper.title)
                .font(.system(size: 16, weight: .semibold))
                // Two lines maximum. A long title would otherwise change the header's
                // height on every selection and shove the panes below it around.
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if !paper.authors.isEmpty {
                    Text(paper.authors.prefix(3).joined(separator: ", ")
                         + (paper.authors.count > 3 ? " et al." : ""))
                        .lineLimit(1)
                }
                if let y = paper.year { Text(String(y)) }
                if !paper.venue.isEmpty { Text(paper.venue).lineLimit(1) }
                Link("arXiv", destination: URL(string: "https://arxiv.org/abs/\(paper.arxivID)")!)
                Spacer()
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)

            // Its own row. Six segments have a wide intrinsic width, and sharing the
            // metadata line meant one of them got clipped — the authors at 620pt,
            // the picker itself at 700pt.
            HStack(spacing: 10) {
                Picker("", selection: Binding(
                    get: { model.draft?.verdict ?? .unset },
                    set: { model.draft?.verdict = $0 })) {
                    ForEach(Verdict.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .labelsHidden()
                .fixedSize()

                // The star was reachable only by right-clicking the sidebar, which
                // meant the recommender's one input was effectively hidden: 0 of 68
                // papers were starred.
                Button {
                    model.toggleStar(paper)
                } label: {
                    Image(systemName: paper.starred ? "star.fill" : "star")
                        .foregroundStyle(paper.starred ? Color(hex: 0xEDA100) : .secondary)
                }
                .buttonStyle(.borderless)
                .help(paper.starred
                      ? "Starred — counts treble when recommending"
                      : "Star this paper to pull its references up the recommendations")

                Spacer(minLength: 8)

                if model.isGrading {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                }
                Button("Grade my note") { model.gradeCurrentNote() }
                    .controlSize(.small)
                    .disabled(model.isGrading || !(model.draft?.isSubstantive ?? false))
                    // Says *why* it is off. A greyed button with no explanation is
                    // indistinguishable from a broken one.
                    .help(model.draft?.isSubstantive == true
                          ? "Reads the paper and tells you what your note missed or overstated"
                          : "Write a note first — there is nothing to grade yet")
            }
            .padding(.top, 2)
            // The row keeps a fixed height whatever it contains, so selecting a
            // different paper can never shift the panes below it.
            .frame(height: 22)

            appraisalRow
                // Same reason: one line, always, whatever it holds. A reason that
                // wrapped to two lines on some papers would move the editor.
                .frame(height: 15)
        }
    }
}

extension NoteHeader {
    /// Claude's read on whether the idea is worth your time — graded on how
    /// surprising and generative it is, not on how carefully it was executed.
    @ViewBuilder
    var appraisalRow: some View {
        HStack(spacing: 6) {
            if model.appraising.contains(paper.arxivID) {
                ProgressView().controlSize(.small).scaleEffect(0.55)
                    .frame(width: 12, height: 12)
                Text("Claude is reading it…")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            } else if paper.appraisal != .unset {
                Text("Claude: \(paper.appraisal.label)")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                // The position is the honest part. The band is only a coarsening of
                // it, and a band assigned without ranking meant almost nothing.
                if paper.appraisalRank > 0 {
                    Text("#\(paper.appraisalRank) of \(model.papers.filter { $0.appraisalRank > 0 }.count)")
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                }
                Text(paper.appraisalNote)
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.tail)
                    // The full sentence is in the note file either way; the tooltip
                    // saves opening it.
                    .help(paper.appraisalNote)
                if paper.overridesAppraisal {
                    Text("· you said \(paper.verdict.label)")
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            } else if !paper.pdfPath.isEmpty && Judge.isAvailable {
                Button("Ask Claude if it's worth reading") { model.appraise(paper) }
                    .buttonStyle(.link)
                    .font(.system(size: 10))
            }
            Spacer()
        }
    }
}

/// The point of the whole thing: after writing, you are shown what this connects to.
private struct RelatedPanel: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Connected to what you've read")
                .font(.system(size: 11, weight: .medium))
            if model.related.isEmpty {
                Text("Nothing yet — the graph fills in as you add papers that cite each other.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            } else {
                // Fixed height, and fixed-height cards inside it. A horizontal
                // ScrollView is still flexible *vertically*, which made this a second
                // greedy child in a VStack that already has one — and its content
                // height changes with the selection, so the layout shifted whenever a
                // different paper was clicked.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.related) { r in
                            Button { model.select(r.other.arxivID) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(r.explanation)
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundStyle(.secondary)
                                    Text(r.other.title.isEmpty ? r.other.arxivID : r.other.title)
                                        .font(.system(size: 11))
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    Spacer(minLength: 0)
                                }
                                .frame(width: 190, height: 38, alignment: .topLeading)
                                .padding(8)
                                .background(RoundedRectangle(cornerRadius: 6).fill(.quinary))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(height: 54)
            }
        }
        // A constant height whether or not there are relations. Otherwise the strip
        // is 54pt for a connected paper and one line of text for an unconnected one,
        // and everything above it jumps by ~41pt each time the selection changes —
        // measured across the library before this was fixed.
        .frame(maxWidth: .infinity, minHeight: 73, maxHeight: 73, alignment: .topLeading)
    }
}

private struct AddPaperSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var entry = ""
    @State private var pdf: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a paper").font(.system(size: 14, weight: .semibold))
            TextField("arXiv id or URL — e.g. 2510.23966", text: $entry)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 8) {
                Button("Choose PDF…") { pick() }
                if let pdf {
                    Text(pdf.lastPathComponent).font(.system(size: 10)).lineLimit(1)
                        .foregroundStyle(.secondary)
                }
            }
            Text("A PDF is what gives you citation edges — the free APIs return no references for recent preprints. It also opens for reading straight away.")
                .font(.system(size: 9)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    let e = entry, p = pdf
                    Task { await model.add(idOrURL: e.isEmpty ? (p?.lastPathComponent ?? "") : e, pdf: p) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(entry.isEmpty && pdf == nil)
            }
        }
        .padding(18)
        .frame(width: 440)
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.pdf]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { pdf = panel.url }
    }
}
