import XCTest
import AVFoundation
@testable import memanager

/// Encodes the UnifiedAudioMixer observer leak as fixed: block based
/// observers must be removed by token, and re-attaching for a fresh engine
/// must not leave the previous observer alive.
final class EngineConfigurationObserverTests: XCTestCase {
    func testHandlerFiresForAttachedEngineOnly() {
        let center = NotificationCenter()
        let observer = EngineConfigurationObserver(center: center)
        let engineA = AVAudioEngine()
        let engineB = AVAudioEngine()
        var fireCount = 0

        observer.attach(to: engineA) { fireCount += 1 }
        center.post(name: .AVAudioEngineConfigurationChange, object: engineA)
        center.post(name: .AVAudioEngineConfigurationChange, object: engineB)

        XCTAssertEqual(fireCount, 1)
        observer.detach()
    }

    func testReattachRemovesThePreviousObserver() {
        let center = NotificationCenter()
        let observer = EngineConfigurationObserver(center: center)
        let oldEngine = AVAudioEngine()
        let newEngine = AVAudioEngine()
        var oldFires = 0
        var newFires = 0

        observer.attach(to: oldEngine) { oldFires += 1 }
        observer.attach(to: newEngine) { newFires += 1 }

        center.post(name: .AVAudioEngineConfigurationChange, object: oldEngine)
        center.post(name: .AVAudioEngineConfigurationChange, object: newEngine)

        XCTAssertEqual(oldFires, 0, "The old engine's observer must be gone after re-attach")
        XCTAssertEqual(newFires, 1)
        observer.detach()
    }

    func testRepeatedStartStopCyclesNeverAccumulateObservers() {
        let center = NotificationCenter()
        let observer = EngineConfigurationObserver(center: center)
        let engine = AVAudioEngine()
        var fireCount = 0

        for _ in 0..<5 {
            observer.attach(to: engine) { fireCount += 1 }
        }
        center.post(name: .AVAudioEngineConfigurationChange, object: engine)
        XCTAssertEqual(fireCount, 1, "Five attach cycles must leave exactly one live observer")

        observer.detach()
        center.post(name: .AVAudioEngineConfigurationChange, object: engine)
        XCTAssertEqual(fireCount, 1, "No observer may survive detach")
    }
}
