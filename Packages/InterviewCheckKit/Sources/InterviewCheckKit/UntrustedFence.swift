import Foundation

/// Wraps text the model must read but never obey (a candidate's transcribed
/// speech) in named tags. Any tag of the same name inside the text is
/// defused, so the text cannot close the fence and speak as the prompt.
public struct UntrustedFence: Equatable, Sendable {
    public let tag: String

    public init(tag: String) { self.tag = tag }

    public var openTag: String { "<\(tag)>" }
    public var closeTag: String { "</\(tag)>" }

    public func wrap(_ text: String) -> String {
        [openTag, defused(text), closeTag].joined(separator: "\n")
    }

    /// "<candidate_answer>", "</ CANDIDATE_ANSWER >" and the like become
    /// "(candidate_answer)", which reads the same but is no tag.
    func defused(_ text: String) -> String {
        let pattern = "<\\s*/?\\s*" + NSRegularExpression.escapedPattern(for: tag) + "\\s*>?"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "(\(tag))")
    }
}
