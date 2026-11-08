import Foundation

/// One planned AI answer: a provider and model, with one cheater prompt.
struct ReferenceRun: Equatable {
    let entry: LineupEntry
    let prompt: CheaterPrompt
}

/// Asks every provider in the lineup, with every enabled cheater prompt, at
/// the same time, and streams each answer to the screen as it arrives.
final class ReferenceAnswerRunner {
    static let maxRuns = 6

    typealias ClientMaker = (AIProviderType, String) throws -> DetectorTextGenerating
    private let makeClient: ClientMaker
    private let clock: () -> TimeInterval
    private let deliver: (@escaping () -> Void) -> Void

    init(
        makeClient: @escaping ClientMaker = { try DetectorTextClientFactory.make(provider: $0, model: $1) },
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        deliver: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }
    ) {
        self.makeClient = makeClient
        self.clock = clock
        self.deliver = deliver
    }

    /// Pairs providers with prompts round by round, so a capped list still
    /// covers every provider and every prompt (a Latin square, not a grid
    /// filled row by row).
    static func plan(lineup: [LineupEntry], prompts: [CheaterPrompt], limit: Int = maxRuns) -> [ReferenceRun] {
        let entries = lineup.filter(\.isEnabled)
        let enabled = prompts.filter(\.isEnabled)
        guard !entries.isEmpty, !enabled.isEmpty else { return [] }
        var runs: [ReferenceRun] = []
        for round in 0..<enabled.count {
            for (index, entry) in entries.enumerated() {
                runs.append(ReferenceRun(entry: entry, prompt: enabled[(index + round) % enabled.count]))
            }
        }
        return Array(runs.prefix(limit))
    }

    /// Runs all requests in parallel. `onUpdate` is called on the main queue
    /// with each answer as it grows; the returned records are final.
    func run(
        questionID: String,
        question: String,
        context: RoleContext,
        runs: [ReferenceRun],
        onUpdate: @escaping (ReferenceAnswerRecord) -> Void
    ) async -> [ReferenceAnswerRecord] {
        await withTaskGroup(of: ReferenceAnswerRecord.self) { group in
            for run in runs {
                group.addTask { await self.runOne(run, questionID: questionID, question: question,
                                                  context: context, onUpdate: onUpdate) }
            }
            var results: [ReferenceAnswerRecord] = []
            for await record in group { results.append(record) }
            let order = runs.map(\.entry.id)
            return results.sorted { (order.firstIndex(of: $0.id.lineupID) ?? 0) < (order.firstIndex(of: $1.id.lineupID) ?? 0) }
        }
    }

    private func runOne(
        _ run: ReferenceRun,
        questionID: String,
        question: String,
        context: RoleContext,
        onUpdate: @escaping (ReferenceAnswerRecord) -> Void
    ) async -> ReferenceAnswerRecord {
        let started = clock()
        var record = ReferenceAnswerRecord(
            id: "\(run.entry.id)|\(run.prompt.id)|\(questionID)", questionID: questionID,
            provider: run.entry.provider, model: run.entry.model, promptName: run.prompt.name,
            text: "", isStreaming: true
        )
        let initial = record
        deliver { onUpdate(initial) }

        let request = CheaterPromptLibrary.request(for: run.prompt, question: question, context: context)
        let buffer = StreamBuffer()
        do {
            let client = try makeClient(run.entry.provider, run.entry.model)
            let full = try await client.streamText(system: request.system, user: request.user) { [clock, deliver] chunk in
                let snapshot = buffer.append(chunk, elapsed: clock() - started)
                var partial = initial
                partial.text = snapshot.text
                partial.firstSentenceSeconds = snapshot.firstSentence
                deliver { onUpdate(partial) }
            }
            let cleaned = request.appliesVoiceGuard
                ? ResponseVoiceGuard().normalizeText(full, surface: .quickAssist).text : full
            if cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw DetectorClientError.emptyReply }
            record.text = cleaned
            record.firstSentenceSeconds = buffer.snapshot.firstSentence ?? (clock() - started)
        } catch {
            record.text = buffer.snapshot.text
            record.error = error.localizedDescription
        }
        record.totalSeconds = clock() - started
        record.isStreaming = false
        let final = record
        deliver { onUpdate(final) }
        return record
    }
}

/// Collects streamed text from whichever thread delivers it.
final class StreamBuffer: @unchecked Sendable {
    struct Snapshot {
        let text: String
        let firstSentence: TimeInterval?
    }

    private let lock = NSLock()
    private var text = ""
    private var firstSentence: TimeInterval?

    func append(_ chunk: String, elapsed: TimeInterval) -> Snapshot {
        lock.withLock {
            text += chunk
            if firstSentence == nil, Self.hasCompleteSentence(text) { firstSentence = elapsed }
            return Snapshot(text: text, firstSentence: firstSentence)
        }
    }

    var snapshot: Snapshot { lock.withLock { Snapshot(text: text, firstSentence: firstSentence) } }

    /// Enough to start reading: at least eight words up to the latest full
    /// stop, question mark, exclamation mark or line break. ("Great
    /// question." alone is not enough to read from.)
    static func hasCompleteSentence(_ text: String) -> Bool {
        guard let end = text.lastIndex(where: { ".!?\n".contains($0) }) else { return false }
        return text[..<end].split(whereSeparator: \.isWhitespace).count >= 8
    }
}

private extension String {
    /// The lineup entry part of a reference id ("entry|prompt|question").
    var lineupID: String { split(separator: "|").first.map(String.init) ?? self }
}
