import Foundation

/// Owns one Eagle 3 recognizer and keeps the profile alive for every process call.
final class EagleEngineImpl: EagleEngineProtocol {
    private let symbols: EagleV3Symbols
    private let accessKey: String
    private let modelPath: String
    private let profile: Data
    private var engine: OpaquePointer?
    let minimumAudioSamples: Int

    init(accessKey: String, modelPath: String, profile: Data, symbols: EagleV3Symbols) throws {
        guard !accessKey.isEmpty else { throw EagleError.invalidAccessKey }
        guard !modelPath.isEmpty else { throw EagleError.modelLoadFailed(modelPath) }
        guard !profile.isEmpty else { throw EagleError.invalidState }
        self.symbols = symbols
        self.accessKey = accessKey
        self.modelPath = modelPath
        self.profile = profile
        let created = try Self.create(accessKey: accessKey, modelPath: modelPath, symbols: symbols)
        engine = created.object
        minimumAudioSamples = created.minimumSamples
    }

    private static func create(accessKey: String, modelPath: String,
                               symbols: EagleV3Symbols) throws -> (object: OpaquePointer, minimumSamples: Int) {
        var object: OpaquePointer?
        let status = accessKey.withCString { key in
            modelPath.withCString { model in
                "cpu".withCString { device in symbols.engineInit(key, model, device, 0.3, &object) }
            }
        }
        if let error = EagleError.from(status: status) {
            if let object { symbols.engineDelete(object) }
            throw error
        }
        guard let object else { throw EagleError.invalidState }
        var samples: Int32 = 0
        let sizeStatus = symbols.engineMinimumSamples(object, &samples)
        if let error = EagleError.from(status: sizeStatus) {
            symbols.engineDelete(object)
            throw error
        }
        guard samples > 0, Int(samples) <= symbols.sampleRate * 30 else {
            symbols.engineDelete(object)
            throw EagleError.invalidState
        }
        return (object, Int(samples))
    }

    func process(pcm: [Int16]) throws -> Float {
        guard let engine else { throw EagleError.invalidState }
        guard pcm.count >= minimumAudioSamples else { throw EagleError.audioTooShort }
        guard pcm.count <= Int(Int32.max) else { throw EagleError.audioTooLong }
        var scores: UnsafeMutablePointer<Float>?
        defer { if let scores { symbols.scoresDelete(scores) } }
        let status = profile.withUnsafeBytes { bytes in
            var profilePointer = UnsafeMutableRawPointer(mutating: bytes.baseAddress)
            return withUnsafeMutablePointer(to: &profilePointer) { profiles in
                pcm.withUnsafeBufferPointer {
                    symbols.process(engine, $0.baseAddress, Int32($0.count), profiles, 1, &scores)
                }
            }
        }
        if let error = EagleError.from(status: status) { throw error }
        // A successful call with no scores means that the chunk had insufficient
        // voice. It must not become a zero-confidence speaker observation.
        guard let scores else { throw EagleError.audioNoVoice }
        let score = scores.pointee
        guard score.isFinite, (0...1).contains(score) else { throw EagleError.invalidState }
        return score
    }

    func reset() throws {
        guard let engine else { throw EagleError.invalidState }
        // Eagle 3 removed pv_eagle_reset. Recreate before releasing the old
        // instance so a failed reset leaves a valid owned object to clean up.
        let replacement = try Self.create(accessKey: accessKey, modelPath: modelPath, symbols: symbols)
        guard replacement.minimumSamples == minimumAudioSamples else {
            symbols.engineDelete(replacement.object)
            throw EagleError.invalidState
        }
        self.engine = replacement.object
        symbols.engineDelete(engine)
    }

    func destroy() {
        guard let engine else { return }
        symbols.engineDelete(engine)
        self.engine = nil
    }

    deinit { destroy() }
}
