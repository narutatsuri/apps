import SwiftUI
import AppKit

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

/// `openWindow` is only reachable from a View, so the menu item is one.
struct GraphCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Citation Graph") { openWindow(id: WindowID.graph) }
            .keyboardShortcut("g", modifiers: .command)
    }
}

/// Viridis. Perceptually uniform and colourblind-safe, so it reads as an ordered
/// scale rather than a rainbow — and close to the ramp Connected Papers uses for year.
enum Viridis {
    private static let stops: [(Double, Double, Double)] = [
        (0.267, 0.005, 0.329), (0.254, 0.265, 0.530), (0.164, 0.471, 0.558),
        (0.135, 0.659, 0.518), (0.478, 0.821, 0.318), (0.993, 0.906, 0.144)
    ]

    static func color(_ t: Double) -> Color {
        let clamped = min(1, max(0, t))
        let scaled = clamped * Double(stops.count - 1)
        let i = min(stops.count - 2, Int(scaled))
        let f = scaled - Double(i)
        let a = stops[i], b = stops[i + 1]
        return Color(.sRGB, red: a.0 + (b.0 - a.0) * f,
                     green: a.1 + (b.1 - a.1) * f,
                     blue: a.2 + (b.2 - a.2) * f, opacity: 1)
    }
}

/// The library as a live citation graph. Nodes have mass and momentum, the canvas
/// pans and zooms, and dragging a paper pulls its neighbours along.
struct GraphView: View {
    @Bindable var model: AppModel
    @Environment(\.colorScheme) private var scheme

    @State private var sim = GraphSim()
    @State private var edges: [(String, String, Double)] = []
    @State private var canvas: CGSize = .zero
    @State private var loadedFor = -1

    // Viewport
    @State private var scale: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var gesture = ViewportGesture()
    @State private var magnifyBase: CGFloat = 1

    /// Archived papers are out of the graph unless asked for. Remembered, so
    /// the choice survives a relaunch — a view setting you have to set again
    /// every time is one you stop using.
    @AppStorage("graph.showArchaic") private var showArchaic = false

    @State private var hovered: String?
    @State private var scrollMonitor: Any?
    @State private var ticker: Timer?

    private var surface: Color { Color(hex: scheme == .dark ? 0x17181C : 0xFBFBFA) }

    /// What the graph is a map of. Everything below reads this rather than
    /// `model.papers`, so the toggle cannot be honoured in one place and
    /// forgotten in another.
    private var shown: [Paper] {
        showArchaic ? model.papers : model.papers.filter { !$0.archaic }
    }

    private var years: (min: Int, max: Int) {
        let ys = shown.compactMap(\.year)
        guard let lo = ys.min(), let hi = ys.max() else { return (2020, 2026) }
        return lo == hi ? (lo - 1, hi) : (lo, hi)
    }

