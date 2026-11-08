import Combine
import Foundation
import ImageIO
import os

/// Keeps PNG decoding off the main actor and retains only the current pose.
actor AbleyWelcomeFrames {
    private let bundle: Bundle
    private var cachedIndex: Int?
    private var cachedImage: CGImage?

    init(bundle: Bundle = .main) { self.bundle = bundle }

    func image(at index: Int) throws -> CGImage {
        let index = min(AbleyWelcomeMotion.frameCount - 1, max(0, index))
        if cachedIndex == index, let cachedImage { return cachedImage }
        let name = String(format: "abley-welcome-%04d", index + 1)
        guard let url = bundle.url(forResource: name, withExtension: "png") else {
            throw AssetError.missing(name)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw AssetError.unreadable(name)
        }
        cachedIndex = index
        cachedImage = image
        return image
    }

    enum AssetError: Error { case missing(String), unreadable(String) }
}

@MainActor
final class AbleyWelcomePlayback: ObservableObject {
    @Published private(set) var image: CGImage?
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var usesStillGreeting = false

    /// Lifetime is the presenting view's task. Hiding, skipping or signing out
    /// cancels it and releases its decoder, with no timer left in the shell.
    func play(reduceMotion: Bool, frames: AbleyWelcomeFrames = AbleyWelcomeFrames(),
              completion: () -> Void) async {
        elapsed = 0
        usesStillGreeting = reduceMotion
        do {
            image = try await frames.image(at: 0)
            try Task.checkCancellation()
            if reduceMotion {
                try await Task.sleep(for: .seconds(AbleyWelcomeMotion.stillDuration))
            } else {
                let clock = ContinuousClock()
                let start = clock.now
                while !Task.isCancelled {
                    let components = start.duration(to: clock.now).components
                    let time = Double(components.seconds) + Double(components.attoseconds) / 1e18
                    guard time < AbleyWelcomeMotion.duration else { break }
                    let next = try await frames.image(at: AbleyWelcomeMotion.frameIndex(at: time))
                    try Task.checkCancellation()
                    image = next
                    elapsed = time
                    let nextTick = (floor(time * AbleyWelcomeMotion.framesPerSecond) + 1)
                        / AbleyWelcomeMotion.framesPerSecond
                    try await clock.sleep(until: start.advanced(by: .seconds(nextTick)))
                }
            }
            try Task.checkCancellation()
            completion()
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            Logger(subsystem: "com.memanager.app", category: "Welcome").error(
                "Welcome asset failed: \(String(describing: error), privacy: .public)")
            // A damaged or absent optional asset must never trap the account UI.
            elapsed = 0
            image = nil
            usesStillGreeting = true
            do {
                try await Task.sleep(for: .seconds(AbleyWelcomeMotion.stillDuration))
                try Task.checkCancellation()
                completion()
            } catch { return }
        }
    }
}
