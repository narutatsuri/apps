import SwiftUI
import AppKit

/// The board: every project side by side on a canvas that scrolls sideways.
/// A project is one column, or — split into threads — one header over a row
/// of sub-columns. Columns never resize to fit; the canvas grows instead,
/// because seeing all of them at once is the point.
struct LanesBoard: View {
    @State private var lanes: [Lane] = []
    /// Held as state purely so a theme change redraws the board: everything
    /// is read from `Theme`, which SwiftUI cannot observe on its own.
    @State private var appearance = Theme.current
    @State private var pendingScroll: String?
    /// The widths of whatever is being dragged, while it is being dragged —
    /// keyed by lane or thread id; a project's edge drags all its threads at
    /// once. The store learns the numbers once, when the hand lets go.
    @State private var liveWidths: [String: CGFloat] = [:]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(lanes) { lane in
                        if lane.isSplit {
                            ProjectColumn(lane: lane, appearance: appearance,
                                          width: { liveWidths[$0] },
                                          onDrag: { id, base, delta in liveWidths = [id: Lane.clampWidth(base + delta)] },
                                          onDragEnd: { _ in commitThreads(lane) })
                                .id(lane.id)
                            // The project's own edge: full height, and it
                            // scales every thread together.
                            ResizeHandle(
                                onDrag: { delta in
                                    let widths = lane.threads.map(\.width)
                                    let scaled = Lane.scaled(widths, toTotal: widths.reduce(0, +) + delta)
                                    liveWidths = Dictionary(uniqueKeysWithValues:
                                        zip(lane.threads.map(\.id), scaled))
                                },
                                onEnd: { commitThreads(lane) },
                                onReset: {
                                    LaneStore.shared.setThreadWidths(lane.id, Dictionary(
                                        uniqueKeysWithValues: lane.threads.map { ($0.id, Lane.defaultWidth) }))
                                })
                        } else {
                            NoteColumn(
                                id: lane.id, modelTitle: lane.title, initialText: lane.text,
                                initialRendered: lane.rendered, appearance: appearance,
                                fileURL: LaneStore.shared.url(for: lane), prominent: true, depth: 0,
                                onText: { LaneStore.shared.update(lane.id, text: $0) },
                                onRename: { LaneStore.shared.rename(lane.id, to: $0) },
                                onRendered: { LaneStore.shared.setRendered(lane.id, $0) },
                                deleteLabel: "Delete lane…",
                                deleteMessage: "The file moves to the lanes folder's .trash — recoverable, not gone.",
                                onDelete: { LaneStore.shared.delete(lane.id) }
                            ) {
                                Button("Add Thread") { LaneStore.shared.addThread(to: lane.id) }
                                Divider()
                                Button("Move Left") { LaneStore.shared.move(lane.id, by: -1) }
                                Button("Move Right") { LaneStore.shared.move(lane.id, by: 1) }
                                Divider()
                                Button("Vault") { LaneStore.shared.vault(lane.id) }
                            }
                            .frame(width: liveWidths[lane.id] ?? lane.width)
                            .id(lane.id)
                            ResizeHandle(
                                onDrag: { delta in liveWidths = [lane.id: Lane.clampWidth(lane.width + delta)] },
                                onEnd: {
                                    if let w = liveWidths[lane.id] { LaneStore.shared.setWidth(lane.id, w) }
                                    liveWidths = [:]
                                },
                                onReset: { LaneStore.shared.setWidth(lane.id, Lane.defaultWidth) })
                        }
                    }
                    addColumn
                }
                .frame(maxHeight: .infinity)
            }
            .onChange(of: pendingScroll) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .trailing) }
                pendingScroll = nil
            }
        }
        .background(Color(nsColor: Theme.paper(.grey)))
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: LaneStore.changed)) { note in
            refresh()
            if let id = note.object as? String { pendingScroll = id }
        }
        .onReceive(NotificationCenter.default.publisher(for: Theme.changed)) { _ in
            appearance = Theme.current
        }
    }

    private func refresh() { lanes = LaneStore.shared.lanes }

    private func commitThreads(_ lane: Lane) {
        defer { liveWidths = [:] }
        let touched = liveWidths.filter { key, _ in lane.threads.contains { $0.id == key } }
        guard !touched.isEmpty else { return }
        LaneStore.shared.setThreadWidths(lane.id, touched)
    }

    private var addColumn: some View {
        Button { LaneStore.shared.add() } label: {
            VStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 18, weight: .light))
                Text("New lane").font(.system(size: 11))
            }
            .foregroundStyle(Color(nsColor: Theme.dimmedInk(0.45)))
            .frame(width: 140)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Add a project column (⌘N)")
    }
}

