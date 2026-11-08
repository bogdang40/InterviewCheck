import Foundation

extension ResponseVoiceGuard {
    struct MutableLineRewrite {
        let text: String
        let replacementCount: Int
    }

    enum Segment {
        case prose(String)
        case fenced(String)
    }

    static let fenceRegex = try? NSRegularExpression(
        pattern: #"^[ ]{0,3}(`{3,}|~{3,})([^\n`~]*)\n[\s\S]*?^[ ]{0,3}\1[ ]*$"#,
        options: [.anchorsMatchLines]
    )

    static let firstPersonRegex = makeRegex(
        #"(?i)\b(i|i'm|i’m|i’d|i'll|i’ll|i’ve|my|me|let me)\b"#
    )

    static let coachingRegex = makeRegex(
        #"(?i)\b(here(?:'|’)s what you say|what you can say is|you can say|you should say|say this|the candidate should|candidate should|you should mention|you can mention|you should explain|you can explain)\b"#
    )

    static let immutableLinePrefixes: [String] = [
        "### step ",
        "builds-on:",
        "diagram delta:",
        "why now:",
        "decision:",
        "trade-off:",
        "completion_checklist:",
        "inferred side question:",
        "[say this]",
        "[code cell]",
        "[expected output]",
        "[insight to mention]",
        "## step "
    ]

    static let rewriteRules: [(regex: NSRegularExpression, replacement: String)] = [
        // Second-person coaching (original rules)
        (makeRegex(#"(?i)\bhere(?:'|’)s what you say\b[:\s\-]*"#), "Here's how I'd answer: "),
        (makeRegex(#"(?i)\bwhat you can say is\b[:\s\-]*"#), "What I'd say is "),
        (makeRegex(#"(?i)\byou can say\b"#), "I'd say"),
        (makeRegex(#"(?i)\byou should say\b"#), "I'd say"),
        (makeRegex(#"(?i)\bsay this\b"#), "I'd say this"),
        (makeRegex(#"(?i)\bthe candidate should\b"#), "I should"),
        (makeRegex(#"(?i)\bcandidate should\b"#), "I should"),
        (makeRegex(#"(?i)\byou should mention\b"#), "I should mention"),
        (makeRegex(#"(?i)\byou can mention\b"#), "I can mention"),
        (makeRegex(#"(?i)\byou should explain\b"#), "I'll explain"),
        (makeRegex(#"(?i)\byou can explain\b"#), "I can explain"),
        (makeRegex(#"(?i)\byou should\b"#), "I should"),
        (makeRegex(#"(?i)\byou can\b"#), "I can"),
        // Banned openers and fillers (derived from VoiceCore.bannedPhrases)
        (makeRegex(#"(?i)\bin order to\b"#), "to"),
        (makeRegex(#"(?i)\bfirst, let us\b"#), "I'll start by"),
        (makeRegex(#"(?i)\blet us now\b"#), "now I"),
        (makeRegex(#"(?i)\bit is important to note that\b[:\s\-]*"#), ""),
        (makeRegex(#"(?i)\bit should be noted\b[:\s\-]*"#), ""),
        (makeRegex(#"(?i)\bas we can see\b[,\s\-]*"#), ""),
        (makeRegex(#"(?i)\bthe approach here is to\b"#), "I'd"),
        (makeRegex(#"(?i)\bthe key idea is to\b"#), "what I'd do is"),
        (makeRegex(#"(?i)\bone could argue that\b"#), "I'd argue"),
        (makeRegex(#"(?i)\bit is worth mentioning\b[:\s\-]*"#), ""),
        (makeRegex(#"(?i)\bwe need to take into consideration\b"#), "I need to consider"),
        (makeRegex(#"(?i)\bmoving forward\b[,\s\-]*"#), "going on, "),
        (makeRegex(#"(?i)\bat the end of the day\b[,\s\-]*"#), ""),
        (makeRegex(#"(?i)\bneedless to say\b[,\s\-]*"#), ""),
        (makeRegex(#"(?i)\bwithout further ado\b[,\s\-]*"#), ""),
        (makeRegex(#"(?i)\bin conclusion, to summarize\b[,\s\-]*"#), "so "),
        (makeRegex(#"(?i)\bto put it simply\b[,\s\-]*"#), ""),
        (makeRegex(#"(?i)\bbasically what happens is\b"#), "what happens is"),
        (makeRegex(#"(?i)\bin today(?:'|’)s world\b[,\s\-]*"#), ""),
        (makeRegex(#"(?i)\bin this day and age\b[,\s\-]*"#), "")
    ]

    /// Cliché sentence-openers (lowercase, no boundary markers). Used for a
    /// secondary detection pass that counts banned-opener rewrites separately
    /// so we can tune the list empirically.
    static let clicheOpeners: [String] = [
        "in order to",
        "first, let us",
        "let us now",
        "it is important to note that",
        "it should be noted",
        "as we can see",
        "the approach here is to",
        "the key idea is to",
        "one could argue that",
        "it is worth mentioning",
        "we need to take into consideration",
        "moving forward",
        "at the end of the day",
        "in today's world",
        "in this day and age",
        "needless to say",
        "without further ado",
        "in conclusion, to summarize",
        "to put it simply",
        "basically what happens is"
    ]

    static func hasFirstPerson(in text: String) -> Bool {
        firstPersonRegex.firstMatch(
            in: text,
            options: [],
            range: NSRange(location: 0, length: (text as NSString).length)
        ) != nil
    }

    static func containsCoachingLanguage(in text: String) -> Bool {
        coachingRegex.firstMatch(
            in: text,
            options: [],
            range: NSRange(location: 0, length: (text as NSString).length)
        ) != nil
    }

    /// Counts how many cliché openers appear in the input. A counted occurrence
    /// does not imply a rewrite fired (the rule table may reach it first or
    /// the line may be inside an immutable fence). Kept as a diagnostic signal
    /// so `SessionLogger` can see which openers the model is actually emitting.
    static func countClicheOpeners(in text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let lowered = text.lowercased()
        var total = 0
        for opener in clicheOpeners {
            var searchRange = lowered.startIndex..<lowered.endIndex
            while let found = lowered.range(of: opener, range: searchRange) {
                total += 1
                searchRange = found.upperBound..<lowered.endIndex
            }
        }
        return total
    }

    /// Collapses the whitespace artifacts rewrite rules can leave behind:
    /// orphan " ," from a dropped phrase, double spaces, and leading-line
    /// spaces that appear when a phrase at the start of a line is deleted.
    /// Fenced blocks (code and Mermaid) are preserved byte-for-byte because
    /// their indentation is semantically meaningful.
    static func makeRegex(_ pattern: String) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: [])
        } catch {
            fatalError("Invalid regex pattern: \(pattern)")
        }
    }
}
