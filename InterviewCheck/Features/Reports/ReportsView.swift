import SwiftUI
import InterviewCheckKit

/// Reports: past interviews beside the selected report.
struct ReportsView: View {
    @ObservedObject private var navigation = AppNavigation.shared
    @ObservedObject private var interview = InterviewController.shared
    var database: SessionDatabase = .shared
    @State private var interviews: [InterviewRecord] = []
    @State private var selection: String?
    @State private var report: InterviewReportData?
    @State private var search = ""
    @State private var confirmDelete = false

    private var filtered: [InterviewRecord] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return interviews }
        return interviews.filter { "\($0.candidateName) \($0.roleTitle)".lowercased().contains(query) }
    }

    var body: some View {
        HSplitView {
            List(selection: $selection) {
                ForEach(filtered) { record in
                    ReportRow(record: record).tag(record.id)
                        .contextMenu {
                            Button("Export Markdown\u{2026}") { export(record.id, pdf: false) }
                            Button("Export PDF\u{2026}") { export(record.id, pdf: true) }
                            Divider()
                            Button("Delete\u{2026}", role: .destructive) { selection = record.id; confirmDelete = true }
                        }
                }
            }
            .searchable(text: $search, placement: .sidebar, prompt: "Candidate or role")
            .frame(minWidth: 240, idealWidth: 280, maxWidth: 380)
            .overlay {
                if interviews.isEmpty {
                    ContentUnavailableView("No Reports Yet", systemImage: "doc.text.magnifyingglass",
                                           description: Text("Finished interviews appear here."))
                }
            }

            Group {
                if let report {
                    ReportDetail(report: report)
                } else {
                    ContentUnavailableView("Select an Interview", systemImage: "doc.text.magnifyingglass",
                                           description: Text("See each answer, its score, and what the AI tools said."))
                }
            }
            .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Reports")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button("Markdown\u{2026}") { if let id = selection { export(id, pdf: false) } }
                    Button("PDF\u{2026}") { if let id = selection { export(id, pdf: true) } }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(report == nil)
                Button { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
                    .disabled(report == nil)
            }
        }
        .onAppear { reload(select: navigation.reportToShow) }
        .onChange(of: navigation.reportToShow) { _, id in reload(select: id) }
        .onChange(of: interview.phase) { _, _ in reload(select: selection) }
        .onChange(of: interview.interview?.overallPercent) { _, _ in reload(select: selection) }
        .onChange(of: selection) { _, id in report = id.flatMap { database.loadInterviewReport(id: $0) } }
        .confirmationDialog("Delete this interview and its report?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                if let id = selection { database.deleteInterview(id: id) }
                selection = nil
                reload(select: nil)
            }
        } message: {
            Text("The transcript, AI answers and scores are removed. This cannot be undone.")
        }
    }

    private func reload(select id: String?) {
        interviews = database.loadInterviews()
        if let id { navigation.reportToShow = nil }
        let target = id ?? selection ?? interviews.first?.id
        selection = interviews.contains { $0.id == target } ? target : interviews.first?.id
        report = selection.flatMap { database.loadInterviewReport(id: $0) }
    }

    private func export(_ id: String, pdf: Bool) {
        guard let data = database.loadInterviewReport(id: id) else { return }
        if pdf { ReportExporter.exportPDF(data) } else { ReportExporter.exportMarkdown(data) }
    }
}

private struct ReportRow: View {
    let record: InterviewRecord

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.candidateName.isEmpty ? "Candidate" : record.candidateName).lineLimit(1)
                Text([record.roleTitle, record.startedAt.formatted(date: .abbreviated, time: .shortened)]
                        .filter { !$0.isEmpty }.joined(separator: " \u{00B7} "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let percent = record.overallPercent {
                Tag(text: "\(percent)%", color: ScoreBand(percent: percent).color)
            }
        }
        .padding(.vertical, 2)
    }
}

/// One interview's report.
struct ReportDetail: View {
    let report: InterviewReportData

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                ForEach(report.questions) { question in
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Q\(question.ordinal). \(question.text.isEmpty ? "(question not captured)" : question.text)")
                            .font(.title3.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        if let score = report.scores[question.id] { ScoreCard(score: score) }
                        Text("CANDIDATE'S ANSWER").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(question.answerText.isEmpty ? "(nothing captured)" : question.answerText)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        let answers = (report.references[question.id] ?? []).filter { $0.error == nil }
                        if !answers.isEmpty {
                            DisclosureGroup("What AI tools would have said (\(answers.count))") {
                                ReferenceGrid(answers: answers, bestMatchLabel: report.scores[question.id]?.metrics.bestMatchLabel)
                                    .padding(.top, 6)
                            }
                        }
                    }
                    Divider()
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        let interview = report.interview
        return VStack(alignment: .leading, spacing: 6) {
            Text(interview.candidateName.isEmpty ? "Candidate" : interview.candidateName)
                .font(.largeTitle.weight(.semibold))
            Text([interview.roleTitle, interview.startedAt.formatted(date: .long, time: .shortened),
                  interview.consentConfirmedAt == nil ? "notice not recorded" : "candidate notified"]
                    .filter { !$0.isEmpty }.joined(separator: " \u{00B7} "))
                .foregroundStyle(.secondary)
            if let overall = interview.overallPercent {
                HStack(spacing: 8) {
                    Tag(text: "\(overall)% overall", color: ScoreBand(percent: overall).color)
                    Text("\(interview.flaggedCount) of \(interview.questionCount) answers at 70% or more")
                        .foregroundStyle(.secondary)
                }
            }
            Text("Scores are signals to follow up on, not proof. A person should review the evidence before any decision.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
