import Foundation

/// Tracks visible text emission across one OpenAI Responses SSE stream.
///
/// The Responses API emits incremental `response.output_text.delta` events and
/// then a `response.output_text.done` event carrying the full accumulated text
/// for the same output item. Emitting both duplicates the answer, but the done
/// event is also the only text source for streams that never emit deltas, so
/// suppression must be tracked per output item rather than globally.
struct OpenAIResponsesStreamState {
    private(set) var hasVisibleText = false
    private(set) var completed = false
    private var deltaEmittingItemKeys: Set<String> = []

    /// Stands in for events that carry no item identity. When deltas arrive
    /// without identifiers, any done event is treated as their accumulation.
    private static let fallbackItemKey = "__no_item__"

    mutating func registerDeltaEmitted(itemKey: String?) {
        deltaEmittingItemKeys.insert(itemKey ?? Self.fallbackItemKey)
        hasVisibleText = true
    }

    /// A done event's text is redundant when deltas already streamed for the
    /// same item, or when either side lacks item identity and any deltas were
    /// seen (the conservative reading that prevents whole-answer duplication).
    func shouldSuppressDoneText(itemKey: String?) -> Bool {
        guard let itemKey else {
            return !deltaEmittingItemKeys.isEmpty
        }
        return deltaEmittingItemKeys.contains(itemKey)
            || deltaEmittingItemKeys.contains(Self.fallbackItemKey)
    }

    mutating func markVisibleTextEmitted() {
        hasVisibleText = true
    }

    mutating func markCompleted() {
        completed = true
    }
}
