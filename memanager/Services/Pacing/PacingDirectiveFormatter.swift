import Foundation

/// Produces the per-call prompt addendum that the model reads as its "Pacing
/// Contract". Pure function; tested by asserting on the returned string.
///
/// Returns `nil` when the state has zero confidence (the first 30 seconds
/// of a session, or when Deepgram is offline) to avoid feeding the model an
/// instruction that isn't grounded in data.
enum PacingDirectiveFormatter {

    static func format(state: PacingState) -> String? {
        guard state.confidence >= 0.25 else { return nil }
        let body: String
        switch state.kind {
        case .decisive:
            body = """
            Interviewer is impatient and moving fast. Answer in at most three sentences.
            Land the punchline in the first sentence. Skip the caveats and the "let me think" opener.
            """
        case .measured:
            body = """
            Normal interview cadence. Answer with balanced depth: restate briefly, then reason, then conclude.
            Avoid both over-hedging and compression.
            """
        case .expansive:
            body = """
            Interviewer is engaged and leaning in. There is room to go deeper.
            Walk through the reasoning, surface at least one trade-off, and mention a related approach.
            """
        case .stalled:
            body = """
            The room is silent. Take the lead: re-anchor on the question or offer the next step proactively.
            A single sentence is often enough.
            """
        }
        return """
        ### Pacing Contract
        \(body)
        """
    }
}
