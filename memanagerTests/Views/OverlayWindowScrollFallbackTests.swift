import XCTest
@testable import memanager

final class OverlayWindowScrollFallbackTests: XCTestCase {
    func testBestFallbackScrollViewIndexChoosesLargestVisibleArea() {
        let rootBounds = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let candidates = [
            CGRect(x: 0, y: 0, width: 280, height: 600),
            CGRect(x: 280, y: 0, width: 720, height: 600)
        ]

        let index = OverlayScrollFallback.bestFallbackScrollViewIndex(
            rootBounds: rootBounds,
            candidateBoundsInRoot: candidates
        )

        XCTAssertEqual(index, 1)
    }

    func testBestFallbackScrollViewIndexIgnoresNonVisibleCandidates() {
        let rootBounds = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let candidates = [
            CGRect(x: 1200, y: 0, width: 300, height: 300),
            CGRect(x: 100, y: 100, width: 200, height: 200)
        ]

        let index = OverlayScrollFallback.bestFallbackScrollViewIndex(
            rootBounds: rootBounds,
            candidateBoundsInRoot: candidates
        )

        XCTAssertEqual(index, 1)
    }

    func testBestFallbackScrollViewIndexBreaksAreaTieByWidthThenLeftMost() {
        let rootBounds = CGRect(x: 0, y: 0, width: 1200, height: 600)
        let equalAreaDifferentWidth = [
            CGRect(x: 100, y: 0, width: 200, height: 300),
            CGRect(x: 400, y: 0, width: 300, height: 200)
        ]

        let widthWinner = OverlayScrollFallback.bestFallbackScrollViewIndex(
            rootBounds: rootBounds,
            candidateBoundsInRoot: equalAreaDifferentWidth
        )
        XCTAssertEqual(widthWinner, 1)

        let equalAreaEqualWidth = [
            CGRect(x: 600, y: 0, width: 300, height: 200),
            CGRect(x: 50, y: 0, width: 300, height: 200)
        ]

        let leftMostWinner = OverlayScrollFallback.bestFallbackScrollViewIndex(
            rootBounds: rootBounds,
            candidateBoundsInRoot: equalAreaEqualWidth
        )
        XCTAssertEqual(leftMostWinner, 1)
    }

    func testBestFallbackScrollViewIndexBiasesTowardCenteredQuickAssistResponseRegion() {
        let rootBounds = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let candidates = [
            CGRect(x: 0, y: 0, width: 220, height: 600),
            CGRect(x: 220, y: 40, width: 560, height: 520)
        ]

        let index = OverlayScrollFallback.bestFallbackScrollViewIndex(
            rootBounds: rootBounds,
            candidateBoundsInRoot: candidates,
            preferredTarget: .quickAssist
        )

        XCTAssertEqual(index, 1)
    }
}

final class StreamingAutoScrollPolicyTests: XCTestCase {
    func testNearBottomIsTrueWhenContentFitsViewport() {
        let policy = StreamingAutoScrollPolicy(nearBottomThreshold: 56)

        XCTAssertTrue(
            policy.isNearBottom(
                offsetY: 0,
                visibleHeight: 700,
                contentHeight: 500
            )
        )
    }

    func testNearBottomIsTrueWhenWithinThreshold() {
        let policy = StreamingAutoScrollPolicy(nearBottomThreshold: 56)

        XCTAssertTrue(
            policy.isNearBottom(
                offsetY: 444,
                visibleHeight: 500,
                contentHeight: 980
            )
        )
    }

    func testNearBottomIsFalseWhenOutsideThreshold() {
        let policy = StreamingAutoScrollPolicy(nearBottomThreshold: 56)

        XCTAssertFalse(
            policy.isNearBottom(
                offsetY: 300,
                visibleHeight: 500,
                contentHeight: 980
            )
        )
    }
}

final class StreamingProgrammaticFollowPolicyTests: XCTestCase {
    func testReduceStreamingFollowStateRemainsFollowingWhenProgrammaticNearBottom() {
        let state = reduceStreamingFollowState(
            autoScrollMode: .smart,
            programmaticFollowPolicy: .allowUserDetachment,
            nearBottom: true,
            isProgrammaticScroll: true,
            isFollowingLatest: true
        )

        XCTAssertTrue(state.isFollowingLatest)
        XCTAssertTrue(state.isProgrammaticScroll)
    }

    func testReduceStreamingFollowStateAllowsDetachmentWhenProgrammaticAndAwayFromBottom() {
        let state = reduceStreamingFollowState(
            autoScrollMode: .smart,
            programmaticFollowPolicy: .allowUserDetachment,
            nearBottom: false,
            isProgrammaticScroll: true,
            isFollowingLatest: true
        )

        XCTAssertFalse(state.isFollowingLatest)
        XCTAssertFalse(state.isProgrammaticScroll)
    }

    func testReduceStreamingFollowStatePreservesLegacyLockBehavior() {
        let state = reduceStreamingFollowState(
            autoScrollMode: .smart,
            programmaticFollowPolicy: .lockDuringProgrammaticScroll,
            nearBottom: false,
            isProgrammaticScroll: true,
            isFollowingLatest: true
        )

        XCTAssertTrue(state.isFollowingLatest)
        XCTAssertTrue(state.isProgrammaticScroll)
    }
}