/// A split project: one header spanning its threads, the threads side by
/// side beneath it, each its own note column with its own width.
struct ProjectColumn: View {
    let lane: Lane
    let appearance: Theme.Appearance
    let width: (String) -> CGFloat?
    let onDrag: (String, CGFloat, CGFloat) -> Void
    let onDragEnd: (String) -> Void

    @State private var title: String
    @State private var confirmingDelete = false
    @FocusState private var editingTitle: Bool

    init(lane: Lane, appearance: Theme.Appearance, width: @escaping (String) -> CGFloat?,
         onDrag: @escaping (String, CGFloat, CGFloat) -> Void, onDragEnd: @escaping (String) -> Void) {
        self.lane = lane
        self.appearance = appearance
        self.width = width
        self.onDrag = onDrag
        self.onDragEnd = onDragEnd
        _title = State(initialValue: lane.title)
    }

    private var paperNS: NSColor { Theme.paper(.grey) }
    private var ink: Color { Color(nsColor: Theme.ink) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            // The project's own words, above the threads.
            NotePane(id: lane.id + ":above", initialText: lane.text, initialRendered: lane.rendered,
                     appearance: appearance,
                     onText: { LaneStore.shared.update(lane.id, text: $0) },
                     onRendered: { LaneStore.shared.setRendered(lane.id, $0) })
                .frame(height: Lane.aboveHeight)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                if lane.threads.isEmpty {
                    Button { LaneStore.shared.addThread(to: lane.id) } label: {
                        Label("Add a thread", systemImage: "plus")
                            .font(.system(size: 11))
                            .foregroundStyle(Color(nsColor: Theme.dimmedInk(0.45)))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                ForEach(Array(lane.threads.enumerated()), id: \.element.id) { index, thread in
                    NoteColumn(
                        id: thread.id, modelTitle: thread.title, initialText: thread.text,
                        initialRendered: thread.rendered, appearance: appearance,
                        fileURL: LaneStore.shared.url(for: thread, in: lane), prominent: false, depth: 1,
                        onText: { LaneStore.shared.updateThread(lane.id, thread.id, text: $0) },
                        onRename: { LaneStore.shared.renameThread(lane.id, thread.id, to: $0) },
                        onRendered: { LaneStore.shared.setThreadRendered(lane.id, thread.id, $0) },
                        deleteLabel: "Delete thread…",
                        deleteMessage: "The thread's file moves to the lanes folder's .trash — recoverable, not gone.",
                        onDelete: { LaneStore.shared.deleteThread(lane.id, thread.id) }
                    ) {
                        Button("Move Left") { LaneStore.shared.moveThread(lane.id, thread.id, by: -1) }
                        Button("Move Right") { LaneStore.shared.moveThread(lane.id, thread.id, by: 1) }
                        Divider()
                        Button("Vault Thread") { LaneStore.shared.vaultThread(lane.id, thread.id) }
                    }
                    .frame(width: width(thread.id) ?? thread.width)
                    // Between threads only; the project's own edge is the
                    // board's full-height handle.
                    if index < lane.threads.count - 1 {
                        ResizeHandle(
                            onDrag: { delta in onDrag(thread.id, thread.width, delta) },
                            onEnd: { onDragEnd(thread.id) },
                            onReset: { LaneStore.shared.setThreadWidth(lane.id, thread.id, Lane.defaultWidth) })
                    }
                }
            }
            .frame(maxHeight: .infinity)
            Divider()
            // And below them — the place for what the threads add up to.
            NotePane(id: lane.id + ":below", initialText: lane.belowText,
                     initialRendered: lane.belowRendered, appearance: appearance,
                     onText: { LaneStore.shared.updateBelow(lane.id, text: $0) },
                     onRendered: { LaneStore.shared.setBelowRendered(lane.id, $0) })
                .frame(height: Lane.belowHeight)
        }
        // With no threads the row is a placeholder, so the project keeps a
        // column's worth of width for its own writing.
        .frame(width: lane.threads.isEmpty ? Lane.defaultWidth : nil)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: paperNS))
        .onChange(of: lane.title) { _, new in title = new }
        .alert("Delete \"\(title)\" and its threads?", isPresented: $confirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { LaneStore.shared.delete(lane.id) }
        } message: {
            Text("The whole folder moves to the lanes folder's .trash — recoverable, not gone.")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            TextField("Project", text: $title)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ink)
                .focused($editingTitle)
                .onSubmit { commitRename() }
                // Clicking away used to discard the name silently: the field
                // kept showing what was typed while the file stayed
                // "Untitled" — until a relaunch revealed it. Three lanes lost
                // their names that way. A rename now lands whenever editing
                // ends, not only on Return.
                .onChange(of: editingTitle) { _, focused in if !focused { commitRename() } }
                // The binding can deliver the final text *after* focus has
                // already left, so a change that arrives while unfocused is
                // the end of an edit too.
                .onChange(of: title) { _, _ in if !editingTitle { commitRename() } }
                .onDisappear { commitRename() }
            Spacer(minLength: 4)
            Text("\(lane.threads.count) threads")
                .font(.system(size: 10))
                .foregroundStyle(ink.opacity(0.4))
            Menu {
                Button("Add Thread") { LaneStore.shared.addThread(to: lane.id) }
                Divider()
                Button("Move Left") { LaneStore.shared.move(lane.id, by: -1) }
                Button("Move Right") { LaneStore.shared.move(lane.id, by: 1) }
                Divider()
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([LaneStore.shared.url(for: lane)])
                }
                if lane.threads.isEmpty {
                    Divider()
                    Button("Merge Back Into One Lane") { LaneStore.shared.unsplit(lane.id) }
                }
                Divider()
                Button("Vault Project") { LaneStore.shared.vault(lane.id) }
                Button("Delete Project…", role: .destructive) { confirmingDelete = true }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 11))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .foregroundStyle(ink.opacity(0.6))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // A shade further from the paper than a thread's header, so the
        // project band reads as the outer frame.
        .background(Color(nsColor: paperNS).brightness(appearance == .dark ? 0.10 : -0.07))
    }

    /// The store decides the name actually used; a failed move reverts the
    /// field to the real name rather than leaving it showing a fiction.
    private func commitRename() {
        guard title != lane.title else { return }
        title = LaneStore.shared.rename(lane.id, to: title) ?? lane.title
    }
}

