import Foundation

/// Builds system and user prompts for AI-powered session debrief generation.
/// Separated from `PromptBuilder.swift` to respect the single-responsibility boundary.
enum DebriefPromptBuilder {

    // MARK: - System Prompt

    static func buildSystemPrompt() -> String {
        """
        You are a senior interview performance analyst. Your job is to review a completed \
        interview coaching session and produce a structured debrief report that helps the \
        candidate improve.

        You will receive session evidence: transcript excerpts, Quick Assist usage data, \
        coach findings, and aggregate metrics. Analyze this evidence to identify patterns, \
        strengths, and areas for improvement.

        OUTPUT FORMAT: Respond with a single JSON object. Do not include any text outside \
        the JSON. Do not wrap in markdown code fences.

        JSON Schema:
        {
          "whatHappened": ["string", ...],
          "strongMoments": ["string", ...],
          "missedOpportunities": ["string", ...],
          "recommendedDrills": ["string", ...],
          "nextSessionFocus": ["string", ...],
          "drills": [
            {
              "kind": "clarification" | "tradeoff" | "recovery" | "depth" | "pacing",
              "title": "short drill title",
              "prompt": "the practice question or scenario for the candidate",
              "relatedTurnQuestion": "the original question from the session this drill targets"
            }
          ]
        }

        GUIDELINES:
        - whatHappened: 2-4 factual sentences summarizing what occurred. Reference actual \
        numbers from the metrics.
        - strongMoments: 1-3 specific strengths backed by evidence (verification status, \
        low latency, grounded claims).
        - missedOpportunities: 1-3 specific weak points with evidence (failed verification, \
        unsupported claims, coach findings).
        - recommendedDrills: 2-4 concise recommendations tied to observed weaknesses.
        - nextSessionFocus: 1-3 actionable focus areas for the next session.
        - drills: 2-5 practice drills. Each drill should target a specific weakness observed \
        in the session. The prompt should be a concrete scenario the candidate can practice. \
        Use "depth" kind for knowledge gaps and "pacing" kind for timing or response speed \
        issues. Use "clarification", "tradeoff", or "recovery" for the corresponding \
        interview skill.

        Keep language direct and specific to this session. Avoid generic advice.
        """
    }

    // MARK: - User Prompt

    static func buildUserPrompt(context: DebriefContext) -> String {
        var sections: [String] = []

        sections.append(metricsSection(context.metrics))

        if !context.condensedTranscript.isEmpty {
            sections.append("""
            ## Transcript (\(context.transcriptWordCount) words, \
            \(context.transcriptEntryCount) entries)
            \(context.condensedTranscript)
            """)
        }

        sections.append("""
        ## Quick Assist Usage
        \(context.quickAssistManifest)
        """)

        sections.append("""
        ## Coach Findings
        \(context.coachFindingsManifest)
        """)

        sections.append("""
        ## Response Cards
        \(context.responseCardSummary)
        """)

        return sections.joined(separator: "\n\n")
    }

    // MARK: - Private

    private static func metricsSection(_ m: DebriefMetrics) -> String {
        var lines = [
            "## Session Metrics",
            "Total Quick Assist calls: \(m.totalQuickAssistCalls)",
            "Successful: \(m.successfulCalls), Failed: \(m.failedCalls), Verified: \(m.verifiedCalls)"
        ]
        if let avg = m.averageLatencyMs {
            lines.append("Average latency: \(avg)ms")
        }
        if m.unsupportedClaimTotal > 0 {
            lines.append("Total unsupported claims: \(m.unsupportedClaimTotal)")
        }
        lines.append("Coach findings: \(m.coachFindingCount)")
        lines.append("Response cards: \(m.responseCardCount)")
        return lines.joined(separator: "\n")
    }
}
