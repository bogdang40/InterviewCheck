import Foundation

/// Builds the system and user prompts used by `SessionSummaryComposer`. Kept separate so that
/// the wording can be iterated without touching the execution path.
enum SessionSummaryPromptBuilder {
    struct Prompts {
        let system: String
        let user: String
    }

    static func build(
        sessionID: UUID,
        transcript: SessionSummaryTranscript,
        modeSnapshot: SessionModeSnapshot?
    ) -> Prompts {
        let systemPrompt = """
        You are a meeting minutes writer. Given the full transcript of a session, produce a
        concise, structured summary in strict JSON. Do not invent facts. If the transcript is
        sparse, still produce the JSON structure with empty arrays and short notes.
        Use only speaker identities and timing explicitly present in the transcript.
        If attribution or timing is unavailable, leave it unspecified.

        Schema (respond with JSON only, no prose around it):
        {
          "actionItems": [
            { "title": "short imperative", "owner": "name or null", "dueDate": "freeform or null", "notes": "optional one line" }
          ],
          "backgroundSummary": "3 to 6 short bullets joined with newlines describing context, decisions, and themes",
          "followUpEmail": "optional draft email body or null"
        }
        """

        let transcriptBody = transcript.promptBody
        let snapshotBody = modeSnapshotContext(modeSnapshot)

        let userPrompt = """
        Session ID: \(sessionID.uuidString)

        \(snapshotBody)

        Transcript:
        \(transcriptBody)

        Produce the JSON object described in the system prompt. Do not wrap it in code fences.
        """

        return Prompts(system: systemPrompt, user: userPrompt)
    }

    private static func modeSnapshotContext(_ snapshot: SessionModeSnapshot?) -> String {
        guard let snapshot else { return "No Mode was active during this session." }
        var parts = ["Active Mode: \(snapshot.title)"]
        let trimmedPrompt = snapshot.promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPrompt.isEmpty {
            parts.append("Mode prompt: " + trimmedPrompt)
        }
        if !snapshot.attachments.isEmpty {
            let names = snapshot.attachments.map { $0.originalFilename }.joined(separator: ", ")
            parts.append("Attached references: " + names)
        }
        return parts.joined(separator: "\n")
    }
}
