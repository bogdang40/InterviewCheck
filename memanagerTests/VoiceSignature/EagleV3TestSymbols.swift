import Foundation
@testable import memanager

/// C-callable fakes exercise the exact function pointer signatures without
/// loading a dylib. The test class holds the lock while current is installed.
final class EagleV3TestSymbols {
    static let lock = NSLock()
    static var current: EagleV3TestSymbols!
    private var versionStorage = strdup("3.0.0")!
    var events: [String] = []
    var resolved: [String] = []
    var profilerArguments: (String, String, String, Int32, Float)?
    var engineArguments: (String, String, String, Float)?
    var enrolledSamples: [Int16] = []
    var processedSamples: [Int16] = []
    var profileFirstByte: UInt8?
    var speakerCount: Int32 = 0
    var progress: Float = 100
    var frameLength: Int32 = 4
    var minimumSamples: Int32 = 8
    var sizeStatus: Int32 = 0
    var processStatus: Int32 = 0
    var produceScores = true
    var score: Float = 0.75
    var outstandingScores = 0
    var profileSize: Int32 = 4

    func setVersion(_ value: String) {
        free(versionStorage)
        versionStorage = strdup(value)!
    }

    func symbols(omitting missing: String? = nil) throws -> EagleV3Symbols {
        let table = addresses()
        return try EagleV3Symbols { name in
            resolved.append(name)
            return name == missing ? nil : table[name]
        }
    }

    private func addresses() -> [String: UnsafeMutableRawPointer] {
        let version: EagleV3Symbols.Version = { UnsafePointer(EagleV3TestSymbols.current.versionStorage) }
        let sampleRate: EagleV3Symbols.Size = { 16_000 }
        let frameLength: EagleV3Symbols.Size = { EagleV3TestSymbols.current.frameLength }
        let profilerInit: EagleV3Symbols.ProfilerInit = { key, model, device, chunks, threshold, output in
            EagleV3TestSymbols.current.events.append("profiler.init")
            EagleV3TestSymbols.current.profilerArguments = (String(cString: key!), String(cString: model!), String(cString: device!), chunks, threshold)
            output?.pointee = OpaquePointer(bitPattern: 0x101)
            return 0
        }
        let profilerDelete: EagleV3Symbols.Delete = { _ in EagleV3TestSymbols.current.events.append("profiler.delete") }
        let enroll: EagleV3Symbols.ProfilerEnroll = { _, pcm, percentage in
            EagleV3TestSymbols.current.events.append("profiler.enroll")
            EagleV3TestSymbols.current.enrolledSamples = Array(UnsafeBufferPointer(start: pcm, count: Int(EagleV3TestSymbols.current.frameLength)))
            percentage?.pointee = EagleV3TestSymbols.current.progress
            return 0
        }
        let flush: EagleV3Symbols.ProfilerFlush = { _, percentage in
            EagleV3TestSymbols.current.events.append("profiler.flush")
            percentage?.pointee = EagleV3TestSymbols.current.progress
            return 0
        }
        let exportSize: EagleV3Symbols.ObjectSize = { _, output in
            EagleV3TestSymbols.current.events.append("profiler.size")
            output?.pointee = EagleV3TestSymbols.current.profileSize
            return 0
        }
        let export: EagleV3Symbols.ProfilerExport = { _, output in
            EagleV3TestSymbols.current.events.append("profiler.export")
            for index in 0..<Int(EagleV3TestSymbols.current.profileSize) { output?.storeBytes(of: UInt8(index + 1), toByteOffset: index, as: UInt8.self) }
            return 0
        }
        let reset: EagleV3Symbols.ProfilerReset = { _ in EagleV3TestSymbols.current.events.append("profiler.reset"); return 0 }
        let engineInit: EagleV3Symbols.EngineInit = { key, model, device, threshold, output in
            EagleV3TestSymbols.current.events.append("engine.init")
            EagleV3TestSymbols.current.engineArguments = (String(cString: key!), String(cString: model!), String(cString: device!), threshold)
            output?.pointee = OpaquePointer(bitPattern: 0x202)
            return 0
        }
        let engineDelete: EagleV3Symbols.Delete = { _ in EagleV3TestSymbols.current.events.append("engine.delete") }
        let minimumSamples: EagleV3Symbols.ObjectSize = { _, output in
            EagleV3TestSymbols.current.events.append("engine.size")
            output?.pointee = EagleV3TestSymbols.current.minimumSamples
            return EagleV3TestSymbols.current.sizeStatus
        }
        let process: EagleV3Symbols.Process = { _, pcm, count, profiles, speakers, output in
            EagleV3TestSymbols.current.events.append("engine.process")
            EagleV3TestSymbols.current.processedSamples = Array(UnsafeBufferPointer(start: pcm, count: Int(count)))
            EagleV3TestSymbols.current.profileFirstByte = profiles?.pointee?.load(as: UInt8.self)
            EagleV3TestSymbols.current.speakerCount = speakers
            if EagleV3TestSymbols.current.produceScores {
                let scores = UnsafeMutablePointer<Float>.allocate(capacity: 1)
                scores.initialize(to: EagleV3TestSymbols.current.score)
                EagleV3TestSymbols.current.outstandingScores += 1
                output?.pointee = scores
            }
            return EagleV3TestSymbols.current.processStatus
        }
        let scoresDelete: EagleV3Symbols.ScoresDelete = { scores in
            EagleV3TestSymbols.current.events.append("scores.delete")
            scores?.deinitialize(count: 1)
            scores?.deallocate()
            EagleV3TestSymbols.current.outstandingScores -= 1
        }
        func address<T>(_ value: T) -> UnsafeMutableRawPointer { unsafeBitCast(value, to: UnsafeMutableRawPointer.self) }
        return [
            "pv_eagle_version": address(version), "pv_sample_rate": address(sampleRate),
            "pv_eagle_profiler_frame_length": address(frameLength),
            "pv_eagle_profiler_init": address(profilerInit), "pv_eagle_profiler_delete": address(profilerDelete),
            "pv_eagle_profiler_enroll": address(enroll), "pv_eagle_profiler_flush": address(flush),
            "pv_eagle_profiler_export_size": address(exportSize), "pv_eagle_profiler_export": address(export),
            "pv_eagle_profiler_reset": address(reset), "pv_eagle_init": address(engineInit),
            "pv_eagle_delete": address(engineDelete), "pv_eagle_process_min_audio_length_samples": address(minimumSamples),
            "pv_eagle_process": address(process), "pv_eagle_scores_delete": address(scoresDelete)
        ]
    }

    deinit { free(versionStorage) }
}
