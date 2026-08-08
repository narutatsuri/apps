import SwiftUI

struct RecommendCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("What to Read Next") { openWindow(id: WindowID.recommend) }
            .keyboardShortcut("j", modifiers: .command)
    }
}

/// What to read next. Its own window, like the graph — with three displays it can
/// sit beside the notes rather than replacing them.
struct RecommendationsView: View {
    @Bindable var model: AppModel
    /// ImageRenderer draws a ScrollView's content as blank space, so the only way to
    /// see these rows without a screen is to render them unwrapped. Snapshots pass
    /// false; the app never does.
    var scrolls = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if model.isRecommending && model.recommendations.isEmpty {
                progress
            } else if model.recommendations.isEmpty {
                empty
            } else {
                if model.isRecommending { banner }
                list
            }
        }
        .frame(minWidth: 520, minHeight: 420)
        .task { if model.recommendations.isEmpty && !model.isRecommending { model.loadRecommendations() } }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Recommended reading").font(.system(size: 15, weight: .semibold))
                Text("New on arXiv, papers like the ones you rated highest, work by people you follow, and what your library keeps citing."
                     + (model.papers.contains(where: \.starred)
                        ? " Starred papers count treble."
                        : " Star papers to weight them treble."))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: Binding(
                get: { Prefs.freshWindowDays },
                set: { Prefs.freshWindowDays = $0; model.loadRecommendations(fresh: true) })) {
                Text("Past week").tag(7)
                Text("Past 3 weeks").tag(21)
                Text("Past 2 months").tag(60)
            }
            .pickerStyle(.menu).controlSize(.small).labelsHidden()
            .disabled(model.isRecommending)
            .help("How far back the arXiv scan looks for brand-new papers")
            Button("Authors…") { model.editTrustedAuthors() }
                .controlSize(.small)
                .help("Edit the list of people whose new work you want to hear about")
            Button {
                model.loadRecommendations(fresh: true)
            } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .controlSize(.small)
                .disabled(model.isRecommending)
            Button("Ask the judge") { model.judgeRecommendations() }
                .controlSize(.small)
                .disabled(model.isRecommending || model.recommendations.isEmpty)
                .help("Weighs each candidate against what you have already read. Takes a few minutes.")
        }
        .padding(14)
    }

    /// Judging runs down the list one at a time; the results that have landed stay
    /// readable while the rest come in.
    private var banner: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).scaleEffect(0.7)
            Text(model.recommendProgress).font(.system(size: 10)).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 5)
        .background(.quaternary.opacity(0.4))
    }

    private var progress: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text(model.recommendProgress).font(.system(size: 11)).foregroundStyle(.secondary)
            Text("The judge reads each candidate against your library; this takes a minute.")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Text("Nothing to recommend yet").foregroundStyle(.secondary)
            Text("Import more papers — suggestions come from what their bibliographies\nkeep pointing at.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var list: some View {
        if scrolls {
            ScrollView { rows }
        } else {
            rows
            Spacer(minLength: 0)
        }
    }

    // VStack, not LazyVStack: the list is capped at a dozen rows, so laziness buys
    // nothing here and costs the ability to render it offscreen.
    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.recommendations, id: \.arxivID) { c in
                row(c)
                Divider()
            }
        }
    }

    private func row(_ c: Recommender.Candidate) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    if !c.verdict.isEmpty {
                        Text(c.verdict)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(colour(c.verdict)))
                    }
                    Text(c.title.isEmpty ? "arXiv:\(c.arxivID)" : c.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(2)
                }
                HStack(spacing: 8) {
                    if !c.authors.isEmpty {
                        Text(c.authors.prefix(3).joined(separator: ", ")
                             + (c.authors.count > 3 ? " et al." : "")).lineLimit(1)
                    }
                    if !c.ageLabel.isEmpty {
                        // Age leads, because it is the thing being optimised for.
                        Text(c.ageLabel)
                            .fontWeight(.semibold)
                            .foregroundStyle((c.ageInDays ?? 999) <= 31
                                             ? Color(hex: 0x0CA30C) : Color.secondary)
                    } else if let y = c.year { Text(String(y)) }
                    switch c.source {
                    case .author(let name):
                        Label(name, systemImage: "person.fill.checkmark")
                            .fontWeight(.medium).foregroundStyle(Color(hex: 0x2A78D6))
                    case .fresh:
                        Label("new on arXiv", systemImage: "sparkle")
                            .fontWeight(.medium).foregroundStyle(Color(hex: 0x0CA30C))
                    case .similar:
                        Label("like your top papers", systemImage: "wand.and.stars")
                            .fontWeight(.medium).foregroundStyle(Color(hex: 0x7A5AF8))
                    case .cited:
                        Text("cited by \(c.citedByYours.count) of yours").fontWeight(.medium)
                    }
                    if c.citations > 0 { Text("· \(c.citations) citations") }
                }
                .font(.system(size: 10)).foregroundStyle(.secondary)
                if !c.reason.isEmpty {
                    Text(c.reason).font(.system(size: 10)).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            VStack(spacing: 5) {
                Button("Add") { model.addRecommendation(c) }
                    .controlSize(.small)
                Button("Read next") { model.addRecommendation(c, queue: true) }
                    .controlSize(.small)
                    .help("Adds it and puts it at the front of the reading queue")
                Link("arXiv", destination: URL(string: "https://arxiv.org/abs/\(c.arxivID)")!)
                    .font(.system(size: 10))
                Button("Not for me") { model.dismissRecommendation(c) }
                    .buttonStyle(.link)
                    .font(.system(size: 9))
                    .help("Recorded in not-interested.txt so it stops coming back")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    /// The verdict scale is a judgement of state, so it uses the reserved status
    /// colours rather than borrowing from the graph's year ramp.
    private func colour(_ verdict: String) -> Color {
        switch verdict {
        case "ESSENTIAL": return Color(hex: 0x0CA30C)
        case "USEFUL": return Color(hex: 0x2A78D6)
        case "MARGINAL": return Color(hex: 0xEC835A)
        case "SKIP": return Color(hex: 0x898781)
        default: return Color(hex: 0x898781)
        }
    }
}

/// The grading result: your answers first, then the assessment.
///
/// Rendered through the same markdown+KaTeX view the note editor uses, because
/// the answers arrive full of quoted maths — a plain Text view showed a proof
/// of the paper's Appendix C as one unbroken grey paragraph.
struct GradeSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private var report: GradeReport { GradeReport.parse(model.gradeResult ?? "") }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            MarkdownPreview(markdown: report.markdown(rawFallback: model.gradeResult ?? ""))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
            Divider()
            footer
        }
        .frame(width: 720, height: 620)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if !report.grade.isEmpty {
                Text(report.grade)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .background(Capsule().fill(colour(report.grade)))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(model.draft?.title.isEmpty == false
                     ? model.draft!.title : (model.draft?.arxivID ?? "Your note"))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(verdictBlurb(report.grade))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if model.gradeWasCached {
                Label("Saved from an earlier run — your note has not changed since",
                      systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Grade again") { model.gradeCurrentNote(force: true) }
                .controlSize(.small)
                .disabled(model.isGrading)
                .help("Ignores the saved result and asks Claude again")
            Button("Done") { model.gradeResult = nil; dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    /// The note scale, which is deliberately not the paper scale — SOLID here is
    /// a statement about your writing, not about the paper.
    private func colour(_ grade: String) -> Color {
        switch grade {
        case "SOLID": return Color(hex: 0x0CA30C)
        case "PARTIAL": return Color(hex: 0x2A78D6)
        case "THIN": return Color(hex: 0xEC835A)
        case "WRONG": return Color(hex: 0xC5343A)
        default: return Color(hex: 0x898781)
        }
    }

    private func verdictBlurb(_ grade: String) -> String {
        switch grade {
        case "SOLID": return "Your note holds up against the paper."
        case "PARTIAL": return "Right as far as it goes; something load-bearing is missing."
        case "THIN": return "Accurate but shallow — the paper's substance isn't here yet."
        case "WRONG": return "Something in the note misstates what the paper claims."
        default: return "Graded against the paper itself."
        }
    }
}
