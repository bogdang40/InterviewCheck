import Foundation

/// Adaptive single-flight scheduler for Design section Mermaid rendering.
/// Serializes render dispatches and coalesces rapid updates by slot.
actor SystemDesignMermaidRenderScheduler {
    enum DispatchDecision: Equatable {
        case superseded
        case dispatch(token: UUID, intervalMs: Int)
    }

    enum RenderOutcome: String {
        case success
        case failure
        case timeout
        case cancelled
    }

    static let shared = SystemDesignMermaidRenderScheduler()

    private struct PendingRequest {
        let requestID: String
        let continuation: CheckedContinuation<DispatchDecision, Never>
    }

    private struct CompletionPayload {
        let durationMs: Int
        let outcome: RenderOutcome
    }

    private let minIntervalMs: Int
    private let maxIntervalMs: Int
    private let increaseStepMs: Int
    private let decreaseStepMs: Int
    private let highPressureSamples: Int
    private let lowPressureSamples: Int
    private let isLoggingEnabled: Bool

    private var currentIntervalMs: Int
    private var nextDispatchAt: Date?

    private var pendingBySlot: [String: PendingRequest] = [:]
    private var queueOrder: [String] = []
    private var warmedSlots: Set<String> = []
    private var isRunning = false

    private var inFlightToken: UUID?
    private var inFlightCompletion: CheckedContinuation<CompletionPayload, Never>?

    private var highPressureStreak = 0
    private var lowPressureStreak = 0

    private var totalEnqueued = 0
    private var totalCoalesced = 0
    private var totalDispatched = 0
    private var totalTimedOut = 0

    init(
        baseIntervalMs: Int = 1000,
        minIntervalMs: Int = 750,
        maxIntervalMs: Int = 2000,
        increaseStepMs: Int = 150,
        decreaseStepMs: Int = 150,
        highPressureSamples: Int = 2,
        lowPressureSamples: Int = 3,
        isLoggingEnabled: Bool = true
    ) {
        self.currentIntervalMs = max(minIntervalMs, min(baseIntervalMs, maxIntervalMs))
        self.minIntervalMs = minIntervalMs
        self.maxIntervalMs = maxIntervalMs
        self.increaseStepMs = increaseStepMs
        self.decreaseStepMs = decreaseStepMs
        self.highPressureSamples = max(1, highPressureSamples)
        self.lowPressureSamples = max(1, lowPressureSamples)
        self.isLoggingEnabled = isLoggingEnabled
    }

    func enqueue(slotID: String, requestID: String) async -> DispatchDecision {
        await withCheckedContinuation { continuation in
            totalEnqueued += 1

            if let previous = pendingBySlot[slotID] {
                totalCoalesced += 1
                previous.continuation.resume(returning: .superseded)
            } else {
                queueOrder.append(slotID)
            }

            pendingBySlot[slotID] = PendingRequest(
                requestID: requestID,
                continuation: continuation
            )

            maybeLogEnqueueStats(slotID: slotID)

            if !isRunning {
                isRunning = true
                Task { await self.drainQueue() }
            }
        }
    }

    func reportCompletion(token: UUID, durationMs: Int, outcome: RenderOutcome) {
        guard inFlightToken == token else { return }

        let boundedDuration = max(0, durationMs)
        inFlightToken = nil
        let continuation = inFlightCompletion
        inFlightCompletion = nil
        continuation?.resume(
            returning: CompletionPayload(
                durationMs: boundedDuration,
                outcome: outcome
            )
        )
    }

    func currentIntervalMilliseconds() -> Int {
        currentIntervalMs
    }

    func waitForIdle(timeoutMs: Int = 5000) async -> Bool {
        let start = Date()
        while isRunning || !queueOrder.isEmpty || inFlightToken != nil {
            if Date().timeIntervalSince(start) * 1000 > Double(timeoutMs) {
                return false
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return true
    }

    private func drainQueue() async {
        while !queueOrder.isEmpty {
            let slotID = queueOrder.removeFirst()
            guard let pending = pendingBySlot.removeValue(forKey: slotID) else { continue }

            let isColdSlot = !warmedSlots.contains(slotID)
            if isColdSlot {
                warmedSlots.insert(slotID)
                maybeLogColdSlotDispatch(slotID: slotID, requestID: pending.requestID)
            }

            let delayNs = isColdSlot ? 0 : dispatchDelayNanoseconds()
            if delayNs > 0 {
                try? await Task.sleep(nanoseconds: delayNs)
            }

            let token = UUID()
            inFlightToken = token
            pending.continuation.resume(
                returning: .dispatch(token: token, intervalMs: currentIntervalMs)
            )

            let completion = await withCheckedContinuation { continuation in
                inFlightCompletion = continuation
            }

            totalDispatched += 1
            if completion.outcome == .timeout {
                totalTimedOut += 1
            }

            applyAdaptiveInterval(
                durationMs: completion.durationMs,
                queueDepth: queueOrder.count,
                outcome: completion.outcome
            )

            nextDispatchAt = Date().addingTimeInterval(Double(currentIntervalMs) / 1000.0)
            maybeLogDispatchStats(slotID: slotID, requestID: pending.requestID)
        }

        isRunning = false
    }

    private func dispatchDelayNanoseconds() -> UInt64 {
        if nextDispatchAt == nil {
            nextDispatchAt = Date().addingTimeInterval(Double(currentIntervalMs) / 1000.0)
        }
        guard let nextDispatchAt else { return 0 }
        let remaining = nextDispatchAt.timeIntervalSinceNow
        guard remaining > 0 else { return 0 }
        return UInt64(remaining * 1_000_000_000)
    }

    private func applyAdaptiveInterval(durationMs: Int, queueDepth: Int, outcome: RenderOutcome) {
        let isHighPressure = durationMs > 700 || queueDepth >= 2 || outcome == .timeout
        let isLowPressure = durationMs < 300 && queueDepth == 0 && outcome == .success

        if isHighPressure {
            highPressureStreak += 1
            lowPressureStreak = 0
            if highPressureStreak >= highPressureSamples {
                highPressureStreak = 0
                adjustInterval(by: increaseStepMs, reason: "high_pressure")
            }
            return
        }

        if isLowPressure {
            lowPressureStreak += 1
            highPressureStreak = 0
            if lowPressureStreak >= lowPressureSamples {
                lowPressureStreak = 0
                adjustInterval(by: -decreaseStepMs, reason: "low_pressure")
            }
            return
        }

        highPressureStreak = 0
        lowPressureStreak = 0
    }

    private func adjustInterval(by deltaMs: Int, reason: String) {
        let oldValue = currentIntervalMs
        let newValue = max(minIntervalMs, min(maxIntervalMs, oldValue + deltaMs))
        guard newValue != oldValue else { return }

        currentIntervalMs = newValue

        guard isLoggingEnabled else { return }
        SessionLogger.shared.logMermaidEvent(
            name: "adaptive_scheduler_interval_changed",
            details: "reason=\(reason), old=\(oldValue), new=\(newValue), queueDepth=\(queueOrder.count)"
        )
    }

    private func maybeLogEnqueueStats(slotID: String) {
        guard isLoggingEnabled else { return }

        let shouldLogCoalescing = totalCoalesced > 0 && totalCoalesced % 25 == 0
        let shouldLogQueueGrowth = queueOrder.count >= 4 && totalEnqueued % 10 == 0
        guard shouldLogCoalescing || shouldLogQueueGrowth else { return }

        SessionLogger.shared.logMermaidEvent(
            name: "adaptive_scheduler_enqueue_stats",
            details: "slot=\(slotID), queueDepth=\(queueOrder.count), enqueued=\(totalEnqueued), coalesced=\(totalCoalesced), interval=\(currentIntervalMs)"
        )
    }

    private func maybeLogDispatchStats(slotID: String, requestID: String) {
        guard isLoggingEnabled else { return }

        let shouldLogDispatch = totalDispatched % 20 == 0
        let shouldLogTimeout = totalTimedOut > 0 && totalTimedOut % 5 == 0
        guard shouldLogDispatch || shouldLogTimeout else { return }

        SessionLogger.shared.logMermaidEvent(
            name: "adaptive_scheduler_dispatch_stats",
            details: "slot=\(slotID), request=\(requestID), queueDepth=\(queueOrder.count), dispatched=\(totalDispatched), timeoutCount=\(totalTimedOut), interval=\(currentIntervalMs)"
        )
    }

    private func maybeLogColdSlotDispatch(slotID: String, requestID: String) {
        guard isLoggingEnabled else { return }
        SessionLogger.shared.logMermaidEvent(
            name: "adaptive_scheduler_cold_slot_dispatch",
            details: "slot=\(slotID), request=\(requestID), queueDepth=\(queueOrder.count), interval=\(currentIntervalMs)"
        )
    }
}
