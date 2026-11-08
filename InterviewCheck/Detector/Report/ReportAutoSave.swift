import Combine
import Foundation

/// Saves a PDF of every finished report into a folder the interviewer picked
/// (a shared drive, a hiring folder). Off until a folder is chosen. Files in
/// that folder are the interviewer's: the retention setting does not delete them.
@MainActor
final class ReportAutoSave {
    static let shared = ReportAutoSave()
    static let folderKey = "interviewcheck.reportFolder"

    var folder: URL? {
        get { defaults.string(forKey: Self.folderKey).map { URL(fileURLWithPath: $0, isDirectory: true) } }
        set { defaults.set(newValue?.path, forKey: Self.folderKey) }
    }

    private let defaults: UserDefaults
    private let database: SessionDatabase
    /// Each saved report's file and the scores it showed: a report whose
    /// scores change later (Save and Regenerate) is written again in place.
    private var saved: [String: (url: URL, scores: String)] = [:]
    private var watching: AnyCancellable?
    /// The interview that ended last: saved once its scores and AI answers are
    /// done, even if New Interview was pressed meanwhile.
    private var ended: String?
    /// The last file written or the last failure, for Settings.
    private(set) var lastResult: String?

    init(defaults: UserDefaults = AppDefaults.standard, database: SessionDatabase = .shared) {
        self.defaults = defaults
        self.database = database
    }

    /// Saves each live interview once it has ended, every score is final and
    /// no AI answers are still being generated; again if its scores change.
    func watch(_ controller: InterviewController) {
        // The interview's id is read when it ends, not later: New Interview
        // may clear it before the delivery on the main queue.
        let endedIDs = controller.$phase.map { [weak controller] phase in phase == .ended ? controller?.interview?.id : nil }
        watching = endedIDs.combineLatest(controller.$pendingScoring, controller.$referencesInFlight)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] endedID, pending, inFlight in
                guard let self else { return }
                if let endedID { self.ended = endedID }
                guard let id = self.ended, pending.isEmpty, inFlight.isEmpty else { return }
                self.save(id: id)
            }
    }

    /// Saves the stored report of this interview (again only if its scores changed).
    @discardableResult
    func save(id: String) -> URL? {
        guard folder != nil, let report = database.loadInterviewReport(id: id) else { return nil }
        return save(report)
    }

    @discardableResult
    func save(_ report: InterviewReportData) -> URL? {
        guard let folder else { return nil }
        let id = report.interview.id
        let scores = Self.scoreLine(report)
        if let previous = saved[id], previous.scores == scores { return nil }
        guard let data = PaginatedPDF.data(ReportAttributedText.make(report)) else { return nil }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = saved[id].map(\.url) ?? Self.uniqueURL(in: folder, name: Self.fileName(report))
            try data.write(to: url, options: .atomic)
            // Remembered only once written, so a failed save is tried again.
            saved[id] = (url, scores)
            lastResult = "Saved \(url.lastPathComponent)"
            return url
        } catch {
            lastResult = "Could not save to \(folder.path): \(error.localizedDescription)"
            return nil
        }
    }

    /// The scores a report shows, to notice when they change.
    static func scoreLine(_ report: InterviewReportData) -> String {
        report.questions.map { question in
            let score = report.scores[question.id]
            return "\(question.id):\(score.map { "\($0.percent)\($0.isFinal ? "f" : "")" } ?? "-")"
        }.joined(separator: "|") + "|\(report.interview.overallPercent.map(String.init) ?? "-")"
    }

    /// "2026-11-08 10.15 Jane Doe - Backend Engineer.pdf"
    static func fileName(_ report: InterviewReportData) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        let who = report.interview.candidateName.isEmpty ? "Interview" : report.interview.candidateName
        let role = report.interview.roleTitle.isEmpty ? "" : " - \(report.interview.roleTitle)"
        let name = "\(formatter.string(from: report.interview.startedAt)) \(who)\(role)"
            .components(separatedBy: CharacterSet(charactersIn: "/\\:\0")).joined(separator: "-")
        return String(name.prefix(150)) + ".pdf"
    }

    static func uniqueURL(in folder: URL, name: String) -> URL {
        var url = folder.appendingPathComponent(name)
        var number = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent(name.replacingOccurrences(of: ".pdf", with: " \(number).pdf"))
            number += 1
        }
        return url
    }
}
