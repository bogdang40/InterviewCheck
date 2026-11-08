import Foundation

/// Narrative and identity families: who the candidate is, why they are here,
/// and the stories that anchor both. Frameworks follow the coaching canon:
/// present past future for self introductions, three circle fit for
/// motivation, recap then own for take home defenses.
enum InterviewNarrativePlaybooks {
    static let all: [InterviewAnswerPlaybook] = [
        InterviewAnswerPlaybook(
            id: "self_intro",
            displayName: "Self introduction",
            frameworkName: "Present Past Future",
            frameworkSummary: "A one line identity thesis, the present role, two past proof points, and why this role is the logical next step.",
            strongCues: [
                "tell me about yourself",
                "walk me through your resume",
                "walk me through your background",
                "introduce yourself",
                "tell us about your background"
            ],
            cues: ["your journey", "your story", "about your experience"],
            beats: [
                "Thesis: one line identity claim that frames me for this exact role.",
                "Present: current role, scope, and the work that maps hardest onto this job.",
                "Past: two proof points that built the relevant strengths, each with a number.",
                "Future: why this role is the logical next step and what I want to build here."
            ],
            spokenLengthTarget: "60 to 90 seconds",
            voiceStyle: .spoken,
            allowsCode: false,
            allowsMermaid: false,
            legacyIntent: .conversation,
            depth: .spokenFast
        ),
        InterviewAnswerPlaybook(
            id: "motivation",
            displayName: "Motivation",
            frameworkName: "Three Circle Fit",
            frameworkSummary: "A specific company hook, the mapping from my strengths to the role, and the career trajectory logic.",
            strongCues: [
                "why do you want to work here",
                "why this company",
                "why this role",
                "why are you leaving",
                "why us",
                "where do you see yourself"
            ],
            cues: ["what do you know about our company", "what attracts you", "why now"],
            beats: [
                "Hook: the specific thing about this company or product that genuinely pulls me.",
                "Fit: how my strengths map onto what this role needs day to day.",
                "Trajectory: why this step makes sense in my career arc right now."
            ],
            spokenLengthTarget: "45 to 60 seconds",
            voiceStyle: .spoken,
            allowsCode: false,
            allowsMermaid: false,
            legacyIntent: .conversation,
            depth: .spokenFast
        ),
        InterviewAnswerPlaybook(
            id: "values_fit",
            displayName: "Values fit",
            frameworkName: "Value in Action",
            frameworkSummary: "Name the principle, prove it with one concrete moment under pressure, and connect it to how I would work with this team.",
            strongCues: [
                "what environment do you thrive",
                "which of our principles",
                "what matters to you in a team",
                "describe your ideal culture"
            ],
            cues: ["culture fit", "your values", "how do you like to work"],
            beats: [
                "Value: the principle that actually drives how I work, named plainly.",
                "Story: one concrete moment where I applied it under pressure.",
                "Fit: how that shows up in the way I would work with this team."
            ],
            spokenLengthTarget: "45 to 60 seconds",
            voiceStyle: .spoken,
            allowsCode: false,
            allowsMermaid: false,
            legacyIntent: .conversation,
            depth: .spokenFast
        ),
        InterviewAnswerPlaybook(
            id: "project_deep_dive",
            displayName: "Project deep dive",
            frameworkName: "Context Role Decisions Impact",
            frameworkSummary: "Set the problem, claim exactly what I owned, defend the hardest technical calls, quantify the impact, and close with the retrospective.",
            strongCues: [
                "tell me about a project",
                "most challenging project",
                "project you are most proud of",
                "what are you working on",
                "go deeper on that project"
            ],
            cues: ["your recent work", "technical challenge you faced", "walk me through the project"],
            beats: [
                "Context: the problem and why it mattered, one or two sentences.",
                "Role: exactly what I owned, in I voice, no hiding behind we.",
                "Decisions: the two or three hardest technical calls and why I made them.",
                "Impact: the quantified outcome the work produced.",
                "Retrospective: what I would do differently now."
            ],
            spokenLengthTarget: "90 seconds to 2 minutes, then invite the deep dive",
            voiceStyle: .spoken,
            allowsCode: false,
            allowsMermaid: false,
            legacyIntent: .conversation,
            depth: .spokenDeep
        ),
        InterviewAnswerPlaybook(
            id: "take_home_defense",
            displayName: "Take home defense",
            frameworkName: "Recap Then Own",
            frameworkSummary: "A two minute recap of problem, approach, and the key decision, then proactive ownership of tradeoffs and limitations.",
            strongCues: [
                "walk us through your solution",
                "walk me through your submission",
                "why did you choose that in your solution",
                "explain your take home"
            ],
            cues: ["your assignment", "the exercise you submitted", "your submission"],
            beats: [
                "Recap: the problem, my approach, and the one decision that shaped everything.",
                "Tradeoffs: the alternatives I weighed and why I landed where I did.",
                "Limitations: what I knowingly cut and why that was the right scope call.",
                "Extensions: what I would build next with more time."
            ],
            spokenLengthTarget: "2 minute recap, then answer questions",
            voiceStyle: .spoken,
            allowsCode: false,
            allowsMermaid: false,
            legacyIntent: .conversation,
            depth: .spokenDeep
        )
    ]
}
