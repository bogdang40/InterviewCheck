import Foundation

/// Behavioral and situational families. STAR-L carries the story questions,
/// the three Ps carry weakness questions, and hypotheticals get a principle
/// led structure because they are future tense, not stories.
enum InterviewBehavioralPlaybooks {
    static let all: [InterviewAnswerPlaybook] = [
        InterviewAnswerPlaybook(
            id: "behavioral_story",
            displayName: "Behavioral story",
            frameworkName: "STAR-L",
            frameworkSummary: "One line situation, one line task, the action as the bulk of the answer in I voice, a quantified result, and a brief lesson.",
            strongCues: [
                "tell me about a time",
                "describe a situation",
                "give me an example of a time",
                "describe a time when"
            ],
            cues: [
                "disagreed with", "conflict with", "pushed back", "difficult stakeholder",
                "a time you failed", "biggest mistake", "went wrong",
                "most proud of", "biggest impact", "led without authority",
                "influenced", "mentored", "convinced",
                "competing priorities", "tight deadline", "ambiguous requirements"
            ],
            beats: [
                "Situation: one line that sets the stakes.",
                "Task: what I was responsible for, one line.",
                "Action: the steps I personally drove, in I voice, the bulk of the answer.",
                "Result: the quantified outcome.",
                "Lesson: what I took forward, offered briefly."
            ],
            spokenLengthTarget: "90 seconds to 2 minutes, action carries most of it",
            voiceStyle: .spoken,
            allowsCode: false,
            allowsMermaid: false,
            legacyIntent: .conversation,
            depth: .spokenFast
        ),
        InterviewAnswerPlaybook(
            id: "strengths_pitch",
            displayName: "Strengths",
            frameworkName: "Claim Evidence Relevance",
            frameworkSummary: "One strength chosen for this role, a quantified moment that proves it, and the mapping to the job's day to day.",
            strongCues: [
                "what are your strengths",
                "your biggest strength",
                "what are you great at",
                "why should we hire you"
            ],
            cues: ["what sets you apart", "your superpower"],
            beats: [
                "Claim: the one strength most relevant to this role.",
                "Evidence: a quantified moment that proves it.",
                "Relevance: how it maps onto what this job needs."
            ],
            spokenLengthTarget: "45 to 60 seconds",
            voiceStyle: .spoken,
            allowsCode: false,
            allowsMermaid: false,
            legacyIntent: .conversation,
            depth: .spokenFast
        ),
        InterviewAnswerPlaybook(
            id: "weakness_growth",
            displayName: "Weakness and growth",
            frameworkName: "Three Ps",
            frameworkSummary: "A real non disqualifying weakness, the plan already underway to manage it, and proof it is improving.",
            strongCues: [
                "biggest weakness",
                "greatest weakness",
                "development area",
                "critical feedback you received",
                "what would your manager say you need"
            ],
            cues: ["area to improve", "growth area", "constructive feedback"],
            beats: [
                "Weakness: a real, non disqualifying weakness named plainly.",
                "Plan: the concrete practice I already use to manage it.",
                "Proof: recent evidence that it is improving."
            ],
            spokenLengthTarget: "45 to 60 seconds",
            voiceStyle: .spoken,
            allowsCode: false,
            allowsMermaid: false,
            legacyIntent: .conversation,
            depth: .spokenFast
        ),
        InterviewAnswerPlaybook(
            id: "hypothetical_situational",
            displayName: "Hypothetical scenario",
            frameworkName: "Principle Led Approach",
            frameworkSummary: "Confirm the key assumption, state the guiding principle, walk the steps in order, and ground it with a real adjacent moment.",
            strongCues: [
                "what would you do if",
                "how would you handle",
                "imagine you are",
                "suppose your"
            ],
            cues: ["how would you respond", "what would be your approach if"],
            beats: [
                "Clarify: the one assumption I would confirm first.",
                "Principle: the rule of thumb guiding my approach.",
                "Approach: the steps I would actually take, in order.",
                "Experience: a quick real moment where I handled something similar."
            ],
            spokenLengthTarget: "60 to 90 seconds",
            voiceStyle: .spoken,
            allowsCode: false,
            allowsMermaid: false,
            legacyIntent: .conversation,
            depth: .spokenFast
        ),
        InterviewAnswerPlaybook(
            id: "people_management",
            displayName: "People management",
            frameworkName: "STAR at Team Altitude",
            frameworkSummary: "The team context, the management principle applied, action taken through others, a team level outcome, and how it shaped my approach.",
            strongCues: [
                "underperformer",
                "how do you run your one on ones",
                "your management style",
                "hiring philosophy",
                "team disagreed with your decision",
                "how do you give feedback"
            ],
            cues: ["managing up", "low performer", "growing engineers", "delegat"],
            beats: [
                "Situation: the team context and the stakes.",
                "Principle: the management philosophy I applied.",
                "Action: what I did through others, not around them.",
                "Outcome: the team level result, with delivery or retention numbers.",
                "Lesson: how it shaped the way I manage now."
            ],
            spokenLengthTarget: "90 seconds to 2 minutes",
            voiceStyle: .spoken,
            allowsCode: false,
            allowsMermaid: false,
            legacyIntent: .conversation,
            depth: .spokenDeep
        )
    ]
}
