import Foundation
import CoreGraphics

/// Tracks capture ownership across session changes, cache fills, and resets.
/// Background prewarming only mutates this synchronized state.
final class ScreenshotCaptureState {
    struct Identity: Equatable {
        let sessionID: UUID
        let generation: UUID
    }

    struct Display: Equatable {
        let id: CGDirectDisplayID
        let bounds: CGRect
    }

    struct Request: Equatable {
        let identity: Identity
        let display: Display
        let id = UUID()
    }

    private struct CachedImage {
        let request: Request
        let base64: String
        let capturedAt: Date
    }

    private let lock = NSLock()
    private let validity: TimeInterval
    private var generation = UUID()
    private var cachedImage: CachedImage?
    private var activeRequest: Request?

    init(validity: TimeInterval = 3.5) {
        self.validity = validity
    }

    func identity(sessionID: UUID) -> Identity {
        lock.lock()
        defer { lock.unlock() }
        return Identity(sessionID: sessionID, generation: generation)
    }

    func isCurrent(_ identity: Identity) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return identity.generation == generation
    }

    func cachedBase64(for identity: Identity, display: Display, now: Date = Date()) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return cachedBase64Locked(for: identity, display: display, now: now)
    }

    func beginCapture(
        for identity: Identity,
        display: Display,
        prewarm: Bool = false,
        now: Date = Date()
    ) -> Request? {
        lock.lock()
        defer { lock.unlock() }
        guard identity.generation == generation else { return nil }
        if prewarm {
            guard cachedBase64Locked(for: identity, display: display, now: now) == nil else { return nil }
            if activeRequest?.identity == identity, activeRequest?.display == display { return nil }
        }
        let request = Request(identity: identity, display: display)
        activeRequest = request
        return request
    }

    @discardableResult
    func finishCapture(_ request: Request, base64: String?, capturedAt: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard request.identity.generation == generation, activeRequest == request else { return false }
        activeRequest = nil
        if let base64 {
            cachedImage = CachedImage(request: request, base64: base64, capturedAt: capturedAt)
        }
        return true
    }

    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        generation = UUID()
        cachedImage = nil
        activeRequest = nil
    }

    private func cachedBase64Locked(for identity: Identity, display: Display, now: Date) -> String? {
        guard identity.generation == generation,
              let cachedImage,
              cachedImage.request.identity == identity,
              cachedImage.request.display == display else { return nil }
        let age = now.timeIntervalSince(cachedImage.capturedAt)
        guard age >= 0, age < validity else { return nil }
        return cachedImage.base64
    }
}
