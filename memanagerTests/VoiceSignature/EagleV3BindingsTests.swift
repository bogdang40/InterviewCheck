import XCTest
@testable import memanager

final class EagleV3BindingsTests: XCTestCase {
    private var stub: EagleV3TestSymbols!

    override func setUp() {
        super.setUp()
        EagleV3TestSymbols.lock.lock()
        stub = EagleV3TestSymbols()
        EagleV3TestSymbols.current = stub
    }

    override func tearDown() {
        XCTAssertEqual(stub.outstandingScores, 0)
        EagleV3TestSymbols.current = nil
        stub = nil
        EagleV3TestSymbols.lock.unlock()
        super.tearDown()
    }

    func testUnsupportedVersionFailsBeforeResolvingInstanceFunctions() {
        stub.setVersion("2.0.0")
        XCTAssertThrowsError(try stub.symbols()) { XCTAssertEqual($0 as? EagleError, .unsupportedSDK("2.0.0")) }
        XCTAssertEqual(stub.resolved, ["pv_eagle_version"])
        XCTAssertTrue(stub.events.isEmpty)
    }

    func testMissingRequiredScoreDeallocatorFailsClosed() {
        XCTAssertThrowsError(try stub.symbols(omitting: "pv_eagle_scores_delete")) {
            XCTAssertEqual($0 as? EagleError, .missingSDKSymbol("pv_eagle_scores_delete"))
        }
        XCTAssertTrue(stub.events.isEmpty)
    }

    func testBothAuditedNativePatchVersionsHaveTheSameContract() throws {
        XCTAssertEqual(try stub.symbols().version, "3.0.0")
        stub.setVersion("3.0.1")
        XCTAssertEqual(try stub.symbols().version, "3.0.1")
        stub.setVersion("3.1.0")
        XCTAssertThrowsError(try stub.symbols())
    }

    func testProfilerPassesV3ArgumentsAndExactFrames() throws {
        let profiler = try EagleProfilerImpl(accessKey: "test-key", modelPath: "test-model", symbols: stub.symbols())
        defer { profiler.destroy() }
        let arguments = try XCTUnwrap(stub.profilerArguments)
        XCTAssertEqual(arguments.0, "test-key")
        XCTAssertEqual(arguments.1, "test-model")
        XCTAssertEqual(arguments.2, "cpu")
        XCTAssertEqual(arguments.3, 1)
        XCTAssertEqual(arguments.4, 0.3)
        XCTAssertThrowsError(try profiler.enroll(pcm: [1, 2, 3]))
        XCTAssertThrowsError(try profiler.enroll(pcm: [1, 2, 3, 4, 5]))
        XCTAssertFalse(stub.events.contains("profiler.enroll"))
        let result = try profiler.enroll(pcm: [10, 20, 30, 40])
        XCTAssertEqual(stub.enrolledSamples, [10, 20, 30, 40])
        XCTAssertEqual(result.progress, 100)
        XCTAssertEqual(result.feedback, .progressOnly)
    }

    func testProfilerFlushesBeforeSizingAndExportingOwnedData() throws {
        let profiler = try EagleProfilerImpl(accessKey: "test", modelPath: "model", symbols: stub.symbols())
        XCTAssertEqual(try profiler.exportProfile(), Data([1, 2, 3, 4]))
        XCTAssertEqual(Array(stub.events.suffix(3)), ["profiler.flush", "profiler.size", "profiler.export"])
        profiler.destroy()
        profiler.destroy()
        XCTAssertEqual(stub.events.filter { $0 == "profiler.delete" }.count, 1)
        XCTAssertThrowsError(try profiler.exportProfile())
    }

    func testIncompleteFlushAndInvalidExportSizeNeverExport() throws {
        let profiler = try EagleProfilerImpl(accessKey: "test", modelPath: "model", symbols: stub.symbols())
        defer { profiler.destroy() }
        stub.progress = 99
        XCTAssertThrowsError(try profiler.exportProfile())
        stub.progress = 100
        stub.profileSize = -1
        XCTAssertThrowsError(try profiler.exportProfile())
        XCTAssertFalse(stub.events.contains("profiler.export"))
    }

