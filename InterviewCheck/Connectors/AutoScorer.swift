import Foundation
import InterviewCheckConnectors

/// Optional: scores new meeting recordings in the background as they arrive
/// from Zoom, Teams or Meet, when the recording matches a scheduled
/// interview with a known candidate. Off by default (it uses the Deepgram
/// and AI keys, and the company must tell candidates interviews are checked).
@MainActor
final class AutoScorer {
    static let shared = AutoScorer()
    static let enabledKey = "interviewcheck.autoScoreRecordings"
    private static let attemptedKey = "interviewcheck.autoScoreAttempted"

    var manager: ConnectorManager = .shared
    var roles: RoleStore = .shared
    var defaults: UserDefaults = AppDefaults.standard
    var makeAnalyzer: () -> RecordingAnalyzer = { RecordingAnalyzer() }
    /// Told about each finished report (a notification in the app).
    var onReport: (InterviewReportData) -> Void = { _ in }
    var now: () -> Date = { Date() }
    private(set) var isRunning = false

    var isEnabled: Bool {
        get { defaults.bool(forKey: Self.enabledKey) }
        set { defaults.set(newValue, forKey: Self.enabledKey) }
    }

    private var attempted: Set<String> {
        get { Set(defaults.stringArray(forKey: Self.attemptedKey) ?? []) }
        set { defaults.set(Array(newValue.suffix(500)), forKey: Self.attemptedKey) }
    }

    /// Recordings worth scoring now: new, recent, matched to an interview.
    func pending() -> [(ExternalRecording, ExternalInterview)] {
        let seen = attempted
        // Reports with answers, from a live interview or an earlier part of the
        // same meeting: that interview is not scored a second time.
        let reports = manager.database.loadInterviews(limit: 300).filter { $0.questionCount > 0 }
        var claimed: Set<String> = []
        return manager.recordings.compactMap { item -> (ExternalRecording, ExternalInterview)? in
            let recording = item.recording
            guard item.interviewID == nil, !seen.contains(recording.id),
                  recording.startedAt > now().addingTimeInterval(-2 * 86_400),
                  let interview = manager.interview(for: recording), interview.candidate != nil,
                  !claimed.contains(interview.id), !alreadyReported(interview, near: recording.startedAt, in: reports) else { return nil }
            claimed.insert(interview.id)
            return (recording, interview)
        }
    }

    /// A report near this time for the same meeting: the same id, or the same
    /// interview as the merger sees it (link, candidate email or name), since
    /// Prepare may have saved it under the ATS's id.
    private func alreadyReported(_ interview: ExternalInterview, near start: Date, in reports: [InterviewRecord]) -> Bool {
        reports.contains { report in
            guard abs(report.startedAt.timeIntervalSince(start)) < 3 * 3600 else { return false }
            guard let ref = report.externalRef else {
                // Run live without Prepare: the same candidate's name, started
                // at this meeting's time (not a second round later that day).
                let name = InterviewMerger.normalized(interview.candidate?.name ?? "")
                // Start is pressed when the call begins, which may be well after
                // the booked time (introductions, a late candidate).
                let slot = interview.startsAt.addingTimeInterval(-15 * 60)...(interview.endsAt ?? interview.startsAt.addingTimeInterval(3600))
                return !name.isEmpty && InterviewMerger.normalized(report.candidateName) == name && slot.contains(report.startedAt)
            }
            if ref == interview.id { return true }
            return manager.database.loadExternalLink(ref).map { ConnectorManager.sameInterview($0, interview) } ?? false
        }
    }

    /// Scores pending recordings one at a time. Each is tried once.
    func run() async {
        guard isEnabled, !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        for (recording, interview) in pending() {
            attempted.insert(recording.id)
            if let report = await score(recording, interview: interview) { onReport(report) }
        }
    }

    func score(_ recording: ExternalRecording, interview: ExternalInterview) async -> InterviewReportData? {
        let analyzer = makeAnalyzer()
        // In the background: never switch the window (a live interview may be on).
        analyzer.showsReportWhenDone = false
        let role = interview.job.flatMap { job in
            roles.roles.first { $0.externalJobKey == "\(interview.source.rawValue):\(job.externalID)" }
                ?? roles.roles.first { $0.name.caseInsensitiveCompare(job.title) == .orderedSame }
        }
        do {
            try await manager.analyze(recording, with: analyzer, candidateName: interview.candidate?.name ?? "", role: role)
        } catch {
            return nil
        }
        guard await wait(for: analyzer, until: { $0 == .chooseSpeaker }) else { return nil }
        // With nobody to confirm the voice, a transcript is only scored when
        // the candidate's name picks out exactly one speaker.
        if recording.bestMediaFile == nil, !analyzer.candidateMatchedByName {
            analyzer.reset()
            return nil
        }
        analyzer.analyze()
        guard await wait(for: analyzer, until: { if case .finished = $0 { return true } else { return false } }),
              case .finished(let id, _) = analyzer.step else { return nil }
        var report = manager.database.loadInterviewReport(id: id)
        if var record = report?.interview {
            record.externalRef = interview.id
            manager.database.saveInterview(record)
            manager.database.saveExternalLink(interview)
            report = manager.database.loadInterviewReport(id: id)
        }
        return report
    }

    /// Waits for the analyzer to reach a step; false when it fails or stalls.
    private func wait(for analyzer: RecordingAnalyzer, until done: (RecordingAnalyzer.Step) -> Bool,
                      timeout: TimeInterval = 30 * 60) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if done(analyzer.step) { return true }
            if case .failed = analyzer.step { return false }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return false
    }
}
