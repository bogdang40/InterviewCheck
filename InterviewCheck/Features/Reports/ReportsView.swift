import InterviewCheckConnectors
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
    @AppStorage("interviewcheck.reports.sort") private var sort = ReportSort.newest
    @AppStorage("interviewcheck.reports.flaggedOnly") private var flaggedOnly = false
    @State private var roleFilter: String?
    @State private var summaryTarget: SummaryTarget?
    @ObservedObject private var connectors = ConnectorManager.shared
    @Environment(\.openWindow) private var openWindow

    private struct SummaryTarget: Identifiable {
        let report: InterviewReportData
        let interview: ExternalInterview
        var id: String { interview.id }
    }

    private var filtered: [InterviewRecord] {
        ReportFilter(search: search, flaggedOnly: flaggedOnly, roleTitle: roleFilter, sort: sort).apply(interviews)
    }

    private var roleTitles: [String] {
        Array(Set(interviews.map(\.roleTitle).filter { !$0.isEmpty })).sorted()
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
            .onDeleteCommand { if selection != nil { confirmDelete = true } }
            .safeAreaInset(edge: .top, spacing: 0) {
                if !interviews.isEmpty { filterBar }
            }
            .overlay {
                if interviews.isEmpty {
                    ContentUnavailableView {
                        Label("No Reports Yet", systemImage: "doc.text.magnifyingglass")
                    } description: {
                        Text("Finished interviews appear here. The demo interview ends on a sample report.")
                    } actions: {
                        Button("Watch the Demo") { openWindow(id: AppWindowID.demo) }
                    }
                } else if filtered.isEmpty {
                    ContentUnavailableView {
                        Label("No Matches", systemImage: "line.3.horizontal.decrease.circle")
                    } description: {
                        Text("No interviews match the search and filters.")
                    } actions: {
                        Button("Clear Filters") {
                            search = ""
                            flaggedOnly = false
                            roleFilter = nil
                        }
                    }
                }
            }
            .frame(minWidth: 240, idealWidth: 280, maxWidth: 380)

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
                Button { RecordingAnalyzer.shared.present() } label: {
                    Label("Analyze Recording", systemImage: "waveform.badge.magnifyingglass")
                }
                .help("Score a recorded interview (File \u{203A} Analyze Recording\u{2026})")
                Menu {
                    Button("Markdown\u{2026}") { if let id = selection { export(id, pdf: false) } }
                        .disabled(report == nil)
                    Button("PDF\u{2026}") { if let id = selection { export(id, pdf: true) } }
                        .disabled(report == nil)
                    Button("Share PDF\u{2026}") { if let report { ReportExporter.share(report) } }
                        .disabled(report == nil)
                    Divider()
                    Button("All Interviews as CSV\u{2026}") {
                        ReportExporter.exportCSV(interviews.compactMap { database.loadInterviewReport(id: $0.id) })
                    }
                    .disabled(interviews.isEmpty)
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(interviews.isEmpty)
                if let report, let (interview, kind) = connectors.noteDestination(for: report) {
                    Button { summaryTarget = SummaryTarget(report: report, interview: interview) } label: {
                        Label("Send to \(kind.descriptor.name)", systemImage: "paperplane")
                    }
                    .help("Review a summary and add it as a private note in \(kind.descriptor.name)")
                }
                Button { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
                    .disabled(report == nil)
            }
        }
        .onAppear { reload(select: navigation.reportToShow) }
        .onChange(of: navigation.reportToShow) { _, id in reload(select: id) }
        .onChange(of: interview.phase) { _, _ in reload(select: selection) }
        .onChange(of: interview.interview?.overallPercent) { _, _ in reload(select: selection) }
        .onChange(of: selection) { _, id in
            report = id.flatMap { database.loadInterviewReport(id: $0) }
            navigation.selectedReportID = report?.interview.id
        }
        .sheet(item: $summaryTarget) { target in
            SendSummarySheet(report: target.report, interview: target.interview)
        }
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

    private var filterBar: some View {
        HStack(spacing: 8) {
            Picker("Sort", selection: $sort) {
                ForEach(ReportSort.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .help("Sort the interviews")
            Picker("Role", selection: $roleFilter) {
                Text("All roles").tag(String?.none)
                ForEach(roleTitles, id: \.self) { Text($0).tag(Optional($0)) }
            }
            .labelsHidden()
            .frame(maxWidth: 150)
            .help("Show one role's interviews")
            Spacer(minLength: 0)
            Toggle(isOn: $flaggedOnly) {
                Image(systemName: "flag")
            }
            .toggleStyle(.button)
            .help("Only interviews with an answer at 70% or more")
            .accessibilityLabel("Flagged only")
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func reload(select id: String?) {
        interviews = database.loadInterviews()
        if let id {
            navigation.reportToShow = nil
            // A report asked for by name is shown even if a filter hid it.
            if !filtered.contains(where: { $0.id == id }) {
                search = ""
                flaggedOnly = false
                roleFilter = nil
            }
        }
        let visible = filtered
        let target = id ?? selection ?? visible.first?.id
        selection = visible.contains { $0.id == target } ? target : visible.first?.id
        report = selection.flatMap { database.loadInterviewReport(id: $0) }
        navigation.selectedReportID = report?.interview.id
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
            if record.wasInterrupted {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .help("The app closed before this interview was ended")
                    .accessibilityLabel("Interrupted")
            }
            // Flagged answers first, as everywhere else; the overall % is secondary.
            if record.flaggedCount > 0 {
                Tag(text: "\(record.flaggedCount) flagged", color: ScoreBand.flagged.color)
                    .accessibilityLabel("\(record.flaggedCount) answer\(record.flaggedCount == 1 ? "" : "s") flagged")
            }
            if let percent = record.overallPercent {
                Text("\(percent)%").font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    .frame(minWidth: 36, alignment: .trailing)
                    .help(InterviewSummary.overallHelp)
                    .accessibilityLabel("\(percent) percent overall")
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// One interview's report.
struct ReportDetail: View {
    let report: InterviewReportData
    var database: SessionDatabase = .shared
    @State private var labels: [String: AnswerLabel] = [:]
    @State private var words: [TimedWord] = []

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if report.questions.count > 1 {
                    QuestionRail(questions: report.questions, scores: report.scores, activeID: nil, focusedID: nil,
                                 showsSummary: false) { id in
                        withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(id, anchor: .top) }
                    }
                }
                if !standouts.isEmpty { standoutBox }
                ForEach(report.questions) { question in
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Q\(question.ordinal). \(question.text.isEmpty ? "(question not captured)" : question.text)")
                            .font(.title3.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        if let score = report.scores[question.id] {
                            ScoreCard(score: score, baselineNote: BaselineSignal.note(for: question.id, scores: report.scores))
                        }
                        if let strip = timingStrip(question) {
                            SectionCaption("Timing")
                            TimingStrip(model: strip)
                        }
                        let answers = (report.references[question.id] ?? []).filter { $0.error == nil }
                        CandidateAnswerBlock(text: question.answerText, references: answers, question: question.text,
                                             placeholder: "(nothing captured)")
                        if !answers.isEmpty {
                            DisclosureGroup("What AI tools would have said (\(answers.count))") {
                                ReferenceGrid(answers: answers, bestMatchLabel: report.scores[question.id]?.metrics.bestMatchLabel,
                                              candidateAnswer: question.answerText, question: question.text)
                                    .padding(.top, 6)
                            }
                        }
                        if report.scores[question.id] != nil { verdictPicker(question.id) }
                        SectionCaption("Your notes")
                        QuestionNoteField(questionID: question.id, database: database)
                            .id("note-\(question.id)")
                    }
                    .id(question.id)
                    Divider()
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        }
        .onAppear { load(report.interview.id) }
        .onChange(of: report.interview.id) { _, id in load(id) }
    }

    private func load(_ interviewID: String) {
        labels = database.loadAnswerLabels(interviewID: interviewID)
        words = database.loadInterviewWords(interviewID: interviewID)
    }

    private var standouts: [ReportStandout] { ReportStandout.make(report) }

    private var standoutBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(standouts) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("\(item.score.percent)%")
                            .font(.title2.weight(.semibold)).monospacedDigit()
                            .foregroundStyle(ScoreBand(percent: item.score.percent).color)
                            .frame(minWidth: 56, alignment: .leading)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Q\(item.question.ordinal). \(item.question.text)").fontWeight(.semibold)
                                .fixedSize(horizontal: false, vertical: true)
                            ForEach(item.evidence, id: \.self) { line in
                                Text(line).font(.callout).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("What stood out", systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
        }
    }

    /// Silence, stalling and the answer, rebuilt from the saved word timings.
    private func timingStrip(_ question: InterviewQuestionRecord) -> TimingStripModel? {
        guard let questionEnd = question.questionEnd, !words.isEmpty else { return nil }
        let window = QuestionWindow.stored(questionText: question.text, questionEnd: questionEnd,
                                           answerStart: question.answerStart, answerEnd: question.answerEnd,
                                           words: words)
        guard !window.answerWords.isEmpty else { return nil }
        let timing = TimingSignal.evaluate(answerWords: window.answerWords, questionEnd: questionEnd,
                                           questionText: question.text)
        return TimingStripModel(window: window, timing: timing, now: window.answerEnd ?? questionEnd,
                                aiFirstLine: InterviewLiveScreen.fastestFirstLine(report.references[question.id] ?? []))
    }

    /// The interviewer's own verdict, used to tune the weights.
    private func verdictPicker(_ questionID: String) -> some View {
        HStack(spacing: 10) {
            Text("Your verdict").fixedSize()
            Picker("Your verdict", selection: Binding(
                get: { labels[questionID] },
                set: { label in
                    labels[questionID] = label
                    database.saveAnswerLabel(label, questionID: questionID)
                }
            )) {
                Text("Not judged").tag(AnswerLabel?.none)
                ForEach(AnswerLabel.allCases) { Text($0.title).tag(Optional($0)) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 420)
        }
        .help("After follow-ups, mark what you concluded. Settings \u{203A} Detector can tune the weights from these.")
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
                    Text(report.flaggedLine)
                        .fontWeight(.semibold)
                        .foregroundStyle(interview.flaggedCount > 0 ? ScoreBand.flagged.color : .primary)
                    Text("\u{00B7} \(overall)% overall").foregroundStyle(.secondary).monospacedDigit()
                        .help(InterviewSummary.overallHelp)
                }
            }
            if let ref = interview.externalRef, let link = database.loadExternalLink(ref),
               let profile = link.candidate?.profileURL {
                Link(destination: profile) {
                    Label("Open in \(link.source.descriptor.vendorName)", systemImage: "arrow.up.forward.square")
                }
                .help("The candidate's page in \(link.source.descriptor.vendorName)")
            }
            if interview.wasInterrupted {
                Label("The app closed before this interview was ended. The last answer may be cut short.",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }
            if interview.scoredFrom == .transcript {
                Label(ScoredFrom.transcriptCaveat, systemImage: "text.bubble")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text("Scores are signals to follow up on, not proof. A person should review the evidence before any decision.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
