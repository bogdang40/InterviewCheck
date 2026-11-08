import Foundation
import Metal
import OSLog

/// Immutable Metal objects shared by every border. Preparation does no drawing.
final class GlassBorderResources {
    let renderer: GlassOpticsRenderer
    let commandQueue: MTLCommandQueue
    var device: MTLDevice { renderer.device }

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw GlassRenderError.encoderUnavailable
        }
        commandQueue = queue
        commandQueue.label = "Appearance border"
        renderer = try GlassOpticsRenderer(device: device)
    }
}

/// The UI never waits for pipeline compilation. Concurrent requests share one
/// preparation, and a warm request is delivered in the same main-thread turn.
@MainActor
final class GlassBorderResourcePool {
    static let shared = GlassBorderResourcePool()
    private static let logger = Logger(subsystem: "com.memanager.app", category: "GlassBorder")
    typealias Preparation = Result<GlassBorderResources, Error>
    private var result: Preparation?
    private var waiters: [(Preparation) -> Void] = []
    private let makeResources: () throws -> GlassBorderResources

    init(makeResources: @escaping () throws -> GlassBorderResources = { try GlassBorderResources() }) {
        self.makeResources = makeResources
    }

    func prepare(_ completion: @escaping (Preparation) -> Void) {
        if let result {
            completion(result)
            return
        }
        waiters.append(completion)
        guard waiters.count == 1 else { return }
        let makeResources = makeResources
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try makeResources() }
            DispatchQueue.main.async {
                guard let self else { return }
                if case .failure(let error) = result {
                    Self.logger.error("Glass preparation failed: \(error.localizedDescription, privacy: .public)")
                }
                self.result = result
                let callbacks = self.waiters
                self.waiters.removeAll()
                callbacks.forEach { $0(result) }
            }
        }
    }
}
