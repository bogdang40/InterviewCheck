import Combine
import XCTest
@testable import memanager

@MainActor
final class AppearanceUpdateDeliveryTests: XCTestCase {
    func testMainThreadBurstDefersAndAppliesOnlyTheLatestValue() async {
        let delivery = AppearanceUpdateDelivery()
        var values: [Int] = []
        delivery.submit { values.append(1) }
        delivery.submit { values.append(2) }
        XCTAssertTrue(values.isEmpty, "A settings setter must finish before native layout starts")
        await drainMainQueue()
        withExtendedLifetime(delivery) { XCTAssertEqual(values, [2]) }
    }

    func testPublishedDeliveryObservesTheCommittedModelInsteadOfWillSetState() async {
        final class Model: ObservableObject { @Published var value = 0 }
        let model = Model()
        let delivery = AppearanceUpdateDelivery()
        var storedValues: [Int] = []
        let subscription = model.$value.dropFirst().sink { incoming in
            delivery.submit {
                XCTAssertEqual(model.value, incoming)
                storedValues.append(model.value)
            }
        }
        model.value = 1
        model.value = 2
        XCTAssertTrue(storedValues.isEmpty)
        await drainMainQueue()
        withExtendedLifetime((delivery, subscription)) { XCTAssertEqual(storedValues, [2]) }
    }

    func testNewMainThreadUpdateSupersedesPendingBackgroundUpdate() async {
        let delivery = AppearanceUpdateDelivery()
        var values: [Int] = []
        let submitted = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            delivery.submit { values.append(1) }
            submitted.signal()
        }
        XCTAssertEqual(submitted.wait(timeout: .now() + 2), .success)
        delivery.submit { values.append(2) }
        XCTAssertTrue(values.isEmpty)
        await drainMainQueue()
        withExtendedLifetime(delivery) { XCTAssertEqual(values, [2]) }
    }

    func testPendingBackgroundBurstAppliesOnlyTheLatestValueOnMain() async {
        let delivery = AppearanceUpdateDelivery()
        var values: [Int] = []
        let submitted = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            for value in 1...50 {
                delivery.submit {
                    XCTAssertTrue(Thread.isMainThread)
                    values.append(value)
                }
            }
            submitted.signal()
        }
        XCTAssertEqual(submitted.wait(timeout: .now() + 2), .success)
        await drainMainQueue()
        withExtendedLifetime(delivery) { XCTAssertEqual(values, [50]) }
    }

    private func drainMainQueue() async {
        let drained = expectation(description: "Queued appearance updates drained")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
    }
}