/// The line on a column's right edge: drag it to resize the column on its
/// left, double-click it to put that column back at the default width.
///
/// One point in the layout — the line itself, full height — with the nine-
/// point grab zone laid *over* it rather than taking up room. When the strip
/// was nine points wide and transparent, every header band had a notch
/// either side of every line; a line that is only a line leaves the bands
/// continuous. `zIndex` keeps the grab zone above the neighbouring columns
/// it overlaps.
struct ResizeHandle: View {
    let onDrag: (CGFloat) -> Void
    let onEnd: () -> Void
    let onReset: () -> Void

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: Theme.dimmedInk(0.18)))
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    // Measured in the window's space, not the handle's own:
                    // the handle moves with the column it resizes, so in its
                    // own space every tick shifted the ruler under the finger
                    // — the jiggle a drag used to have.
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { g in onDrag(g.translation.width) }
                            .onEnded { _ in onEnd() })
                    .onTapGesture(count: 2) { onReset() }
                    .help("Drag to resize · double-click to reset")
            }
            .zIndex(1)
    }
}

/// A note area without a title — the project's own writing above or below
/// its threads. Same editor, same render toggle, tucked into the corner.
struct NotePane: View {
    let id: String
    let initialText: String
    let initialRendered: Bool
    let appearance: Theme.Appearance
    let onText: (String) -> Void
    let onRendered: (Bool) -> Void

    @State private var text: String
    @State private var rendered: Bool
    @State private var editor = EditorHandle()

    init(id: String, initialText: String, initialRendered: Bool, appearance: Theme.Appearance,
         onText: @escaping (String) -> Void, onRendered: @escaping (Bool) -> Void) {
        self.id = id
        self.initialText = initialText
        self.initialRendered = initialRendered
        self.appearance = appearance
        self.onText = onText
        self.onRendered = onRendered
        _text = State(initialValue: initialText)
        _rendered = State(initialValue: initialRendered)
    }

    private var paperNS: NSColor { Theme.paper(.grey) }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if rendered {
                MarkdownPreview(markdown: ImageStore.inlined(text), paper: .grey)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // A project's own areas live inside its folder: one deep.
                MarkdownEditor(text: $text, paper: paperNS, handle: editor, ink: Theme.ink,
                               onImageDrop: { ImageStore.adopt($0, depth: 1) })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Button {
                rendered.toggle()
                onRendered(rendered)
            } label: {
                Image(systemName: rendered ? "pencil" : "eye").font(.system(size: 10))
                    .foregroundStyle(Color(nsColor: Theme.dimmedInk(0.5)))
                    .padding(6)
            }
            .buttonStyle(.plain)
            .help(rendered ? "Edit" : "Render the markdown")
        }
        .background(Color(nsColor: paperNS))
        .onChange(of: text) { _, new in onText(new) }
    }
}

