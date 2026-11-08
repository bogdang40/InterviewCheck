import Foundation

/// What a candidate's tool would know: the job and the candidate's resume.
struct RoleContext: Equatable {
    var roleTitle: String
    var jobDescription: String
    var resume: String

    static let empty = RoleContext(roleTitle: "", jobDescription: "", resume: "")

    /// The context block a cheating tool is typically loaded with.
    var block: String {
        var parts: [String] = []
        if !jobDescription.isEmpty {
            let title = roleTitle.isEmpty ? "" : " (\(roleTitle))"
            parts.append("JOB DESCRIPTION\(title):\n\(jobDescription.prefix(6_000))")
        }
        if !resume.isEmpty { parts.append("MY RESUME:\n\(resume.prefix(6_000))") }
        return parts.joined(separator: "\n\n")
    }
}

/// The default cheater prompts, and how each one becomes a request.
enum CheaterPromptLibrary {
    static let copilotID = "builtin.copilot"

    static var defaults: [CheaterPrompt] { [copilot, talkingPoints, star] }

    /// The original app's own answer prompt: the most faithful imitation of
    /// a real cheating tool, because it is one.
    static let copilot = CheaterPrompt(
        id: copilotID,
        name: "Full answer",
        instructions: "Built in: the answer prompt from a real interview copilot, loaded with the job description and resume.",
        isBuiltIn: true
    )

    static let talkingPoints = CheaterPrompt(
        id: "builtin.talking-points",
        name: "Talking points",
        instructions: """
        You are a real-time interview assistant that runs invisibly on the candidate's screen. \
        The interviewer just asked a question. Tell the candidate exactly what to say right now: \
        one opening sentence they can say immediately, then 3 to 5 short first-person talking \
        points, using concrete details from the candidate's resume and the job description when \
        they fit. No preamble, no advice about delivery.
        """,
        isBuiltIn: true
    )

    static let star = CheaterPrompt(
        id: "builtin.star",
        name: "STAR story",
        instructions: """
        You are an AI interview copilot. Write the answer the candidate should speak, in the first \
        person, as natural speech. For behavioral questions tell one story with situation, task, \
        action and result; for technical questions give a clear, structured explanation with one \
        trade-off. Use specific projects, numbers and technologies from the resume so it sounds \
        like the candidate's own experience. 150 to 220 words, no headings.
        """,
        isBuiltIn: true
    )

    struct Request: Equatable {
        let system: String
        let user: String
        /// Run the copilot's own clean-up on the reply, as the real tool does.
        let appliesVoiceGuard: Bool
    }

    static func request(for prompt: CheaterPrompt, question: String, context: RoleContext) -> Request {
        if prompt.id == copilotID { return copilotRequest(question: question, context: context) }
        var user = ""
        if !context.block.isEmpty { user += context.block + "\n\n" }
        user += "THE INTERVIEWER JUST ASKED:\n\(question)\n\nRespond now."
        return Request(system: prompt.instructions, user: user, appliesVoiceGuard: false)
    }

    /// Builds the copilot request exactly as the candidate app would for a
    /// question heard from the other side of the call.
    static func copilotRequest(
        question: String,
        context: RoleContext,
        language: ProgrammingLanguage = .python
    ) -> Request {
        let transcript = "Speaker 1: \(question)"
        let resolution = InterviewQuestionClassifier().classify(.init(
            question: question, transcript: transcript, extraContext: context.block,
            questionSource: .auto, previousFamilyID: nil, allowedFamilyIDs: nil, defaultFamilyID: nil
        ))
        let interaction: QuickAssistInteractionMode =
            resolution?.playbook.voiceStyle == .spoken ? .behavioural : .technical
        let system = PromptBuilder.buildQuickAssistSystemPrompt(
            language: language, contextMode: .conversation, interactionMode: interaction
        )
        let quickContext = QuickAssistContext(
            transcript: transcript, screenshots: [], question: question,
            extraContext: context.block, realtimePrompt: "", interactionMode: interaction,
            contextMode: .conversation, answerPlaybookContract: resolution?.playbook.promptContract
        )
        return Request(system: system, user: PromptBuilder.buildQuickAssistPrompt(context: quickContext),
                       appliesVoiceGuard: true)
    }

    /// Playbook family for a question, for labelling planned questions.
    static func family(of question: String) -> String? {
        InterviewQuestionClassifier().classify(.init(
            question: question, transcript: "", extraContext: "", questionSource: .manual,
            previousFamilyID: nil, allowedFamilyIDs: nil, defaultFamilyID: nil
        ))?.playbook.displayName
    }
}
