import Combine
import Foundation

/// Accumulates `CanvasCommand`s into a `CanvasScene` and publishes the
/// latest snapshot for SwiftUI. Also owns the TTL sweep for highlights so
/// the scene does not retain stale visual callouts.
final class CanvasDirector: ObservableObject {
    @Published private(set) var scene: CanvasScene = .empty

    typealias HighlightScheduler = (Int, @escaping () -> Void) -> AnyCancellable

    private struct HighlightExpiry {
        let token: UUID
        let cancellation: AnyCancellable
    }

    private var expirations: [CanvasHighlightPayload.Identity: HighlightExpiry] = [:]
    private let scheduleDecay: HighlightScheduler
    private let queue = DispatchQueue.main

    convenience init() {
        self.init { milliseconds, action in
            Just(())
                .delay(for: .milliseconds(milliseconds), scheduler: DispatchQueue.main)
                .sink { _ in action() }
        }
    }

    /// The scheduler fires on the main queue. Tests supply a manual clock.
    init(scheduleDecay: @escaping HighlightScheduler) {
        self.scheduleDecay = scheduleDecay
    }

    func apply(_ commands: [CanvasCommand]) {
        guard !commands.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            var next = self.scene
            for command in commands {
                next.apply(command)
                switch command {
                case .highlight(let payload):
                    self.scheduleHighlightDecay(payload)
                case .clear(let sceneID):
                    self.expirations = self.expirations.filter { $0.key.targetID != sceneID }
                default:
                    break
                }
            }
            self.scene = next
        }
    }

    func reset() {
        queue.async { [weak self] in
            self?.scene = .empty
            self?.expirations.removeAll()
        }
    }

    // MARK: - TTL

    private func scheduleHighlightDecay(_ payload: CanvasHighlightPayload) {
        let ttl = max(200, payload.ttlMs)
        let key = payload.identity
        let token = UUID()
        expirations.removeValue(forKey: key)?.cancellation.cancel()
        let cancellation = scheduleDecay(ttl) { [weak self] in
            guard let self, self.expirations[key]?.token == token else { return }
            var next = self.scene
            next.highlights.removeAll { $0.identity == key }
            self.scene = next
            self.expirations.removeValue(forKey: key)
        }
        expirations[key] = HighlightExpiry(token: token, cancellation: cancellation)
    }
}
