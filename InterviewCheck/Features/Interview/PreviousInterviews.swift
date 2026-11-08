import Foundation

/// Earlier interviews with the same candidate, matched on the full name.
enum PreviousInterviews {
    static func latest(for name: String, database: SessionDatabase = .shared) -> InterviewRecord? {
        let wanted = normalized(name)
        guard wanted.split(separator: " ").count >= 2 else { return nil }
        return database.loadInterviews(limit: 200).first { normalized($0.candidateName) == wanted && $0.endedAt != nil }
    }

    static func normalized(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
}