    private var maxCitations: Int { max(1, shown.map(\.citations).max() ?? 1) }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Canvas { context, size in draw(in: context, size: size) }
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p): hovered = node(at: world(p, in: canvas))
                        case .ended: hovered = nil
                        }
                    }
                    .gesture(dragGesture)
                    .gesture(MagnifyGesture()
                        .onChanged { v in
                            scale = min(4, max(0.25, magnifyBase * v.magnification))
                        }
                        .onEnded { _ in magnifyBase = scale })

                legend
                if let hovered, let paper = shown.first(where: { $0.arxivID == hovered }) {
                    card(paper).padding(.top, 62).padding(.leading, 12)
                }
                controls
                if shown.isEmpty {
                    Text(model.papers.isEmpty
                         ? "Add papers and the graph appears here."
                         : "Every paper here is archived. Turn on \"Archived\" to see them.")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .onAppear {
                canvas = geo.size
                reload(geo.size)
                startTicking()
                installScrollZoom()
            }
            .onDisappear { stopTicking(); removeScrollZoom() }
            .onChange(of: geo.size) { _, new in canvas = new; reload(new) }
            .onChange(of: model.papers.count) { _, _ in reload(geo.size, force: true) }
            .onChange(of: showArchaic) { _, _ in reload(geo.size, force: true) }
        }
        .background(surface)
    }

    // MARK: - Viewport maths

    /// Screen point → graph coordinates. The transform is centre-anchored so zooming
    /// magnifies what you are looking at rather than the top-left corner.
    private func world(_ p: CGPoint, in size: CGSize) -> CGPoint {
        let cx = size.width / 2, cy = size.height / 2
        return CGPoint(x: cx + (p.x - cx - pan.width) / scale,
                       y: cy + (p.y - cy - pan.height) / scale)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                // began() is idempotent — it records the origin once. Re-recording it
                // each frame against a cumulative translation is what made the pan
                // accelerate off-screen.
                gesture.began(hit: node(at: world(value.startLocation, in: canvas)),
                              currentPan: pan)
                if let id = gesture.draggedNode {
                    if sim.dragging != id { sim.dragging = id; model.select(id) }
                    sim.dragTarget = world(value.location, in: canvas)
                    sim.reheat()
                } else if gesture.isPanning {
                    // Pan in screen space, so the graph tracks the cursor 1:1
                    // regardless of zoom.
                    pan = gesture.pan(for: value.translation)
                }
            }
            .onEnded { _ in
                // Releasing leaves the node's velocity intact, so it carries on and
                // settles — the momentum the whole simulation exists for.
                gesture.ended()
                sim.dragging = nil
                sim.reheat(0.35)
            }
    }

    /// Scroll-wheel zoom. SwiftUI has no scroll modifier on macOS, and a *local*
    /// NSEvent monitor sees only this app's events, so it needs no permission.
    private func installScrollZoom() {
        removeScrollZoom()
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            let factor = 1 + event.scrollingDeltaY * 0.006
            scale = min(4, max(0.25, scale * factor))
            magnifyBase = scale
            return event
        }
    }

    private func removeScrollZoom() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
    }

    // MARK: - Simulation

    private func reload(_ size: CGSize, force: Bool = false) {
        guard size.width > 80, size.height > 80 else { return }
        if !force, loadedFor == shown.count, !sim.bodies.isEmpty { return }
        loadedFor = shown.count
        edges = Relations.edges(in: shown)
        var masses: [String: Double] = [:]
        for p in shown { masses[p.arxivID] = Double(radius(p)) / 8.0 }
        sim.load(ids: shown.map(\.arxivID), edges: edges, masses: masses, size: size)
    }

    private func startTicking() {
        stopTicking()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard !sim.isSettled else { return }   // idle costs nothing once still
                sim.step(centre: CGPoint(x: canvas.width / 2, y: canvas.height / 2))
            }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func stopTicking() { ticker?.invalidate(); ticker = nil }

    private func node(at point: CGPoint) -> String? {
        var best: (String, CGFloat)?
        for (id, body) in sim.bodies {
            guard let paper = model.papers.first(where: { $0.arxivID == id }) else { continue }
            let d = hypot(body.position.x - point.x, body.position.y - point.y)
            let r = radius(paper) + 8
            if d <= r, best == nil || d < best!.1 { best = (id, d) }
        }
        return best?.0
    }

    /// Area proportional to citations, so radius follows the square root.
    private func radius(_ paper: Paper) -> CGFloat {
        let t = sqrt(Double(paper.citations)) / sqrt(Double(maxCitations))
        return 7 + CGFloat(t) * 19
    }

    private func tint(_ paper: Paper) -> Color {
        let (lo, hi) = years
        guard let y = paper.year else { return Viridis.color(0.5) }
        return Viridis.color(Double(y - lo) / Double(max(1, hi - lo)))
    }

    private func label(_ paper: Paper) -> String {
        let surname = paper.authors.first.map { name -> String in
            name.contains(",")
                ? String(name.split(separator: ",")[0])
                : (name.split(separator: " ").last.map(String.init) ?? name)
        } ?? paper.arxivID
        return paper.year.map { "\(surname) \($0)" } ?? surname
    }

    // MARK: - Drawing

    private func draw(in context: GraphicsContext, size: CGSize) {
        var context = context
        let cx = size.width / 2, cy = size.height / 2
        context.translateBy(x: cx + pan.width, y: cy + pan.height)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -cx, y: -cy)

        let focus = hovered ?? sim.dragging
        let selected = model.selectedID
        let neighbours: Set<String> = focus.map { id in
            Set(edges.filter { $0.0 == id || $0.1 == id }.flatMap { [$0.0, $0.1] })
        } ?? []
        // One dictionary, not a linear scan per node per frame — the sibling
        // Frontier graph showed where that road ends once the node count grows.
        let byID = Dictionary(uniqueKeysWithValues: model.papers.map { ($0.arxivID, $0) })

        for (a, b, weight) in edges {
            guard let pa = sim.position(a), let pb = sim.position(b) else { continue }
            let touched = focus != nil && (a == focus || b == focus)
            let dim = focus != nil && !touched
            var path = Path()
            path.move(to: pa)
            path.addLine(to: pb)
            context.stroke(path,
                           with: .color(.secondary.opacity(dim ? 0.07 : 0.16 + weight * 0.34)),
                           lineWidth: (touched ? 2.2 : 1.2) / scale)
        }

        for (id, body) in sim.bodies {
            guard let paper = byID[id] else { continue }
            let r = radius(paper)
            let rect = CGRect(x: body.position.x - r, y: body.position.y - r,
                              width: r * 2, height: r * 2)
            let isFocus = id == focus
            let isSelected = id == selected
            let dim = focus != nil && !isFocus && !neighbours.contains(id)

            context.fill(Circle().path(in: rect.insetBy(dx: -2, dy: -2)), with: .color(surface))
            context.fill(Circle().path(in: rect),
                         with: .color(tint(paper).opacity(dim ? 0.22 : 1.0)))

            if isSelected || isFocus {
                context.stroke(Circle().path(in: rect.insetBy(dx: -3.5, dy: -3.5)),
                               with: .color(.primary.opacity(isSelected ? 0.8 : 0.45)),
                               lineWidth: (isSelected ? 2 : 1.5) / scale)
            }
            if paper.isSubstantive {
                context.fill(Circle().path(in: rect.insetBy(dx: r * 0.62, dy: r * 0.62)),
                             with: .color(.white.opacity(dim ? 0.3 : 0.92)))
            }

        }

        // Labels last, and only where they fit. At 65 papers the dense middle was a
        // wall of overlapping text; the important ones now win the space.
        // Ordered by citations so the papers that anchor the field keep their label,
        // with the hovered and selected node always winning.
        var claimed: [CGRect] = []
        let ordered = sim.bodies.compactMap { id, body -> (Paper, CGPoint)? in
            guard let paper = byID[id] else { return nil }
            return (paper, body.position)
        }.sorted { lhs, rhs in
            let lp = lhs.0.arxivID == focus || lhs.0.arxivID == selected
            let rp = rhs.0.arxivID == focus || rhs.0.arxivID == selected
            if lp != rp { return lp }
            return lhs.0.citations > rhs.0.citations
        }

        for (paper, position) in ordered {
            let isFocus = paper.arxivID == focus
            let isSelected = paper.arxivID == selected
            let dim = focus != nil && !isFocus && !neighbours.contains(paper.arxivID)
            let text = label(paper)
            let r = radius(paper)

            // Rough box: the exact metrics are not available inside Canvas, and an
            // approximation is enough to keep labels off one another.
            let width = CGFloat(text.count) * 5.2 / scale
            let height = 12 / scale
            let origin = CGPoint(x: position.x - width / 2, y: position.y + r + 5 / scale)
            let box = CGRect(origin: origin, size: CGSize(width: width, height: height))
            guard !claimed.contains(where: { $0.intersects(box) }) else { continue }
            claimed.append(box.insetBy(dx: -2 / scale, dy: -1 / scale))

            context.draw(
                Text(text)
                    .font(.system(size: 9.5 / scale,
                                  weight: (isFocus || isSelected) ? .semibold : .regular))
                    .foregroundStyle(dim ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary)),
                at: CGPoint(x: position.x, y: position.y + r + 5 / scale), anchor: .top)
        }
    }

    // MARK: - Chrome

    private var controls: some View {
        VStack(spacing: 6) {
            Spacer()
            HStack(spacing: 6) {
                // Down here, where it cannot collide with a node near the top.
                Text("drag to pan · scroll to zoom · drag a paper to move it")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                Spacer()
                Toggle(isOn: $showArchaic) {
                    Text("Archived").font(.system(size: 10))
                }
                .toggleStyle(.checkbox)
                .help("Include papers marked archaic — older work the reading has moved past")
                Button { zoom(1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                Button { zoom(0.8) } label: { Image(systemName: "minus.magnifyingglass") }
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { scale = 1; pan = .zero }
                    magnifyBase = 1
                    reload(canvas, force: true)
                } label: { Image(systemName: "arrow.counterclockwise") }
                    .help("Reset the view and re-settle the graph")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(12)
    }

    private func zoom(_ factor: CGFloat) {
        withAnimation(.easeOut(duration: 0.15)) {
            scale = min(4, max(0.25, scale * factor))
        }
        magnifyBase = scale
    }

    private var legend: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text("YEAR").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
                HStack(spacing: 5) {
                    Text(String(years.min)).font(.system(size: 8)).foregroundStyle(.secondary)
                    LinearGradient(colors: (0...10).map { Viridis.color(Double($0) / 10) },
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: 92, height: 7)
                        .clipShape(Capsule())
                    Text(String(years.max)).font(.system(size: 8)).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("CITATIONS").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
                HStack(alignment: .center, spacing: 5) {
                    Circle().fill(.secondary.opacity(0.55)).frame(width: 7, height: 7)
                    Circle().fill(.secondary.opacity(0.55)).frame(width: 13, height: 13)
                    Circle().fill(.secondary.opacity(0.55)).frame(width: 19, height: 19)
                    Text("0 – \(maxCitations)").font(.system(size: 8)).foregroundStyle(.secondary)
                }
            }
            Text("\(shown.count) papers · \(edges.count) connections"
                 + (showArchaic || shown.count == model.papers.count ? ""
                    : " · \(model.papers.count - shown.count) archived"))
                .font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        .padding(12)
        .allowsHitTesting(false)
    }

    private func card(_ paper: Paper) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(paper.title.isEmpty ? paper.arxivID : paper.title)
                .font(.system(size: 11, weight: .medium)).lineLimit(3)
            Text(paper.authors.prefix(3).joined(separator: ", ")
                 + (paper.authors.count > 3 ? " et al." : ""))
                .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            HStack(spacing: 8) {
                if let y = paper.year { Text(String(y)) }
                Text("\(paper.citations) citations")
                if paper.verdict != .unset { Text(paper.verdict.label).fontWeight(.semibold) }
            }
            .font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        .padding(9)
        .frame(width: 250, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7).fill(.regularMaterial))
        .allowsHitTesting(false)
    }
}
