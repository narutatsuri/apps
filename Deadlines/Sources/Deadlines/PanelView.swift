import SwiftUI

/// What the panel shows, and when it last managed to check.
@MainActor
final class Model: ObservableObject {
    @Published var standings: [Standing] = []
    /// nil until a fetch has succeeded at least once. Shown, because a
    /// countdown is only as trustworthy as the date it counts to.
    @Published var checked: Date?
    @Published var offline = false
    /// Bumped on a timer so the countdowns move without recomputing anything.
    @Published var now = Date()

    func recompute() {
        now = Date()
        standings = Schedule.standings(for: Store.shared.tracked, in: Store.shared.all, now: now)
    }
}

struct PanelView: View {
    @ObservedObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if model.standings.isEmpty {
                Text("Nothing tracked.\nAdd conferences to ~/deadlines/conferences.txt")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(Array(model.standings.enumerated()), id: \.offset) { _, standing in
                        row(standing)
                    }
                }
                .padding(.top, 10)
            }
            footer
                .padding(.top, 12)
        }
        .padding(14)
        // Width fixed, height from the content: a card padded out with empty
        // space reads as a thing that failed to load.
        .frame(width: DesktopWindow.width, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.white.opacity(0.10), lineWidth: 1)
                }
        }
        // Forced dark: the panel sits on a wallpaper, not on a window, so it
        // cannot borrow the system's idea of a background. Light text on a dark
        // card is the one combination that stays readable over any photograph.
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack {
            Text("DEADLINES")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(.white.opacity(0.55))
            Spacer()
            if model.offline {
                Text("offline")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
    }

    @ViewBuilder
    private func row(_ standing: Standing) -> some View {
        switch standing {
        case .upcoming(let deadline):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(deadline.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                    Text("\(deadline.kind.label) · \(deadline.zone)")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.45))
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(Countdown.text(from: model.now, to: deadline.at))
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(colour(for: deadline))
                    Text(Self.day.string(from: deadline.at))
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
        case .unannounced(let conference, let lastKnown):
            HStack(alignment: .firstTextBaseline) {
                Text(conference)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer(minLength: 4)
                // Said outright rather than left blank: a tracked conference
                // with no row reads as "nothing to do", which is a different
                // and much worse claim than "the date is not out yet".
                Text(lastKnown == nil ? "not in the feed" : "next round TBA")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
    }

    private var footer: some View {
        Text(model.checked.map { "checked \(Self.stamp.string(from: $0))" } ?? "not checked yet")
            .font(.system(size: 9))
            .foregroundStyle(.white.opacity(0.3))
    }

    private func colour(for deadline: Deadline) -> Color {
        switch Countdown.urgency(from: model.now, to: deadline.at) {
        case .imminent: return Color(red: 1.0, green: 0.42, blue: 0.38)
        case .soon: return Color(red: 1.0, green: 0.76, blue: 0.33)
        case .distant: return .white
        case .past: return .white.opacity(0.4)
        }
    }

    /// Shown in your own zone, since that is the clock you will be working
    /// against at 3am, with the deadline's own zone spelled out beside it.
    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM HH:mm"
        return f
    }()

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM HH:mm"
        return f
    }()
}