    func testEnginePassesProfileAndSampleCountThenFreesScores() throws {
        let engine = try EagleEngineImpl(accessKey: "test-key", modelPath: "test-model", profile: Data([42, 43]), symbols: stub.symbols())
        defer { engine.destroy() }
        let arguments = try XCTUnwrap(stub.engineArguments)
        XCTAssertEqual(arguments.0, "test-key")
        XCTAssertEqual(arguments.1, "test-model")
        XCTAssertEqual(arguments.2, "cpu")
        XCTAssertEqual(arguments.3, 0.3)
        XCTAssertEqual(engine.minimumAudioSamples, 8)
        XCTAssertThrowsError(try engine.process(pcm: [1, 2]))
        XCTAssertFalse(stub.events.contains("engine.process"))
        let samples: [Int16] = [1, 2, 3, 4, 5, 6, 7, 8]
        XCTAssertEqual(try engine.process(pcm: samples), 0.75)
        XCTAssertEqual(stub.processedSamples, samples)
        XCTAssertEqual(stub.profileFirstByte, 42)
        XCTAssertEqual(stub.speakerCount, 1)
        XCTAssertEqual(stub.outstandingScores, 0)
        XCTAssertEqual(stub.events.last, "scores.delete")
    }

    func testScoresAreReleasedOnProcessingFailureAndInvalidOutput() throws {
        let engine = try makeEngine()
        defer { engine.destroy() }
        stub.processStatus = 7
        XCTAssertThrowsError(try engine.process(pcm: Array(repeating: 1, count: 8))) {
            XCTAssertEqual($0 as? EagleError, .runtimeError)
        }
        XCTAssertEqual(stub.outstandingScores, 0)
        stub.processStatus = 0
        stub.score = .nan
        XCTAssertThrowsError(try engine.process(pcm: Array(repeating: 1, count: 8)))
        XCTAssertEqual(stub.outstandingScores, 0)
    }

    func testNilScoresMeanNoVoiceRatherThanZeroConfidence() throws {
        let engine = try makeEngine()
        defer { engine.destroy() }
        stub.produceScores = false
        XCTAssertThrowsError(try engine.process(pcm: Array(repeating: 1, count: 8))) {
            XCTAssertEqual($0 as? EagleError, .audioNoVoice)
        }
        XCTAssertFalse(stub.events.contains("scores.delete"))
    }

    func testMinimumLengthFailureDestroysNewEngine() throws {
        stub.sizeStatus = 7
        XCTAssertThrowsError(try makeEngine())
        XCTAssertEqual(stub.events, ["engine.init", "engine.size", "engine.delete"])
    }

    func testResetRecreatesEngineWithoutCallingRemovedV2Symbol() throws {
        let engine = try makeEngine()
        defer { engine.destroy() }
        try engine.reset()
        XCTAssertEqual(stub.events, ["engine.init", "engine.size", "engine.init", "engine.size", "engine.delete"])
        XCTAssertFalse(stub.resolved.contains("pv_eagle_reset"))
    }

    func testHostedTestsNeverLoadDefaultSDK() {
        guard TestRuntime.isRunningUnitTests else { XCTFail("Expected isolated XCTest runtime"); return }
        XCTAssertFalse(EagleBindings.isSDKAvailable)
        XCTAssertThrowsError(try EagleBindings.createProfiler(accessKey: "test", modelPath: "model")) {
            XCTAssertEqual($0 as? EagleError, .sdkNotAvailable)
        }
    }

    private func makeEngine() throws -> EagleEngineImpl {
        try EagleEngineImpl(accessKey: "test", modelPath: "model", profile: Data([42]), symbols: stub.symbols())
    }
}
