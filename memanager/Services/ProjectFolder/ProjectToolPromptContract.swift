import Foundation

struct ProjectToolPromptContract: Equatable {
    let rootDescriptor: ProjectToolRootDescriptor
    let systemAddendum: String
    let userAddendum: String
    let firstTurnReminder: String
    let forcedToolRecoveryReminder: String
    let pathRecoveryReminder: String
    let synthesisReminder: String

    init(rootDescriptor: ProjectToolRootDescriptor) {
        self.rootDescriptor = rootDescriptor
        self.systemAddendum = """
        Project tool loop contract:
        \(rootDescriptor.summaryLine)
        Use only project folder tools to inspect this root.

        Reasoning voice:
        Before every tool call, write one or two short sentences that narrate your intent: what you are checking and why that step advances the answer. Keep this voice present, specific, and grounded in the user's question. Avoid filler like "I will now use a tool" or "let me think." The narration is what turns a tool call into a deliberate step, so make it read like a focused engineer thinking out loud.
        Prefer sequential, purposeful tool calls that each build on what the previous call revealed. Batch tools in the same response only when the calls are genuinely independent and you would make them regardless of each other's output.
        If a tool result surprises you or redirects your plan, say so in the next narration line before the next call.

        Tool usage:
        Expect to use multiple tool calls when needed. A single call is often not enough to gather the right evidence.
        Every path argument must stay inside the selected root and must be relative to it.
        Never pass an absolute path unless it already starts inside the selected root, and prefer the relative form even then.
        Use an empty string only on tools that explicitly allow the root folder path, such as list_directory(path: "").
        When the exact path is unknown, begin with list_directory(path: ""), glob, search_files, or get_structure before deeper reads.
        If a path validation error comes back, immediately retry with a relative path or a discovery tool instead of inventing a placeholder path.

        Final answer:
        After you gather tool results, answer the user directly from those findings.
        When read_file or search_files succeed, cite exact file paths and line references, quote the relevant code in fenced code blocks, and if you propose a change include either a diff block or the exact code to add or replace.
        """
        self.userAddendum = """
        Project root reminder:
        \(rootDescriptor.summaryLine)
        Use project relative paths only. Start with \(rootDescriptor.discoveryExample) or another discovery tool if the path is unknown.
        """
        self.firstTurnReminder = """
        Forced tools are enabled for this turn. Use project folder tools before answering, and keep going until you have enough evidence to answer well. If the exact file path is not already in the user context, start with a discovery tool such as \(rootDescriptor.discoveryExample), glob, search_files, or get_structure.
        """
        self.forcedToolRecoveryReminder = """
        Forced tools are still required for this turn. Do not answer yet. Use one or more project folder tools inside \(rootDescriptor.displayPath), prefer project relative paths, and batch independent discovery or read calls when possible. If the correct path is still unknown, start with \(rootDescriptor.discoveryExample), glob, search_files, or get_structure.
        """
        self.pathRecoveryReminder = """
        The previous tool call used an invalid path for the selected root \(rootDescriptor.displayPath). Retry with a path relative to this root. Use \(rootDescriptor.discoveryExample) if you need to discover the correct location first.
        """
        self.synthesisReminder = """
        You already have project tool findings for this turn. Now answer the user directly using those findings. Cite the exact file paths and line references you used, include fenced code excerpts for the relevant lines, and if you recommend a change include a fenced diff block or exact replacement code. Do not stop at raw tool output.
        """
    }

    func synthesisReminderMessage(evidenceManifest: String) -> String {
        guard !evidenceManifest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return synthesisReminder
        }
        return """
        \(synthesisReminder)

        Evidence manifest:
        \(evidenceManifest)
        """
    }

    func evidenceRepairReminder(reason: String, evidenceManifest: String) -> String {
        let reasonBlock = reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ""
            : "Why the previous draft is not acceptable:\n\(reason)\n\n"
        let evidenceBlock = evidenceManifest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ""
            : "Use this evidence directly:\n\(evidenceManifest)"
        return """
        Rewrite the answer using the gathered tool evidence. Include exact file paths, line references, and fenced code excerpts. If you are proposing a fix, include a diff block or exact code to add or replace.

        \(reasonBlock)\(evidenceBlock)
        """
    }
}
