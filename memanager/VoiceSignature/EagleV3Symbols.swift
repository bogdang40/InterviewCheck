import Foundation

/// Exact C signatures from Picovoice's v3.0 header. Resolution validates the
/// complete ABI before any profiler or recognizer can be constructed.
struct EagleV3Symbols {
    typealias Version = @convention(c) () -> UnsafePointer<CChar>?
    typealias Size = @convention(c) () -> Int32
    typealias ProfilerInit = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32, Float, UnsafeMutablePointer<OpaquePointer?>?) -> Int32
    typealias Delete = @convention(c) (OpaquePointer?) -> Void
    typealias ProfilerEnroll = @convention(c) (OpaquePointer?, UnsafePointer<Int16>?, UnsafeMutablePointer<Float>?) -> Int32
    typealias ProfilerFlush = @convention(c) (OpaquePointer?, UnsafeMutablePointer<Float>?) -> Int32
    typealias ObjectSize = @convention(c) (OpaquePointer?, UnsafeMutablePointer<Int32>?) -> Int32
    typealias ProfilerExport = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Int32
    typealias ProfilerReset = @convention(c) (OpaquePointer?) -> Int32
    typealias EngineInit = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, Float, UnsafeMutablePointer<OpaquePointer?>?) -> Int32
    typealias Process = @convention(c) (OpaquePointer?, UnsafePointer<Int16>?, Int32, UnsafeMutablePointer<UnsafeMutableRawPointer?>?, Int32, UnsafeMutablePointer<UnsafeMutablePointer<Float>?>?) -> Int32
    typealias ScoresDelete = @convention(c) (UnsafeMutablePointer<Float>?) -> Void

    // Package 3.0.1 ships a native library reporting 3.0.0. Both audited
    // patch versions use these signatures; future versions must be reviewed.
    static let supportedVersions: Set<String> = ["3.0.0", "3.0.1"]
    let version: String
    let sampleRate: Int
    let profilerFrameLength: Int
    let profilerInit: ProfilerInit
    let profilerDelete: Delete
    let profilerEnroll: ProfilerEnroll
    let profilerFlush: ProfilerFlush
    let profilerExportSize: ObjectSize
    let profilerExport: ProfilerExport
    let profilerReset: ProfilerReset
    let engineInit: EngineInit
    let engineDelete: Delete
    let engineMinimumSamples: ObjectSize
    let process: Process
    let scoresDelete: ScoresDelete

    init(resolve: (String) -> UnsafeMutableRawPointer?) throws {
        func load<T>(_ name: String, as type: T.Type) throws -> T {
            guard let address = resolve(name) else { throw EagleError.missingSDKSymbol(name) }
            return unsafeBitCast(address, to: type)
        }
        let getVersion = try load("pv_eagle_version", as: Version.self)
        guard let versionPointer = getVersion(), let version = String(validatingUTF8: versionPointer) else {
            throw EagleError.unsupportedSDK("unavailable")
        }
        guard Self.supportedVersions.contains(version) else { throw EagleError.unsupportedSDK(version) }
        self.version = version
        let getSampleRate = try load("pv_sample_rate", as: Size.self)
        let getFrameLength = try load("pv_eagle_profiler_frame_length", as: Size.self)
        profilerInit = try load("pv_eagle_profiler_init", as: ProfilerInit.self)
        profilerDelete = try load("pv_eagle_profiler_delete", as: Delete.self)
        profilerEnroll = try load("pv_eagle_profiler_enroll", as: ProfilerEnroll.self)
        profilerFlush = try load("pv_eagle_profiler_flush", as: ProfilerFlush.self)
        profilerExportSize = try load("pv_eagle_profiler_export_size", as: ObjectSize.self)
        profilerExport = try load("pv_eagle_profiler_export", as: ProfilerExport.self)
        profilerReset = try load("pv_eagle_profiler_reset", as: ProfilerReset.self)
        engineInit = try load("pv_eagle_init", as: EngineInit.self)
        engineDelete = try load("pv_eagle_delete", as: Delete.self)
        engineMinimumSamples = try load("pv_eagle_process_min_audio_length_samples", as: ObjectSize.self)
        process = try load("pv_eagle_process", as: Process.self)
        scoresDelete = try load("pv_eagle_scores_delete", as: ScoresDelete.self)
        sampleRate = Int(getSampleRate())
        profilerFrameLength = Int(getFrameLength())
        guard (1...192_000).contains(sampleRate),
              (1...(sampleRate * 30)).contains(profilerFrameLength) else { throw EagleError.invalidState }
    }
}
