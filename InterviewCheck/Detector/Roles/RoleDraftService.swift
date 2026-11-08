import Foundation
import InterviewCheckKit

/// What one "Draft" press produces from a job description.
struct RoleDraft: Equatable {
    var questions: [PlannedQuestion]
    /// Role-specific versions of the editable cheater prompts, by prompt id.
    var promptInstructions: [String: String]
}

/// Turns a pasted job description into planned interview questions and
/// role-specific cheater prompts (what a candidate's tool would be told for
/// this exact job), so the AI answers match what a cheating candidate sees.
enum RoleDraftService {
    static let systemPrompt = """
    You help a hiring team prepare a live interview and detect candidates who read answers \
    from AI tools. You write precise, role-specific interview questions, and you write the \
    instructions a cheating tool would most likely be given for this job, so the team can \
    compare candidates' spoken answers with what such a tool produces. Reply with JSON only.
    """

    static func userPrompt(roleTitle: String, jobDescription: String) -> String {
        """
        ROLE: \(roleTitle.isEmpty ? "(see job description)" : roleTitle)

        JOB DESCRIPTION:
        \(jobDescription.prefix(12_000))

        Return exactly this JSON:
        {"questions": [
           {"question": "<one interview question, as you would say it aloud>",
            "strong_answer": "<one or two sentences: what a strong answer covers>"}
         ],
         "talking_points_prompt": "<instructions for an invisible real-time interview assistant for \
        THIS role: tell the candidate what to say right now as one opening sentence plus 3-5 short \
        first-person talking points, using the role's stack, domain and seniority>",
         "star_prompt": "<instructions for an AI interview copilot for THIS role: write the spoken \
        first-person answer, STAR stories for behavioral questions and structured explanations with \
        one trade-off for technical ones, 150-220 words, drawing on the candidate's resume>"}

        Write 10 questions: about 4 technical or role-skill questions, 2 design or problem-solving \
        questions, 3 behavioral questions, and 1 about motivation for this role. Make them specific \
        to the job description, and include at least two that ask for a concrete detail of the \
        candidate's own past work (hard to answer from a generic AI response).
        """
    }

    static func parse(_ reply: String) -> RoleDraft? {
        guard let json = LooseJSON.object(from: reply) else { return nil }
        let items = json["questions"] as? [[String: Any]] ?? []
        let questions = items.compactMap { item -> PlannedQuestion? in
            guard let text = (item["question"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            let strong = (item["strong_answer"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return PlannedQuestion(text: text, family: CheaterPromptLibrary.family(of: text), strongAnswer: strong)
        }
        var instructions: [String: String] = [:]
        if let text = nonEmpty(json["talking_points_prompt"]) {
            instructions[CheaterPromptLibrary.talkingPoints.id] = text
        }
        if let text = nonEmpty(json["star_prompt"]) { instructions[CheaterPromptLibrary.star.id] = text }
        guard !questions.isEmpty || !instructions.isEmpty else { return nil }
        return RoleDraft(questions: Array(questions.prefix(15)), promptInstructions: instructions)
    }

    /// Replaces the planned questions and updates the matching prompts.
    /// Prompts the interviewer added themselves are left alone.
    static func apply(_ draft: RoleDraft, to profile: RoleProfile) -> RoleProfile {
        var updated = profile
        if !draft.questions.isEmpty { updated.plannedQuestions = draft.questions }
        for index in updated.cheaterPrompts.indices {
            if let text = draft.promptInstructions[updated.cheaterPrompts[index].id] {
                updated.cheaterPrompts[index].instructions = text
            }
        }
        return updated
    }

    static func draft(roleTitle: String, jobDescription: String, using client: DetectorTextGenerating) async throws -> RoleDraft {
        let reply = try await client.completeText(system: systemPrompt,
                                                  user: userPrompt(roleTitle: roleTitle, jobDescription: jobDescription))
        guard let draft = parse(reply) else { throw DetectorClientError.emptyReply }
        return draft
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return text
    }
}
