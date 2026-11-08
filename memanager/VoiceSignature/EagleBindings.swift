import Foundation

/// Factory boundary for the bundled Eagle 3 SDK. Tests use injected symbol tables.
final class EagleBindings: EagleBindingsProtocol {
    // Rendering and synthetic audio conversion remain usable without loading an SDK.
    static var sampleRate: Int { EagleLibrary.shared.symbols?.sampleRate ?? 16_000 }
    static var frameLength: Int { EagleLibrary.shared.symbols?.profilerFrameLength ?? 512 }
    static var minEnrollSamples: Int { frameLength }
    static var isSDKAvailable: Bool { EagleLibrary.shared.symbols != nil }
    static var version: String? { EagleLibrary.shared.symbols?.version }

    static func createProfiler(accessKey: String, modelPath: String) throws -> EagleProfilerProtocol {
        try EagleProfilerImpl(accessKey: accessKey, modelPath: modelPath,
                              symbols: EagleLibrary.shared.requireSymbols())
    }

    static func createEngine(accessKey: String, modelPath: String, profile: Data) throws -> EagleEngineProtocol {
        try EagleEngineImpl(accessKey: accessKey, modelPath: modelPath, profile: profile,
                            symbols: EagleLibrary.shared.requireSymbols())
    }
}
