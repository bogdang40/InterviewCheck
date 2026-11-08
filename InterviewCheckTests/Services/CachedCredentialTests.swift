import XCTest
@testable import InterviewCheck

@MainActor
final class CachedCredentialTests: XCTestCase {
    func testBlockedReadDoesNotBlockMainQueueAndCannotOverwriteNewEdit() async {
        let started = expectation(description: "read started")
        let mainResponsive = expectation(description: "main queue responds")
        let saved = expectation(description: "new value saved")
        let release = DispatchSemaphore(value: 0)
        let cache = CachedCredential<String>(read: {
            XCTAssertFalse(Thread.isMainThread)
            started.fulfill()
            _ = release.wait(timeout: .now() + 5)
            return "old synthetic key"
        }, write: { value in
            XCTAssertFalse(Thread.isMainThread)
            return value
        })
        cache.onChange = {
            if cache.status == .configured, cache.value == "new synthetic key" { cache.onChange = nil; saved.fulfill() }
        }
        cache.reload()
        await fulfillment(of: [started], timeout: 2)
        DispatchQueue.main.async { mainResponsive.fulfill() }
        await fulfillment(of: [mainResponsive], timeout: 2)
        XCTAssertEqual(cache.status, .loading)
        cache.save("new synthetic key")
        release.signal()
        await fulfillment(of: [saved], timeout: 2)
        XCTAssertEqual(cache.value, "new synthetic key")
    }

    func testQueuedOlderWritesAreSkippedAndRefreshCannotCancelSave() async {
        let saved = expectation(description: "latest save")
        let queue = DispatchQueue(label: "test.credentials.suspended")
        queue.suspend()
        var writes: [String] = []
        let cache = CachedCredential<String>(queue: queue, read: { "old" }, write: { value in
            writes.append(value ?? "deleted")
            return value
        })
        cache.onChange = { if cache.status == .configured { cache.onChange = nil; saved.fulfill() } }
        cache.save("first")
        cache.save("latest")
        cache.reload()
        XCTAssertEqual(cache.status, .saving)
        queue.resume()
        await fulfillment(of: [saved], timeout: 2)
        XCTAssertEqual(writes, ["latest"])
        XCTAssertEqual(cache.value, "latest")
    }

    func testDeniedReadIsUnavailableAndRetryCanRecover() async {
        let failed = expectation(description: "read unavailable")
        let recovered = expectation(description: "read recovered")
        var denied = true
        let cache = CachedCredential<String>(read: {
            if denied { throw CredentialStorageError.invalidEncoding }
            return "synthetic"
        }, write: { $0 })
        cache.onChange = {
            if case .unavailable = cache.status { cache.onChange = nil; failed.fulfill() }
        }
        cache.reload()
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertNil(cache.value)
        denied = false
        cache.onChange = { if cache.status == .configured { cache.onChange = nil; recovered.fulfill() } }
        cache.reload()
        await fulfillment(of: [recovered], timeout: 2)
        XCTAssertEqual(cache.value, "synthetic")
    }

    func testMissingReadAndFailedSavePreserveDistinctStates() async {
        let missing = expectation(description: "missing key")
        let failed = expectation(description: "save failed")
        let cache = CachedCredential<String>(read: { nil }, write: { _ in throw CredentialStorageError.saveFailed })
        cache.onChange = { if cache.status == .missing { cache.onChange = nil; missing.fulfill() } }
        cache.reload()
        await fulfillment(of: [missing], timeout: 2)
        cache.recordPersisted("existing synthetic key")
        cache.onChange = { if case .saveFailed = cache.status { cache.onChange = nil; failed.fulfill() } }
        cache.save("replacement")
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertEqual(cache.value, "existing synthetic key")
    }
}
