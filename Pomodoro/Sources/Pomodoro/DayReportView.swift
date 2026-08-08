import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }

    /// Categorical slots 1 and 2, in fixed order — focus is always slot 1, break
    /// always slot 2, so the colours never shift meaning. Dark values are their own
    /// steps for the dark surface, not a lightened flip. Both pairs validated at
    /// ΔE 24.7 (protan, light) and 26.8 (protan, dark).
    static func focusSeries(_ scheme: ColorScheme) -> Color {
        Color(hex: scheme == .dark ? 0x3987E5 : 0x2A78D6)
    }

    static func breakSeries(_ scheme: ColorScheme) -> Color {
        Color(hex: scheme == .dark ? 0xD95926 : 0xEB6834)
    }
}

private enum Geo {
    static let label: CGFloat = 48
    static let track: CGFloat = 300
    static let value: CGFloat = 56
    static let bar: CGFloat = 10
}

struct DayReportView: View {
    @State private var day = Date()
    @State private var summary = DaySummary()
    @State private var showTable = false
    @Environment(\.colorScheme) private var scheme

    private let calendar = Calendar.current

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if summary.isEmpty {
                empty
            } else {
                stats
                if showTable { table } else { chart }
                footer
            }
        }
        .padding(20)
        .frame(minWidth: 500, minHeight: 380)
        .task(id: day) { summary = SessionLog.summary(for: day, calendar: calendar) }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(dayTitle).font(.system(size: 16, weight: .semibold))
                if isToday {
                    Text("Today").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            HStack(spacing: 4) {
                Button { step(-1) } label: { Image(systemName: "chevron.left") }
                Button("Today") { day = Date() }.disabled(isToday)
                Button { step(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(isToday)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var isToday: Bool { calendar.isDateInToday(day) }

    private var dayTitle: String {
        day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    private func step(_ days: Int) {
        if let next = calendar.date(byAdding: .day, value: days, to: day) { day = next }
    }

    // MARK: - Summary tiles

    private var stats: some View {
        HStack(spacing: 26) {
            tile("Focus", Fmt.minutes(summary.workMinutes), .focusSeries(scheme))
            tile("Break", Fmt.minutes(summary.breakMinutes), .breakSeries(scheme))
            tile("Sessions", "\(summary.completedFocusSessions)", nil)
            if summary.earlyBreaks > 0 {
                tile("Cut short", "\(summary.earlyBreaks)", nil)
            }
            if let share = summary.focusShare {
                tile("Focus share", "\(Int((share * 100).rounded()))%", nil)
            }
            Spacer()
        }
    }

    /// The swatch carries identity; the number stays in text ink.
    private func tile(_ label: String, _ value: String, _ swatch: Color?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if let swatch {
                    RoundedRectangle(cornerRadius: 1.5).fill(swatch).frame(width: 7, height: 7)
                }
                Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Text(value).font(.system(size: 19, weight: .medium).monospacedDigit())
        }
    }

    // MARK: - Chart

    private var chart: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                gridlines
                VStack(spacing: 5) {
                    ForEach(summary.buckets) { HourRow(bucket: $0) }
                }
            }
            axis
        }
    }

    /// Recessive quarter-hour rules, so bar lengths can be compared across rows.
    private var gridlines: some View {
        HStack(spacing: 0) {
            Spacer().frame(width: Geo.label)
            ZStack(alignment: .leading) {
                ForEach([0.25, 0.5, 0.75, 1.0], id: \.self) { f in
                    Rectangle()
                        .fill(.quaternary)
                        .frame(width: 1)
                        .offset(x: Geo.track * f)
                }
            }
            .frame(width: Geo.track, alignment: .leading)
            Spacer()
        }
        .allowsHitTesting(false)
    }

    private var axis: some View {
        HStack(spacing: 0) {
            Spacer().frame(width: Geo.label)
            ZStack(alignment: .leading) {
                ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { f in
                    Text("\(Int(f * 60))")
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                        .offset(x: Geo.track * f - (f == 0 ? 0 : 6))
                }
            }
            .frame(width: Geo.track, alignment: .leading)
            Text("min").font(.system(size: 9)).foregroundStyle(.tertiary).padding(.leading, 10)
            Spacer()
        }
        .padding(.top, 6)
    }

    // MARK: - Table (identity never rests on colour alone)

    private var table: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 0) {
                Text("Hour").frame(width: Geo.label, alignment: .leading)
                Text("Focus").frame(width: 76, alignment: .trailing)
                Text("Break").frame(width: 76, alignment: .trailing)
                Text("Idle").frame(width: 76, alignment: .trailing)
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            Divider()
            ForEach(summary.buckets) { b in
                HStack(spacing: 0) {
                    Text(Fmt.hourLabel(b.hour)).frame(width: Geo.label, alignment: .leading)
                    Text(Fmt.minutes(b.workMinutes)).frame(width: 76, alignment: .trailing)
                    Text(Fmt.minutes(b.breakMinutes)).frame(width: 76, alignment: .trailing)
                    Text(Fmt.minutes(max(0, 60 - b.totalMinutes))).frame(width: 76, alignment: .trailing)
                        .foregroundStyle(.tertiary)
                }
                .font(.system(size: 11).monospacedDigit())
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 14) {
            legendKey("Focus", .focusSeries(scheme))
            legendKey("Break", .breakSeries(scheme))
            Spacer()
            Button(showTable ? "Chart" : "Table") { showTable.toggle() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    private func legendKey(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 7)
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Nothing logged")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Focus and break intervals are recorded as you use the timer.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct HourRow: View {
    let bucket: HourBucket
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 0) {
            Text(Fmt.hourLabel(bucket.hour))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(bucket.totalMinutes > 0.05 ? .secondary : .tertiary)
                .frame(width: Geo.label, alignment: .leading)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: Geo.bar / 2)
                    .fill(.quinary)
                    .frame(width: Geo.track, height: Geo.bar)
                // 2px gap between the two fills so they read as separate segments.
                HStack(spacing: 2) {
                    if bucket.workMinutes > 0.05 {
                        Capsule().fill(Color.focusSeries(scheme))
                            .frame(width: width(bucket.workMinutes), height: Geo.bar)
                    }
                    if bucket.breakMinutes > 0.05 {
                        Capsule().fill(Color.breakSeries(scheme))
                            .frame(width: width(bucket.breakMinutes), height: Geo.bar)
                    }
                }
            }
            .frame(width: Geo.track, alignment: .leading)

            Text(Fmt.minutes(bucket.totalMinutes))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(bucket.totalMinutes > 0.05 ? .primary : .tertiary)
                .frame(width: Geo.value, alignment: .trailing)
                .padding(.leading, 8)
        }
        .help("\(Fmt.hourLabel(bucket.hour)) — focus \(Fmt.minutes(bucket.workMinutes)), break \(Fmt.minutes(bucket.breakMinutes))")
    }

    /// Minutes → points on a fixed 60-minute track, with a floor so a 1-minute
    /// sliver is still visible.
    private func width(_ minutes: Double) -> CGFloat {
        guard minutes > 0.05 else { return 0 }
        return max(3, Geo.track * CGFloat(min(minutes, 60)) / 60)
    }
}
