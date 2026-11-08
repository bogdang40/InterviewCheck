import Foundation

/// Hands on technical families: algorithmic coding, debugging, SQL, and
/// concept explanations. Coding follows REACTO with the approach and
/// complexity stated before code; debugging follows the scientific loop.
enum InterviewTechnicalPlaybooks {
    static let all: [InterviewAnswerPlaybook] = [
        InterviewAnswerPlaybook(
            id: "coding_algorithm",
            displayName: "Coding",
            frameworkName: "REACTO",
            frameworkSummary: "Restate, examples, approach with complexity before code, narrated implementation, tests, then the optimization I would tune if pushed.",
            strongCues: [
                "write a function",
                "given an array",
                "given a string",
                "implement a function",
                "coding question",
                "solve this problem",
                "optimal solution"
            ],
            cues: ["algorithm", "leetcode", "big o", "data structure", "in place", "linked list", "binary tree"],
            beats: [
                "Restate: the problem in my own words with input and output shapes.",
                "Examples: a normal case and the edge that stresses the approach.",
                "Approach: the pattern I would use and its complexity, stated before any code.",
                "Code: the implementation narrated by intent, with comments that explain why.",
                "Test: trace the example plus the nastiest edge case.",
                "Optimize: the tradeoff I would tune if pushed."
            ],
            spokenLengthTarget: "2 to 3 minutes of framing, then paced to the round",
            voiceStyle: .technical,
            allowsCode: true,
            allowsMermaid: false,
            legacyIntent: .walkthrough,
            depth: .implementationDeep
        ),
        InterviewAnswerPlaybook(
            id: "debugging_code_review",
            displayName: "Debugging",
            frameworkName: "Scientific Loop",
            frameworkSummary: "Reproduce, observe, hypothesize the root cause, isolate until proven, apply the minimal safe fix, then harden with a regression test.",
            strongCues: [
                "find the bug",
                "what is wrong with this code",
                "review this code",
                "why is this failing",
                "debug this"
            ],
            cues: ["stack trace", "exception", "broken", "incorrect output", "not working", "error message"],
            beats: [
                "Reproduce: pin down the failing case first.",
                "Observe: read the error and the code path it implicates.",
                "Hypothesize: the most likely root cause and the cheapest test of it.",
                "Isolate: bisect until the cause is proven, not guessed.",
                "Fix and verify: the minimal safe change plus the check that proves it.",
                "Harden: the regression test that keeps it fixed."
            ],
            spokenLengthTarget: "narrated continuously while working",
            voiceStyle: .technical,
            allowsCode: true,
            allowsMermaid: false,
            legacyIntent: .debug,
            depth: .implementationDeep
        ),
        InterviewAnswerPlaybook(
            id: "sql_data",
            displayName: "SQL",
            frameworkName: "Plan Aloud",
            frameworkSummary: "Restate the output shape, name the tables and join keys, sketch the query structure aloud, write it, then handle nulls, duplicates, and ties.",
            strongCues: [
                "write a query",
                "sql query",
                "window function",
                "top n per group",
                "write the sql"
            ],
            cues: ["group by", "left join", "aggregate", "having clause", "duplicate rows"],
            beats: [
                "Output shape: restate exactly what rows and columns come back.",
                "Tables and joins: the tables involved and the keys that connect them.",
                "Plan: sketch the query structure aloud before writing it.",
                "Query: the SQL itself in a fenced block, formatted for reading.",
                "Edge cases: nulls, duplicates, and ties, handled explicitly."
            ],
            spokenLengthTarget: "2 to 4 minutes",
            voiceStyle: .technical,
            allowsCode: true,
            allowsMermaid: false,
            legacyIntent: .walkthrough,
            depth: .implementationDeep
        ),
        InterviewAnswerPlaybook(
            id: "knowledge_concept",
            displayName: "Concept explanation",
            frameworkName: "Define Intuit Formalize",
            frameworkSummary: "One crisp definition, the mental model that makes it click, the mechanism one level deeper, the tradeoffs, and where I used it for real.",
            strongCues: [
                "what is the difference between",
                "explain how",
                "how does",
                "what is a",
                "what does",
                "explain the concept"
            ],
            cues: ["define", "compare", "versus", "when would you use", "pros and cons"],
            beats: [
                "Definition: one crisp line.",
                "Intuition: the analogy or mental model that makes it click.",
                "Mechanism: how it actually works, one level deeper.",
                "Tradeoffs: when to reach for it and when not to.",
                "Practice: where I have used it for real."
            ],
            spokenLengthTarget: "60 to 90 seconds",
            voiceStyle: .technical,
            allowsCode: true,
            allowsMermaid: false,
            legacyIntent: .conversation,
            depth: InterviewAnswerDepth(
                complexity: .moderate,
                modelTier: .fast,
                detailLevel: .concise,
                responseShape: .structured
            )
        )
    ]
}
