import Foundation

/// Quantitative reasoning families: probability, experimentation, and
/// metric investigations. All three reward stating the tool before the
/// arithmetic and sanity checking against a known anchor.
enum InterviewDataQuantPlaybooks {
    static let all: [InterviewAnswerPlaybook] = [
        InterviewAnswerPlaybook(
            id: "stats_probability",
            displayName: "Statistics and probability",
            frameworkName: "Restate Tool Compute Check",
            frameworkSummary: "Restate the quantity precisely, name the theorem or distribution that applies, compute aloud with clean numbers, then confirm with a bound or limiting case.",
            strongCues: [
                "what is the probability",
                "expected value",
                "p value",
                "two dice",
                "coin flip",
                "standard deviation"
            ],
            cues: ["distribution", "conditional probability", "bayes", "variance", "confidence interval"],
            beats: [
                "Restate: the quantity being asked for, precisely.",
                "Tool: the theorem or distribution that applies and why.",
                "Compute: the calculation aloud with clean rounded numbers.",
                "Check: a bound or limiting case that confirms the answer is sane."
            ],
            spokenLengthTarget: "2 to 4 minutes",
            voiceStyle: .technical,
            allowsCode: false,
            allowsMermaid: false,
            legacyIntent: .conversation,
            depth: .structuredDeep
        ),
        InterviewAnswerPlaybook(
            id: "ab_testing",
            displayName: "A/B testing",
            frameworkName: "Experiment Loop",
            frameworkSummary: "The causal claim, the randomization unit and metrics, rough power math, the classic pitfalls with mitigations, and a ship rule stated before results exist.",
            strongCues: [
                "a/b test",
                "ab test",
                "design an experiment",
                "statistically significant",
                "the metric moved"
            ],
            cues: ["control group", "treatment", "sample size", "novelty effect", "guardrail metric"],
            beats: [
                "Hypothesis: the causal claim in one sentence.",
                "Design: randomization unit, primary metric, and guardrails.",
                "Power: sample size and duration, roughly computed aloud.",
                "Pitfalls: peeking, novelty, and interference, each with my mitigation.",
                "Decision: the ship rule stated before any results exist."
            ],
            spokenLengthTarget: "3 to 5 minutes",
            voiceStyle: .technical,
            allowsCode: false,
            allowsMermaid: false,
            legacyIntent: .conversation,
            depth: .structuredDeep
        ),
        InterviewAnswerPlaybook(
            id: "analytics_case",
            displayName: "Metric investigation",
            frameworkName: "Decomposition Loop",
            frameworkSummary: "Clarify the metric definition, characterize the shape of the change, rule out internal causes first, segment until the drop localizes, then state the confirming query.",
            strongCues: [
                "dropped by",
                "dau dropped",
                "metric dropped",
                "investigate the decline",
                "diagnose the drop",
                "engagement is down"
            ],
            cues: ["root cause the metric", "sudden drop", "gradual decline", "segment the data"],
            beats: [
                "Clarify: the metric definition and the time window.",
                "Shape: sudden versus gradual, seasonal versus new behavior.",
                "Internal check: bugs, logging changes, and launches ruled out first.",
                "Segment: platform, geography, and cohort until the drop localizes.",
                "Hypothesis: the likeliest cause and the query that would confirm it."
            ],
            spokenLengthTarget: "4 to 6 minutes",
            voiceStyle: .technical,
            allowsCode: false,
            allowsMermaid: false,
            legacyIntent: .conversation,
            depth: .structuredDeep
        )
    ]
}
