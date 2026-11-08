import Foundation
import SwiftUI
@testable import memanager

/// Realistic data for the render smoke tests: a coding answer in the exact
/// prompt contract shape, a two party transcript, and shell chrome models.
@MainActor
enum OverlayRenderFixtures {
    static let liveQuestion = LiveQuestion(
        speaker: .speaker(0),
        text: "Can you walk me through how you would find the longest substring without repeating characters?",
        isQuestion: true,
        isPartial: false
    )

    static let transcriptRows: [TranscriptRowModel] = [
        TranscriptRowModel(id: UUID(), speaker: .speaker(0), text: "Thanks for joining. Let's start with a warm up on strings.", isPartial: false, timestamp: Date(), deepgramSpeakerId: 0),
        TranscriptRowModel(id: UUID(), speaker: .me, text: "Sounds good, happy to dive in.", isPartial: false, timestamp: Date(), deepgramSpeakerId: nil),
        TranscriptRowModel(id: UUID(), speaker: .speaker(0), text: "Can you walk me through how you would find the longest substring without repeating characters?", isPartial: false, timestamp: Date(), deepgramSpeakerId: 0),
        TranscriptRowModel(id: UUID(), speaker: .me, text: "So what we are really being asked is to find the longest window where every character appears once. My instinct is a sliding window with a last seen map.", isPartial: false, timestamp: Date(), deepgramSpeakerId: nil),
        TranscriptRowModel(id: UUID(), speaker: .speaker(0), text: "What happens when the input is empty", isPartial: true, timestamp: nil, deepgramSpeakerId: 0)
    ]

    static var codingResponse: MentorResponse {
        MentorResponse.parse(from: codingAnswer)
    }

    static let codingAnswer = """
    ## Problem
    **Restating the problem:** Given a string, return the length of the longest run of characters in which no character repeats.

    **Key constraints:**
    - Time: The string can be 100k characters, so quadratic is out.
    - Space: A map of last positions per character is fine.
    - Input: ASCII or unicode scalars, possibly empty.
    - Output: A single integer length.

    **The real insight here:** A sliding window only ever moves forward, because a repeat inside the window can only be fixed by moving the left edge past the earlier copy.

    **Why this approach is correct:** Every index is visited at most twice, once by each edge, and the window is always the widest valid window ending at the right edge.

    ## Clarifying Questions
    **Edge cases to clarify:**
    - Should an empty string return zero? (Assuming: yes)
    - Are characters case sensitive? (Assuming: yes)

    **Constraints to confirm:**
    - Maximum length of the input

    **Input validation:**
    - Can the input be nil rather than empty?

    ## Implementation
    **Step 1: Track the last index of each character**
    I will keep a dictionary from character to the last index it appeared at, and two pointers for the window.

    ```python
    def longest_unique(s: str) -> int:
        last_seen = {}
        left = 0
        best = 0
    ```

    **Step 2: Slide the right edge and jump the left edge on repeats**
    When the right character was seen inside the window, the left edge jumps just past that earlier position.

    ```python
    def longest_unique(s: str) -> int:
        last_seen = {}
        left = 0
        best = 0
        for right, char in enumerate(s):
            if char in last_seen and last_seen[char] >= left:
                left = last_seen[char] + 1
            last_seen[char] = right
            best = max(best, right - left + 1)
        return best
    ```

    ## Tests
    **Base cases:**
    - `"abcabcbb"` -> `3` (the window abc)
    - `"bbbbb"` -> `1` (every window is one character)

    **Edge cases:**
    - `""` -> `0` (empty input)
    - `"pwwkew"` -> `3` (wke, not pwke)

    **Error cases:**
    - `None` -> `0` (treat missing input as empty)

    ## Complexity
    **Time: O(n)** Each index is visited by the right pointer once and the left pointer at most once.

    **Space: O(k)** where k is the alphabet size, since the map holds one entry per distinct character.

    **Trade-off:** A set with explicit shrinking is simpler to explain but can move the left pointer one step at a time, which is still linear but slower in practice.
    """

    static func commandBar(width: CGFloat, surface: MentorSurface, screen: OverlayScreen) -> some View {
        CommandBar(width: width, destination: OverlayDestination(screen: screen), onSelect: { _ in })
    }

    static func statusBar(width: CGFloat, surface: MentorSurface) -> some View {
        StatusBar(
            width: width,
            dotState: .recording,
            providerName: "Claude sonnet-5",
            transcriptCount: 12,
            screenshotCount: 2,
            workspaceTitle: "Stripe Staff Engineer",
            hints: StatusHintCatalog.hints(surface: surface, screen: .mentor)
        )
    }
}
