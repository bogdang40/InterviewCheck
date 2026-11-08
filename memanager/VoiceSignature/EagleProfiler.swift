import Foundation

/// Owns one Eagle 3 profiler. The service serializes calls and destruction.
final class EagleProfilerImpl: EagleProfilerProtocol {
    private let symbols: EagleV3Symbols
    private var profiler: OpaquePointer?

    init(accessKey: String, modelPath: String, symbols: EagleV3Symbols) throws {
        self.symbols = symbols
        guard !accessKey.isEmpty else { throw EagleError.invalidAccessKey }
        guard !modelPath.isEmpty else { throw EagleError.modelLoadFailed(modelPath) }
        var object: OpaquePointer?
        let status = accessKey.withCString { key in
            modelPath.withCString { model in
                "cpu".withCString { device in
                    symbols.profilerInit(key, model, device, 1, 0.3, &object)
                }
            }
        }
        if let error = EagleError.from(status: status) {
            if let object { symbols.profilerDelete(object) }
            throw error
        }
        guard let object else { throw EagleError.invalidState }
        profiler = object
    }

    func enroll(pcm: [Int16]) throws -> (progress: Float, feedback: EagleEnrollmentFeedback) {
        guard let profiler else { throw EagleError.invalidState }
        guard pcm.count >= symbols.profilerFrameLength else { throw EagleError.audioTooShort }
        guard pcm.count == symbols.profilerFrameLength else { throw EagleError.audioTooLong }
        var percentage: Float = 0
        let status = pcm.withUnsafeBufferPointer {
            symbols.profilerEnroll(profiler, $0.baseAddress, &percentage)
        }
        if let error = EagleError.from(status: status) { throw error }
        guard percentage.isFinite, (0...100).contains(percentage) else { throw EagleError.invalidState }
        // Eagle 3 returns progress only, not the old audio-quality/speaker codes.
        return (percentage, .progressOnly)
    }

    func exportProfile() throws -> Data {
        guard let profiler else { throw EagleError.invalidState }
        var percentage: Float = 0
        let flushStatus = symbols.profilerFlush(profiler, &percentage)
        if let error = EagleError.from(status: flushStatus) { throw error }
        guard percentage.isFinite, percentage == 100 else { throw EagleError.invalidState }

        var size: Int32 = 0
        let sizeStatus = symbols.profilerExportSize(profiler, &size)
        if let error = EagleError.from(status: sizeStatus) { throw error }
        guard size > 0, size <= 16 * 1024 * 1024 else { throw EagleError.exportFailed }
        var profile = Data(count: Int(size))
        let status = profile.withUnsafeMutableBytes { symbols.profilerExport(profiler, $0.baseAddress) }
        if let error = EagleError.from(status: status) { throw error }
        return profile
    }

    func reset() throws {
        guard let profiler else { throw EagleError.invalidState }
        if let error = EagleError.from(status: symbols.profilerReset(profiler)) { throw error }
    }

    func destroy() {
        guard let profiler else { return }
        symbols.profilerDelete(profiler)
        self.profiler = nil
    }

    deinit { destroy() }
}
