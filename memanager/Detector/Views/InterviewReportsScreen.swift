import SwiftUI

/// The Review destination: past interviews and their reports.
struct InterviewReportsScreen: View {
    @ObservedObject var controller = InterviewController.shared
    var database: SessionDatabase = .shared
    let width: CGFloat
    @State private var interviews: [InterviewRecord] = []
    @State private var selectedID: String?
    @State private var report: InterviewReportData?
    @State private var confirmDelete = false

    private var isCompact: Bool { width < 720 }

    var body: some View {
        HStack(spacing: 0) {
            if !isCompact || selectedID == nil {
                list.frame(width: isCompact ? nil : 280)
                if !isCompact { Hairline(axis: .vertical) }
            }
            if !isCompact || selectedID != nil { detail }
        }
        .onAppear(perform: reload)
        .onChange(of: controller.phase) { _, _ in reload() }
        .onChange(of: selectedID) { _, id in report = id.flatMap { database.loadInterviewReport(id: $0) } }
        .confirmationDialog("Delete this interview and its report?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                if let id = selectedID { database.deleteInterview(id: id) }
                selectedID = nil
                reload()
            }
        }
    }

    private func reload() {
        interviews = database.loadInterviews()
        if selectedID == nil, !isCompact { selectedID = interviews.first?.id }
        report = selectedID.flatMap { database.loadInterviewReport(id: $0) }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text("Interviews").font(OverlayType.title).foregroundStyle(OverlayPalette.textPrimary)
                    .padding(.bottom, 6)
                if interviews.isEmpty {
                    Text("Finished interviews appear here.")
                        .font(OverlayType.caption).foregroundStyle(OverlayPalette.textTertiary)
                }
                ForEach(interviews) { interview in
                    Button { selectedID = interview.id } label: { row(interview) }
                        .buttonStyle(.plain)
                }
            }
            .padding(DesignTokens.Spacing.md)
        }
    }

    private func row(_ interview: InterviewRecord) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(interview.candidateName.isEmpty ? "Candidate" : interview.candidateName)
                    .font(OverlayType.heading).foregroundStyle(OverlayPalette.textPrimary).lineLimit(1)
                Text([interview.roleTitle, InterviewReportComposer.dateFormatter.string(from: interview.startedAt)]
                        .filter { !$0.isEmpty }.joined(separator: " \u{00B7} "))
                    .font(OverlayType.caption).foregroundStyle(OverlayPalette.textTertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if let percent = interview.overallPercent {
                ToneBadge(text: "\(percent)%", tone: ScoreBand(percent: percent).tone, monospaced: true)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(selectedID == interview.id ? OverlayPalette.accent.opacity(0.14) : .clear))
        .contentShape(Rectangle())
    }

    @ViewBuilder private var detail: some View {
        if let report {
            InterviewReportView(report: report, width: isCompact ? width : width - 281,
                                onBack: isCompact ? { selectedID = nil } : nil,
                                onDelete: { confirmDelete = true })
        } else {
            OverlayEmptyState(systemImage: "doc.text.magnifyingglass", title: "No report selected",
                              message: "Pick an interview to see each answer, its score, and what the AI tools said.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// One interview's report.
struct InterviewReportView: View {
    let report: InterviewReportData
    let width: CGFloat
    var onBack: (() -> Void)?
    let onDelete: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                header
                ForEach(report.questions) { question in
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                        Text("Q\(question.ordinal). \(question.text.isEmpty ? "(question not captured)" : question.text)")
                            .font(OverlayType.title).foregroundStyle(OverlayPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let score = report.scores[question.id] { ScoreCardView(score: score) }
                        FieldLabel(text: "Candidate's answer")
                        Text(question.answerText.isEmpty ? "(nothing captured)" : question.answerText)
                            .font(OverlayType.body).foregroundStyle(OverlayPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        let answers = (report.references[question.id] ?? []).filter { $0.error == nil }
                        if !answers.isEmpty {
                            DisclosureGroup("What AI tools would have said (\(answers.count))") {
                                ReferenceAnswerGrid(answers: answers,
                                                    bestMatchLabel: report.scores[question.id]?.metrics.bestMatchLabel,
                                                    width: width - 40)
                                    .padding(.top, 6)
                            }
                            .font(OverlayType.callout)
                        }
                    }
                    .padding(.top, DesignTokens.Spacing.sm)
                    Hairline()
                }
            }
            .padding(DesignTokens.Spacing.xl)
        }
    }

    private var header: some View {
        let interview = report.interview
        return VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack(spacing: 6) {
                if let onBack {
                    Button(action: onBack) { Image(systemName: "chevron.left") }.buttonStyle(.overlayIcon(size: 28))
                }
                Text(interview.candidateName.isEmpty ? "Candidate" : interview.candidateName)
                    .font(OverlayType.display).foregroundStyle(OverlayPalette.textPrimary)
                Spacer(minLength: 0)
                Button("Markdown", systemImage: "square.and.arrow.down") { ReportExporter.exportMarkdown(report) }
                    .buttonStyle(.overlay(.secondary, size: .small))
                Button("PDF", systemImage: "doc.richtext") { ReportExporter.exportPDF(report) }
                    .buttonStyle(.overlay(.secondary, size: .small))
                Button(action: onDelete) { Image(systemName: "trash") }
                    .buttonStyle(.overlayIcon(size: 28)).accessibilityLabel("Delete interview")
            }
            Text([interview.roleTitle, InterviewReportComposer.dateFormatter.string(from: interview.startedAt),
                  interview.consentConfirmedAt == nil ? "notice not recorded" : "candidate notified"]
                    .filter { !$0.isEmpty }.joined(separator: " \u{00B7} "))
                .font(OverlayType.caption).foregroundStyle(OverlayPalette.textTertiary)
            if let overall = interview.overallPercent {
                HStack(spacing: 8) {
                    ToneBadge(text: "\(overall)% overall", tone: ScoreBand(percent: overall).tone, style: .solid)
                    Text("\(interview.flaggedCount) of \(interview.questionCount) answers at 70% or more")
                        .font(OverlayType.caption).foregroundStyle(OverlayPalette.textSecondary)
                }
            }
        }
    }
}
