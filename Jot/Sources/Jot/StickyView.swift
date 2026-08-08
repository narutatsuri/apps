import SwiftUI
import AppKit

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// The inside of a sticky.
///
/// One typeface, one size, one set of markdown rules, every note. That is the
/// whole point: the built-in Stickies app lets every note drift into its own
/// font and colour and size, so a wall of them is unreadable and nothing can be
/// searched or moved between notes without a fight. Colour is the only thing
/// that varies here, and it varies as a *label*, not as formatting.
struct StickyView: View {
    let id: String
    @State private var text: String = ""
    @State private var colour: StickyColour = .yellow
    @State private var rendered = false
    @State private var floats = true
    @State private var showingPalette = false
    @FocusState private var editing: Bool
    /// Held so ⌘B and friends can reach the text view, which owns the selection.
    @State private var editor = EditorHandle()

    private var paper: Color { Color(hex: colour.paper.light) }
    private var paperNS: NSColor {
        let hex = colour.paper.light
        return NSColor(srgbRed: Double((hex >> 16) & 0xFF) / 255,
                       green: Double((hex >> 8) & 0xFF) / 255,
                       blue: Double(hex & 0xFF) / 255, alpha: 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            editorOrPreview
            bar
        }
        .background(paper)
        // The panel's own background shows through at the corners otherwise, and
        // a sticky with a grey rim does not read as a piece of paper.
        .ignoresSafeArea()
        .onAppear(perform: load)
        .onChange(of: text) { _, _ in persist() }
    }

    @ViewBuilder
    private var editorOrPreview: some View {
        if rendered {
            MarkdownPreview(markdown: text, paper: colour)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // Black ink on the paper colour, markdown styled as you type, and
            // paste arrives plain — see MarkdownEditor for why none of those are
            // available from SwiftUI's TextEditor.
            MarkdownEditor(text: $text, paper: paperNS, handle: editor)
                .padding(.top, 20)   // clear of the transparent title bar
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// A thin strip rather than a toolbar: on a 340pt window, chrome is the
    /// difference between a sticky and a text editor.
    private var bar: some View {
        HStack(spacing: 10) {
            Button {
                showingPalette.toggle()
            } label: {
                Circle().fill(paper)
                    .overlay(Circle().strokeBorder(.black.opacity(0.25), lineWidth: 1))
                    .frame(width: 13, height: 13)
            }
            .buttonStyle(.plain)
            .help("Colour")
            .popover(isPresented: $showingPalette, arrowEdge: .bottom) {
                HStack(spacing: 8) {
                    ForEach(StickyColour.allCases, id: \.self) { c in
                        Button {
                            colour = c
                            showingPalette = false
                            persist()
                        } label: {
                            Circle().fill(Color(hex: c.paper.light))
                                .overlay(Circle().strokeBorder(
                                    c == colour ? Color.accentColor : .black.opacity(0.2),
                                    lineWidth: c == colour ? 2 : 1))
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(.plain)
                        .help(c.label)
                    }
                }
                .padding(10)
            }

            Button {
                rendered.toggle()
                persist()
            } label: {
                Image(systemName: rendered ? "pencil" : "eye")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help(rendered ? "Edit (⌘R)" : "Render the markdown (⌘R)")

            Button {
                floats.toggle()
                StickyWindow.show(id, activate: false)?.setFloats(floats)
                persist()
            } label: {
                Image(systemName: floats ? "pin.fill" : "pin.slash")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help(floats ? "Floating above other windows" : "Behaves like a normal window")

            Spacer()

            if !text.isEmpty {
                Text("\(text.count)")
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.black.opacity(0.35))
            }

            Button {
                Store.shared.delete(id)
                StickyWindow.close(id)
            } label: {
                Image(systemName: "trash").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .help("Delete (⌘⌫) — moved to ~/jot/.trash, not gone")
        }
        .foregroundStyle(.black.opacity(0.55))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(paper.brightness(-0.05))
        // Keyboard is the point of this app; every button above has one.
        .background {
            Group {
                Button("") { rendered.toggle(); persist() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("") { Store.shared.delete(id); StickyWindow.close(id) }
                    .keyboardShortcut(.delete, modifiers: .command)
                ForEach(Array(StickyColour.allCases.enumerated()), id: \.offset) { i, c in
                    Button("") { colour = c; persist() }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                }
                // Emphasis (⌘B, ⌘I, ⌘⇧H, ⌘E, ⌘⇧X, ⌘⇧M) lives in the main menu
                // instead, targeting the text view through the responder chain.
                // Two handlers for one key equivalent would wrap the selection
                // twice, and the menu is the one place the shortcuts are also
                // discoverable.
            }
            .opacity(0)
        }
    }

    private func load() {
        guard let s = Store.shared.sticky(id) else { return }
        text = s.text
        colour = s.colour
        rendered = s.rendered
        floats = s.floats
        // A new sticky exists to be typed into immediately.
        if s.text.isEmpty { editing = true }
    }

    private func persist() {
        guard var s = Store.shared.sticky(id) else { return }
        s.text = text
        s.colour = colour
        s.rendered = rendered
        s.floats = floats
        Store.shared.save(s)
    }
}
