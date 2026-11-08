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
    private var saved: Set<String> = []
    private var watching: AnyCancellable?
    /// The last file written or the last failure, for Settings.
    private(set) var lastResult: String?

    init(defaults: UserDefaults = AppDefaults.standard, database: SessionDatabase = .shared) {
        self.defaults = defaults
        self.database = database
    }

    /// Saves each live interview once it has ended and every score is final.
    func watch(_ controller: InterviewController) {
        watching = controller.$phase.combineLatest(controller.$pendingScoring)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak controller] phase, pending in
                guard let self, let controller, phase == .ended, pending.isEmpty, let id = controller.interview?.id else { return }
                self.save(id: id)
            }
    }

    /// Saves the stored report of this interview, once.
    @discardableResult
    func save(id: String) -> URL? {
        guard folder != nil, !saved.contains(id), let report = database.loadInterviewReport(id: id) else { return nil }
        return save(report)
    }

    @discardableResult
    func save(_ report: InterviewReportData) -> URL? {
        guard let folder, !saved.contains(report.interview.id) else { return nil }
        saved.insert(report.interview.id)
        guard let data = PaginatedPDF.data(ReportAttributedText.make(report)) else { return nil }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = Self.uniqueURL(in: folder, name: Self.fileName(report))
            try data.write(to: url, options: .atomic)
            lastResult = "Saved \(url.lastPathComponent)"
            return url
        } catch {
            lastResult = "Could not save to \(folder.path): \(error.localizedDescription)"
            return nil
        }
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
