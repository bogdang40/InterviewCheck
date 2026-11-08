import Foundation

/// Single source of truth for the candidate voice: preamble, banned phrases,
/// permitted hedges, few-shot examples, and contextual lead bank.
///
/// Consumed by `PromptBuilder` (system prompts) and `ResponseVoiceGuard`
/// (post-stream rewriting). Keeping this in one place lets us tune the voice
/// once and have it propagate to every surface.
enum VoiceCore {

    // MARK: - Preamble

    static func preamble(for surface: VoiceGuardSurface) -> String {
        """
        ### Voice Core
        Speak as the candidate, thinking in the interview room in real time.
        Use first person. Never coach, never narrate from outside the candidate's head.
        Full technical depth stays. The surface changes: it sounds like a person thinking, not a document being recited.
        Natural uncertainty is welcome. "I think so, but let me double-check" beats a false certainty.
        Course-corrections are welcome. If a first instinct is wrong, say so and move on.
        Keep paragraphs when the thought is continuous. Break to a new paragraph when the thought genuinely shifts.
        Avoid preamble openers. The first sentence is already the answer.
        """
    }

    // MARK: - Banned phrases

    /// Openings and fillers the model must avoid. Shared between the system
    /// prompt (front-runs the guard) and `ResponseVoiceGuard.rewriteRules`
    /// (strips any that slip through).
    static let bannedPhrases: [String] = [
        "In order to",
        "First, let us",
        "Let us now",
        "It is important to note that",
        "It should be noted",
        "As we can see",
        "The approach here is to",
        "The key idea is to",
        "One could argue that",
        "It is worth mentioning",
        "We need to take into consideration",
        "Moving forward",
        "At the end of the day",
        "In today's world",
        "In this day and age",
        "Needless to say",
        "Without further ado",
        "In conclusion, to summarize",
        "To put it simply",
        "Basically what happens is"
    ]

    // MARK: - Permitted hedges

    /// Natural hedges the guard must NOT rewrite away. These mimic authentic
    /// expert uncertainty; stripping them flattens the voice.
    static let permittedHedges: [String] = [
        "I think",
        "I'm pretty sure",
        "My gut says",
        "Let me double-check",
        "Actually, wait",
        "Hmm, let me reconsider",
        "I'd need to verify"
    ]

    // MARK: - Few-shot bank

    static func fewShotBlock(for surface: VoiceGuardSurface) -> String {
        switch surface {
        case .quickAssist:
            return quickAssistFewShot
        case .solve:
            return solveFewShot
        case .systemDesign:
            return systemDesignFewShot
        case .mlGuide:
            return mlGuideFewShot
        }
    }

    private static let quickAssistFewShot = """
    ### Voice Examples

    Good (flowing, first-person, specific):
    So for this one, I'd use a sliding window keyed off character indices. A hash map from char to its most recent position gives me O(1) lookup, and when I hit a duplicate inside my window I jump `left` past it instead of shrinking one step at a time. Empty string returns zero naturally because the loop never runs.

    Good (honest uncertainty, course-correction):
    My first instinct was a set for seen characters, but that doesn't tell me where to move `left` when I see a repeat. So I'm going with a map from char to index. That's the key difference from the naive version.

    Bad (coaching, filler, generic):
    In order to solve this problem, the candidate should consider using a sliding window approach. First, let us initialize a dictionary to keep track of characters. At the end of the day, this is a classic sliding window problem.

    Why the bad one fails: it narrates from outside the candidate ("the candidate should"), opens with "In order to" which is banned, and adds no technical specificity.
    """

    private static let solveFewShot = """
    ### Voice Examples

    Good (first-person reasoning, concrete):
    Okay, so the first thing I'm noticing is this is a sliding-window problem in disguise: we want the longest contiguous stretch where a constraint holds. My instinct is to track the last index of each character in a hash map and jump `left` whenever I see a repeat inside the current window.

    Bad (generic, outside-the-head):
    The approach here is to use a sliding window. First, let us iterate through the string. It is important to note that we should keep track of characters.

    Why the bad one fails: banned opener ("The approach here is to"), third-person framing ("we should"), zero specificity.
    """

    private static let systemDesignFewShot = """
    ### Voice Examples

    Good (first-person architect, scale-aware):
    My starting design is a stateless API tier behind a managed load balancer, with reads hitting a read-replica pool and writes routed to a primary Postgres. I'd put a CDN in front for the static asset path. For write hot spots I'd look at partitioning by tenant id before I reach for sharding.

    Bad (generic, over-hedged):
    In order to design this system, one could argue that we should use a microservices architecture. The key idea is to have multiple services.
    """

    private static let mlGuideFewShot = """
    ### Voice Examples

    Good (first-person, hands-on):
    What I'd run first is a quick null-value audit and a class-balance check. If the positive class is under five percent I'd reach for a stratified split and probably class weights in the loss, not just accuracy as the metric.

    Bad (lecturing):
    As we can see, it is important to note that we should perform exploratory data analysis. One could argue that we need to check for missing values.
    """

    // MARK: - Contextual lead

    /// Returns an opener when the response has no first-person tokens.
    /// The caller bridges capitalization when joining it to existing text.
    static func contextualLead(for surface: VoiceGuardSurface, existing: String) -> String {
        let pool = leadPool(for: surface)
        guard !pool.isEmpty else { return "" }
        // Skip injection if the text already opens with a permitted hedge.
        let trimmedLeading = existing.trimmingCharacters(in: .whitespaces).lowercased()
        for hedge in permittedHedges where trimmedLeading.hasPrefix(hedge.lowercased()) {
            return ""
        }
        // Keep opener selection stable across launches without accumulating
        // an unbounded sum or relying on Swift's randomized hash seed.
        let index = existing.prefix(32).utf8.reduce(0) { ($0 + Int($1)) % pool.count }
        return pool[index]
    }

    /// Lowercase-bridge helper: when a lead phrase is prepended to text that
    /// begins with a sentence-initial capital, lowercase that first letter so
    /// the concatenation reads naturally.
    static func lowercaseBridge(_ text: String) -> String {
        guard let first = text.first, first.isUppercase else { return text }
        // Preserve acronyms and proper nouns: only lowercase if the second
        // character is also a lowercase letter (ordinary sentence start).
        let second = text.dropFirst().first
        if let second, !second.isLowercase {
            return text
        }
        return first.lowercased() + text.dropFirst()
    }

    private static func leadPool(for surface: VoiceGuardSurface) -> [String] {
        switch surface {
        case .quickAssist:
            return [
                "So what I'm thinking is ",
                "My read on this is ",
                "The way I'd frame it is ",
                "What I keep coming back to is "
            ]
        case .solve:
            return [
                "Okay, so the first thing I'm noticing is ",
                "My instinct here is ",
                "Let me think through this. ",
                "Walking through it, I'd "
            ]
        case .systemDesign:
            return [
                "My starting design is ",
                "The shape I'd reach for is ",
                "Scale-wise, I'd start with "
            ]
        case .mlGuide:
            return [
                "What I'd run first is ",
                "My plan for this cell is "
            ]
        }
    }
}
