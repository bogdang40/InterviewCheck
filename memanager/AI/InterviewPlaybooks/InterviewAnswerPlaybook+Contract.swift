import Foundation

extension InterviewAnswerPlaybook {

    /// The exact opener label the model must emit and the UI emphasizes.
    /// `ResponseVoiceGuard` protects lines with this prefix on the
    /// quick assist surface, so keep the three in sync via this constant.
    static let sayFirstLabel = "**Say first:**"

    /// The prompt block injected into the user prompt when this playbook
    /// drives the response. Rendered from data so the prompt, the parser
    /// expectations, and the UI badge can never drift apart.
    var promptContract: String {
        var lines: [String] = []
        lines.append("Answer playbook: \(frameworkName) for a \(displayName) question.")
        lines.append("Framework: \(frameworkSummary)")
        lines.append("Target spoken length: \(spokenLengthTarget).")
        lines.append("Open your response with exactly one line in this format:")
        lines.append("\(Self.sayFirstLabel) <one speakable sentence that directly begins the answer and buys a beat of thinking time>")

        if beats.isEmpty {
            lines.append(contentsOf: deltaAnswerRules)
        } else {
            lines.append("Then deliver these beats in order. Format each beat as a \"### <beat label>\" heading followed by one to three speakable sentences:")
            for (index, beat) in beats.enumerated() {
                lines.append("\(index + 1). \(beat)")
            }
            lines.append("Keep every beat glanceable: lead with the point, quantify results where honest numbers exist, and end the final beat with a clean stop that invites the follow up.")
        }

        lines.append(depthPolicyLine)
        return lines.joined(separator: "\n")
    }

    /// Rules for delta style playbooks (follow up probes): anchor to the
    /// previous answer instead of rebuilding a fresh skeleton.
    private var deltaAnswerRules: [String] {
        [
            "This is a follow up probe on the previous answer. Do NOT restart with a fresh structure.",
            "Answer only the delta the interviewer is probing: defend the decision, add the number, or extend the story where asked.",
            "Anchor explicitly to what was already said, in three to six speakable sentences, no headings unless genuinely new material demands one."
        ]
    }

    private var depthPolicyLine: String {
        switch (allowsCode, allowsMermaid) {
        case (false, false):
            return "Depth policy: natural spoken narrative only. Do not include code or diagrams unless the interviewer explicitly asks for them."
        case (true, false):
            return "Depth policy: include code in fenced blocks when the question calls for implementation detail. No diagrams unless explicitly asked."
        case (false, true):
            return "Depth policy: include a compact Mermaid diagram when structure or flow carries the explanation. Avoid code unless explicitly asked."
        case (true, true):
            return "Depth policy: full technical depth. Use fenced code blocks and compact Mermaid diagrams whenever they add clear value."
        }
    }
}
