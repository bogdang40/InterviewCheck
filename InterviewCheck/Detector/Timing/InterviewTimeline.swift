import Combine
import Foundation
import InterviewCheckKit

/// Every final word of the interview, both sides, on one clock.
///
/// Fed by `DualStreamDeepgramService.onFinalTimedWords`: the microphone is
/// the interviewer, the computer's audio is the candidate. On a panel call
/// several remote voices arrive on the candidate side; the interviewer can
/// pick which one is the candidate.
@MainActor
final class InterviewTimeline: ObservableObject {
    static let shared = InterviewTimeline()

    @Published private(set) var words: [TimedWord] = []
    /// Remote voices in the order they were first heard.
    @Published private(set) var remoteSpeakers: [Int] = []
    /// Nil means every remote voice counts as the candidate.
    @Published var candidateSpeakerIndex: Int?
    /// Host times at which either stream's audio was not contiguous.
    @Published private(set) var gapTimes: [TimeInterval] = []

    private var lastBreaks: [AudioSource: Int] = [:]
    let uptime: () -> TimeInterval

    init(uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.uptime = uptime
    }

    var now: TimeInterval { uptime() }

    func reset() {
        words = []
        remoteSpeakers = []
        candidateSpeakerIndex = nil
        gapTimes = []
        lastBreaks = [:]
    }

    func ingest(_ batch: DeepgramTimedWords) {
        let side: InterviewSide = batch.source == .microphone ? .interviewer : .candidate
        let incoming = batch.words.map { item in
            TimedWord(
                side: side,
                speakerIndex: side == .candidate ? (item.word.speaker ?? 0) : nil,
                text: item.word.punctuatedWord ?? item.word.word,
                start: item.hostStart,
                end: item.hostEnd,
                confidence: item.word.confidence,
                isFiller: FillerLexicon.isFiller(item.word.word)
            )
        }
        noteBreaks(batch.clockBreaks, source: batch.source, at: incoming.first?.start ?? now)
        append(incoming)
    }

    /// Adds words keeping the list ordered by start time. The two streams
    /// deliver independently, so a batch can land before the tail.
    func append(_ incoming: [TimedWord]) {
        guard !incoming.isEmpty else { return }
        for word in incoming where word.side == .candidate {
            if let speaker = word.speakerIndex, !remoteSpeakers.contains(speaker) {
                remoteSpeakers.append(speaker)
            }
        }
        if let last = words.last, let first = incoming.first, first.start < last.start {
            words = (words + incoming).sorted { $0.start < $1.start }
        } else {
            words.append(contentsOf: incoming)
        }
    }

    func isCandidate(_ word: TimedWord) -> Bool {
        guard word.side == .candidate else { return false }
        guard let chosen = candidateSpeakerIndex, let speaker = word.speakerIndex else { return true }
        return speaker == chosen
    }

    func hasGap(between start: TimeInterval, and end: TimeInterval) -> Bool {
        gapTimes.contains { $0 >= start && $0 <= end }
    }

    private func noteBreaks(_ count: Int, source: AudioSource, at time: TimeInterval) {
        let previous = lastBreaks[source] ?? 0
        if count > previous { gapTimes.append(time) }
        lastBreaks[source] = count
    }
}
