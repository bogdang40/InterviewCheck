import Foundation

/// Decides whether an emailed document is this candidate's résumé. Strict on
/// purpose: a wrong CV would give the AI the wrong background.
enum ResumeMatching {
    static let documentExtensions = [".pdf", ".docx", ".doc", ".rtf", ".odt"]

    /// 2: the file names the candidate (all of the name, or the surname);
    /// 1: a CV-looking file in a message whose subject names them; 0: no.
    static func strength(filename: String, subject: String, tokens: [String]) -> Int {
        guard !tokens.isEmpty else { return 0 }
        let file = Set(Self.tokens(filename))
        if tokens.allSatisfy(file.contains) || (tokens.count > 1 && tokens.last!.count >= 3 && file.contains(tokens.last!)) {
            return 2
        }
        let looksLikeCV = !file.isDisjoint(with: ["cv", "resume", "lebenslauf", "curriculum", "vitae"])
        let subjectWords = Set(Self.tokens(subject))
        return looksLikeCV && tokens.allSatisfy(subjectWords.contains) ? 1 : 0
    }

    /// Lower-case words without accents ("Résumé_Jane-Doe.pdf" → resume, jane, doe, pdf).
    static func tokens(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.letters.inverted).filter { $0.count >= 2 }
    }

    static func isDocument(_ filename: String) -> Bool {
        documentExtensions.contains { filename.lowercased().hasSuffix($0) }
    }

    static func safeFileName(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/\\:\0")).joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return cleaned.isEmpty ? "resume.pdf" : String(cleaned.prefix(120))
    }
}
