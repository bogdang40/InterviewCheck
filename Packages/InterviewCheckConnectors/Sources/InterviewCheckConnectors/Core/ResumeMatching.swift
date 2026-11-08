import Foundation

/// Decides whether an emailed document is this candidate's résumé. Strict on
/// purpose: a wrong CV would give the AI the wrong background.
enum ResumeMatching {
    static let documentExtensions = [".pdf", ".docx", ".doc", ".rtf", ".odt"]

    /// 2: the file name has the candidate's first and last name;
    /// 1: a CV-looking file in a message whose subject has both; 0: no.
    /// Titles, suffixes and middle names are not needed ("Dr. Priya Ramesh
    /// Patel" matches Priya_Patel_CV.pdf). A one-word name never matches (any
    /// "Jane_….pdf" would), nor does a surname alone (Raj Patel's CV is not
    /// Priya Patel's).
    static func strength(filename: String, subject: String, tokens: [String]) -> Int {
        let name = tokens.filter { !ignoredNameWords.contains($0) }
        guard name.count >= 2, let first = name.first, let last = name.last else { return 0 }
        let required = [first, last]
        let file = Set(Self.tokens(filename))
        if required.allSatisfy(file.contains) { return 2 }
        let looksLikeCV = !file.isDisjoint(with: ["cv", "resume", "lebenslauf", "curriculum", "vitae"])
        let subjectWords = Set(Self.tokens(subject))
        return looksLikeCV && required.allSatisfy(subjectWords.contains) ? 1 : 0
    }

    static let ignoredNameWords: Set<String> = ["dr", "mr", "mrs", "ms", "mx", "prof", "jr", "sr", "ii", "iii", "iv", "phd", "md"]

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
        guard !cleaned.isEmpty else { return "resume.pdf" }
        guard cleaned.count > 120 else { return cleaned }
        // Shortened, keeping the extension (it decides how the file is read).
        let ext = (cleaned as NSString).pathExtension
        let stem = (cleaned as NSString).deletingPathExtension
        return String(stem.prefix(110)) + (ext.isEmpty ? "" : ".\(ext.prefix(8))")
    }
}
