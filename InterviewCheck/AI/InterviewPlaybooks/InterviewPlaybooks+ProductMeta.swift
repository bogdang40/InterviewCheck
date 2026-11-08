import Foundation

/// Product, business, and meta families: product sense, metrics, estimation,
/// cases, plus the questions every loop ends with: compensation, reverse
/// questions, logistics, and the occasional curveball.
enum InterviewProductMetaPlaybooks {
    static let all: [InterviewAnswerPlaybook] = [
        InterviewAnswerPlaybook(
            id: "product_sense",
            displayName: "Product sense",
            frameworkName: "CIRCLES Lite",
            frameworkSummary: "Pick the user and their sharpest pain, frame the underserved need, compare two or three solutions honestly, commit to one, and define success.",
            strongCues: [
                "design a product",
                "how would you improve",
                "favorite product",
                "build a product for",
                "product for"
            ],
            cues: ["user needs", "pain point", "target user", "feature you would add"],
            beats: [
                "User: who exactly this is for and their sharpest pain.",
                "Problem: the underserved need worth solving.",
                "Options: two or three solutions, honestly compared.",
                "Pick: the one I would build first and why.",
                "Metrics: how I would know it worked."
            ],
            spokenLengthTarget: "staged over the round, user framing first",
            voiceStyle: .spoken,
            allowsCode: false,
            allowsMermaid: false,
            legacyIntent: .conversation,
            depth: .structuredDeep
        ),
        InterviewAnswerPlaybook(
            id: "product_metrics",
            displayName: "Product metrics",
            frameworkName: "GAME",
            frameworkSummary: "State the product goal, the user actions that express it, the funnel metrics that capture those actions, and the counter metric that keeps the number honest.",
            strongCues: [
                "what metrics",
                "measure success",
                "north star metric",
                "how would you measure"
            ],
            cues: ["kpi", "engagement metric", "retention metric", "funnel"],
            beats: [
                "Goal: what the product is for, one line.",
                "Actions: the user behaviors that express that goal.",
                "Metrics: the funnel metrics that capture those behaviors.",
                "Guardrails: the counter metric that keeps the number honest."
            ],
            spokenLengthTarget: "3 to 5 minutes",
            voiceStyle: .spoken,
            allowsCode: false,
            allowsMermaid: false,
            legacyIntent: .conversation,
            depth: .structuredDeep
        ),
        InterviewAnswerPlaybook(
            id: "estimation",
            displayName: "Estimation",
            frameworkName: "Structured Estimation",
            frameworkSummary: "Clarify scope and units, choose top down or bottom up explicitly, estimate each part with rounded numbers computed aloud, then sanity check against a known anchor.",
            strongCues: [
                "how many",
                "estimate the",
                "market size",
                "fermi",
                "size the market",
                "back of the envelope"
            ],
            cues: ["ballpark", "rough estimate", "order of magnitude"],
            beats: [
                "Clarify: the scope and units before any math.",
                "Decompose: top down or bottom up, stated explicitly.",
                "Estimate: each part with rounded numbers, computed aloud.",
                "Check: compare the result against a known anchor."
            ],
            spokenLengthTarget: "3 to 5 minutes",
            voiceStyle: .spoken,
            allowsCode: false,
            allowsMermaid: false,
            legacyIntent: .conversation,
            depth: .structuredDeep
        ),
        InterviewAnswerPlaybook(
            id: "business_case",
            displayName: "Business case",
            frameworkName: "Answer First Pyramid",
            frameworkSummary: "Recommendation up front, the two or three branches that could change it, numbers on each branch, the risks that would make me wrong, then the recommendation restated.",
            strongCues: [
                "should we enter",
                "profits are declining",
                "market entry",
                "you are the ceo",
                "would you launch"
            ],
            cues: ["client", "revenue is down", "competitive response", "go to market"],
            beats: [
                "Answer: my recommendation, stated up front.",
                "Structure: the two or three branches that could change it.",
                "Analysis: the numbers or logic on each branch.",
                "Risks: what would make me wrong.",
                "Synthesis: the recommendation restated with the strongest evidence."
            ],
            spokenLengthTarget: "paced to the interviewer",
            voiceStyle: .spoken,
            allowsCode: false,
            allowsMermaid: false,
            legacyIntent: .conversation,
            depth: .structuredDeep
        ),
        InterviewAnswerPlaybook(
            id: "salary_comp",
            displayName: "Compensation",
            frameworkName: "Deflect Then Anchor",
            frameworkSummary: "Keep the focus on fit and ask for the budgeted range; if pressed, anchor with market data in total compensation terms without naming a hard single number first.",
            strongCues: [
                "salary expectations",
                "compensation expectations",
                "current salary",
                "expected salary",
                "what number are you looking for"
            ],
            cues: ["pay range", "total comp", "equity expectations"],
            beats: [
                "Deflect: keep the focus on fit and ask for the budgeted range.",
                "Anchor: if pressed, a market data based range in total compensation terms.",
                "Flexibility: openness on the mix without committing to a hard single number."
            ],
            spokenLengthTarget: "20 to 30 seconds per exchange",
            voiceStyle: .spoken,
            allowsCode: false,
            allowsMermaid: false,
            legacyIntent: .conversation,
            depth: .spokenFast
        ),
        InterviewAnswerPlaybook(
            id: "reverse_questions",
            displayName: "Questions for them",
            frameworkName: "Three Tier",
            frameworkSummary: "One question about the day to day work, one about how the team operates, one about where the product or company is heading. Never compensation or perks here.",
            strongCues: [
                "questions for us",
                "questions for me",
                "anything you want to ask",
                "any questions about the role"
            ],
            cues: ["what would you like to know from us"],
            beats: [
                "Role: something specific about the day to day work.",
                "Team: how the team actually operates and ships.",
                "Strategy: where the product or company is heading."
            ],
            spokenLengthTarget: "three questions, delivered one at a time",
            voiceStyle: .spoken,
            allowsCode: false,
            allowsMermaid: false,
            legacyIntent: .conversation,
            depth: .spokenFast
        ),
        InterviewAnswerPlaybook(
            id: "logistics_close",
            displayName: "Logistics",
            frameworkName: "Direct and Warm",
            frameworkSummary: "Give the fact plainly, add one sentence of framing, and keep the tone easy so the close stays positive.",
            strongCues: [
                "notice period",
                "start date",
                "when can you start",
                "visa status",
                "willing to relocate"
            ],
            cues: ["work authorization", "remote or onsite", "availability for"],
            beats: [
                "Answer: the fact asked for, plainly.",
                "Context: one sentence of relevant framing.",
                "Warmth: keep the door open and the tone easy."
            ],
            spokenLengthTarget: "15 to 30 seconds",
            voiceStyle: .spoken,
            allowsCode: false,
            allowsMermaid: false,
            legacyIntent: .conversation,
            depth: .spokenFast
        ),
        InterviewAnswerPlaybook(
            id: "brainteaser",
            displayName: "Curveball",
            frameworkName: "Structure Over Answer",
            frameworkSummary: "Pause and restate the puzzle, decompose it into parts aloud, reason through the parts with visible logic, then commit to an answer and note its sensitivity.",
            strongCues: [
                "golf balls",
                "sell me this pen",
                "manhole covers",
                "how would you weigh"
            ],
            cues: ["brainteaser", "riddle", "trick question"],
            beats: [
                "Clarify: restate the puzzle and confirm the constraints.",
                "Decompose: break it into cases or parts aloud.",
                "Reason: work the parts with visible logic.",
                "Land: commit to an answer and note what it is sensitive to."
            ],
            spokenLengthTarget: "2 to 3 minutes",
            voiceStyle: .spoken,
            allowsCode: false,
            allowsMermaid: false,
            legacyIntent: .conversation,
            depth: .spokenFast
        )
    ]
}