/// One note column — a whole lane, or one thread of a split project. The
/// editor is Jot's, verbatim: same markers, same maths, same shortcuts,
/// because the whole reason to build this beside Jot is to write here the
/// way you already write there. What differs between a lane and a thread is
/// only whom the edits are reported to and what the ⋯ menu offers.
struct NoteColumn<Extra: View>: View {
    let id: String
    let modelTitle: String
    let initialText: String
    let initialRendered: Bool
    let appearance: Theme.Appearance
    let fileURL: URL
    let prominent: Bool
    /// Folders between this file and the lanes folder — what a dropped
    /// picture's relative link has to climb.
    let depth: Int
    let onText: (String) -> Void
    let onRename: (String) -> String?
    let onRendered: (Bool) -> Void
    let deleteLabel: String?
    let deleteMessage: String
    let onDelete: () -> Void
    @ViewBuilder let extraItems: () -> Extra

    @State private var text: String
    @State private var title: String
    @State private var rendered: Bool
    @State private var editor = EditorHandle()
    @State private var confirmingDelete = false
    @FocusState private var editingTitle: Bool

    init(id: String, modelTitle: String, initialText: String, initialRendered: Bool,
         appearance: Theme.Appearance, fileURL: URL, prominent: Bool, depth: Int,
         onText: @escaping (String) -> Void, onRename: @escaping (String) -> String?,
         onRendered: @escaping (Bool) -> Void, deleteLabel: String?, deleteMessage: String,
         onDelete: @escaping () -> Void, @ViewBuilder extraItems: @escaping () -> Extra) {
        self.id = id
        self.modelTitle = modelTitle
        self.initialText = initialText
        self.initialRendered = initialRendered
        self.appearance = appearance
        self.fileURL = fileURL
        self.prominent = prominent
        self.depth = depth
        self.onText = onText
        self.onRename = onRename
        self.onRendered = onRendered
        self.deleteLabel = deleteLabel
        self.deleteMessage = deleteMessage
        self.onDelete = onDelete
        self.extraItems = extraItems
        _text = State(initialValue: initialText)
        _title = State(initialValue: modelTitle)
        _rendered = State(initialValue: initialRendered)
    }

    private var paperNS: NSColor { Theme.paper(.grey) }
    private var ink: Color { Color(nsColor: Theme.ink) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if rendered {
                MarkdownPreview(markdown: ImageStore.inlined(text), paper: .grey)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MarkdownEditor(text: $text, paper: paperNS, handle: editor, ink: Theme.ink,
                               onImageDrop: { ImageStore.adopt($0, depth: depth) })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: paperNS))
        .onChange(of: text) { _, new in onText(new) }
        // The store may have sanitised or de-duplicated the name.
        .onChange(of: modelTitle) { _, new in title = new }
        .alert("Delete \"\(title)\"?", isPresented: $confirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { onDelete() }
        } message: { Text(deleteMessage) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            TextField(prominent ? "Project" : "Thread", text: $title)
                .textFieldStyle(.plain)
                .font(.system(size: prominent ? 13 : 12, weight: prominent ? .semibold : .medium))
                .foregroundStyle(ink)
                .focused($editingTitle)
                .onSubmit { commitRename() }
                // Same as the project header: a name lands when editing ends,
                // not only on Return — clicking away used to lose it.
                .onChange(of: editingTitle) { _, focused in if !focused { commitRename() } }
                // The binding can deliver the final text *after* focus has
                // already left, so a change that arrives while unfocused is
                // the end of an edit too.
                .onChange(of: title) { _, _ in if !editingTitle { commitRename() } }
                .onDisappear { commitRename() }
            Spacer(minLength: 4)
            Button {
                rendered.toggle()
                onRendered(rendered)
            } label: {
                Image(systemName: rendered ? "pencil" : "eye").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help(rendered ? "Edit" : "Render the markdown")
            Menu {
                extraItems()
                Divider()
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                }
                if let deleteLabel {
                    Divider()
                    Button(deleteLabel, role: .destructive) { confirmingDelete = true }
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 11))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .foregroundStyle(ink.opacity(0.6))
        .padding(.horizontal, 12)
        .padding(.vertical, prominent ? 8 : 6)
        // Darker than the paper in light mode, lighter in dark — either way
        // the strip has to separate from the writing below it.
        .background(Color(nsColor: paperNS).brightness(appearance == .dark ? 0.06 : -0.04))
    }

    private func commitRename() {
        guard title != modelTitle else { return }
        title = onRename(title) ?? modelTitle
    }
}
