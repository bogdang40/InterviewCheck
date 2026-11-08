import Foundation
import InterviewCheckConnectors

/// Interviews and recordings synced from connectors, kept as JSON so new
/// fields need no migration.
extension SessionDatabase {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()

    /// Replaces one source's interviews with the latest sync.
    func replaceExternalInterviews(_ interviews: [ExternalInterview], source: ConnectorKind) {
        interviewWrite("clearExternalInterviews", "DELETE FROM external_interviews WHERE source = ?") {
            $0.bindText(source.rawValue, at: 1)
        }
        for interview in interviews {
            guard let payload = try? Self.encoder.encode(interview) else { continue }
            interviewWrite("saveExternalInterview", """
                INSERT OR REPLACE INTO external_interviews (id, source, starts_at, payload, synced_at) VALUES (?, ?, ?, ?, ?)
                """) {
                $0.bindText(interview.id, at: 1)
                $0.bindText(source.rawValue, at: 2)
                $0.bindMillis(interview.startsAt, at: 3)
                $0.bindText(String(decoding: payload, as: UTF8.self), at: 4)
                $0.bindMillis(Date(), at: 5)
            }
        }
    }

    func loadExternalInterviews(startingAfter date: Date) -> [ExternalInterview] {
        interviewRead("loadExternalInterviews",
                      "SELECT payload FROM external_interviews WHERE starts_at >= ? ORDER BY starts_at",
                      bind: { $0.bindMillis(date, at: 1) }) { row in
            row.columnText(0).flatMap { try? Self.decoder.decode(ExternalInterview.self, from: Data($0.utf8)) }
        }.compactMap { $0 }
    }

    /// Adds recordings not seen before; keeps which interview each became.
    func addExternalRecordings(_ recordings: [ExternalRecording]) {
        for recording in recordings {
            guard let payload = try? Self.encoder.encode(recording) else { continue }
            interviewWrite("saveExternalRecording", """
                INSERT INTO external_recordings (id, source, started_at, payload, synced_at) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET payload = excluded.payload, synced_at = excluded.synced_at
                """) {
                $0.bindText(recording.id, at: 1)
                $0.bindText(recording.source.rawValue, at: 2)
                $0.bindMillis(recording.startedAt, at: 3)
                $0.bindText(String(decoding: payload, as: UTF8.self), at: 4)
                $0.bindMillis(Date(), at: 5)
            }
        }
    }

    func loadExternalRecordings(limit: Int = 100) -> [(recording: ExternalRecording, interviewID: String?)] {
        interviewRead("loadExternalRecordings",
                      "SELECT payload, interview_id FROM external_recordings ORDER BY started_at DESC LIMIT ?",
                      bind: { $0.bindInt(limit, at: 1) }) { row -> (ExternalRecording, String?)? in
            guard let recording = row.columnText(0).flatMap({
                try? Self.decoder.decode(ExternalRecording.self, from: Data($0.utf8))
            }) else { return nil }
            return (recording, row.columnText(1))
        }.compactMap { $0 }
    }

    func markRecordingAnalyzed(_ recordingID: String, interviewID: String) {
        interviewWrite("markRecordingAnalyzed", "UPDATE external_recordings SET interview_id = ? WHERE id = ?") {
            $0.bindText(interviewID, at: 1)
            $0.bindText(recordingID, at: 2)
        }
    }

    func saveExternalLink(_ interview: ExternalInterview) {
        guard let payload = try? Self.encoder.encode(interview) else { return }
        interviewWrite("saveExternalLink", "INSERT OR REPLACE INTO external_links (ref, payload) VALUES (?, ?)") {
            $0.bindText(interview.id, at: 1)
            $0.bindText(String(decoding: payload, as: UTF8.self), at: 2)
        }
    }

    func loadExternalLink(_ ref: String) -> ExternalInterview? {
        interviewRead("loadExternalLink", "SELECT payload FROM external_links WHERE ref = ?",
                      bind: { $0.bindText(ref, at: 1) }) { row in
            row.columnText(0).flatMap { try? Self.decoder.decode(ExternalInterview.self, from: Data($0.utf8)) }
        }.first ?? nil
    }

    func deleteExternalRecordings(startedBefore date: Date) {
        interviewWrite("deleteOldRecordings", "DELETE FROM external_recordings WHERE started_at < ?") { $0.bindMillis(date, at: 1) }
    }

    /// Forgets everything a source brought in (when it is disconnected),
    /// including candidate links no report refers to.
    func deleteExternalData(source: ConnectorKind) {
        for table in ["external_interviews", "external_recordings"] {
            interviewWrite("deleteExternal", "DELETE FROM \(table) WHERE source = ?") { $0.bindText(source.rawValue, at: 1) }
        }
        interviewWrite("deleteExternalLinks",
                       "DELETE FROM external_links WHERE ref LIKE ? AND ref NOT IN (SELECT external_ref FROM interviews WHERE external_ref IS NOT NULL)") {
            $0.bindText("\(source.rawValue):%", at: 1)
        }
    }

    /// Candidate links (from Prepare) that no saved interview refers to.
    func deleteUnusedExternalLinks() {
        interviewWrite("deleteUnusedLinks",
                       "DELETE FROM external_links WHERE ref NOT IN (SELECT external_ref FROM interviews WHERE external_ref IS NOT NULL)") { _ in }
    }

    func deleteExternalLinks(_ refs: [String]) {
        for ref in Set(refs) {
            interviewWrite("deleteLink", "DELETE FROM external_links WHERE ref = ?") { $0.bindText(ref, at: 1) }
        }
    }
}
