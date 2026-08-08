import SwiftUI

struct PopoverView: View {
    @Bindable var store: UsageStore
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProviderSection(title: "Claude", snapshot: store.claude, tick: store.tick)
            Divider().padding(.vertical, 12)
            ProviderSection(title: "Codex", snapshot: store.codex, tick: store.tick)
            Divider().padding(.top, 12).padding(.bottom, 8)
            footer
        }
        .padding(14)
        .frame(width: 296)
        .task {
            store.start()
            await store.refreshOnOpen()
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 7) {
            Toggle("Open at login", isOn: Binding(
                get: { store.launchAtLogin },
                set: { store.setLaunchAtLogin($0) }
            ))
            .toggleStyle(.checkbox)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)

            if let err = store.loginError {
                Text(err)
                    .font(.system(size: 9))
                    .foregroundStyle(Severity.serious.color(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }

            controls
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Text(refreshedLabel)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer()
            Button {
                Task { await store.manualRefresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .disabled(store.isRefreshing)
            .help("Refresh now")

            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private var refreshedLabel: String {
        _ = store.tick
        guard let at = [store.claude.fetchedAt, store.codex.fetchedAt].compactMap({ $0 }).max() else {
            return store.isRefreshing ? "Refreshing…" : "Not yet loaded"
        }
        let s = Int(-at.timeIntervalSinceNow)
        if s < 60 { return "Updated just now" }
        return "Updated \(s / 60)m ago"
    }
}

private struct ProviderSection: View {
    let title: String
    let snapshot: ProviderSnapshot
    let tick: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                if let plan = snapshot.plan {
                    Text(plan)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(Capsule().fill(.quaternary))
                }
                Spacer()
                if let note = snapshot.note {
                    Text(note).font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }

            if snapshot.meters.isEmpty {
                if let err = snapshot.error {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("No limits reported").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            } else {
                ForEach(snapshot.meters) { MeterRow(meter: $0, tick: tick) }
                // Values stay on screen through a failed refresh; the badge says so.
                if snapshot.isStale, let err = snapshot.error {
                    Label(err, systemImage: "clock.arrow.circlepath")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct MeterRow: View {
    let meter: Meter
    let tick: Int
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(meter.label)
                    .font(.system(size: 11))
                    .foregroundStyle(meter.isActive ? .primary : .secondary)
                    .lineLimit(1)
                if let reset = resetLabel {
                    Text(reset).font(.system(size: 9)).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 6)
                if let sym = meter.severity.symbol {
                    Image(systemName: sym)
                        .font(.system(size: 9))
                        .foregroundStyle(meter.severity.color(scheme))
                }
                Text(Fmt.pct(meter.percent))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
            }
            bar
        }
    }

    private var bar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(meter.severity.color(scheme))
                    .frame(width: max(meter.percent > 0 ? 3 : 0,
                                      geo.size.width * min(meter.percent, 100) / 100))
            }
        }
        .frame(height: 5)
    }

    private var resetLabel: String? {
        _ = tick
        guard let at = meter.resetsAt, let c = Fmt.countdown(to: at) else { return nil }
        return "· \(c)"
    }
}
