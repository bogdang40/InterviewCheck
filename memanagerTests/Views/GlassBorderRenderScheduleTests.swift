import XCTest
@testable import memanager

final class GlassBorderRenderScheduleTests: XCTestCase {
    func testStaticUpdateDoesNotStartTheAnimationDisplayLink() {
        var schedule = GlassBorderRenderSchedule()
        XCTAssertFalse(schedule.shouldRunDisplayLink(isVisible: true, isAnimating: false))
        schedule.requestUrgentFrame()
        XCTAssertFalse(schedule.shouldRunDisplayLink(isVisible: true, isAnimating: false))
        XCTAssertFalse(schedule.shouldRunDisplayLink(isVisible: false, isAnimating: false))
        XCTAssertTrue(schedule.beginFrame(isVisible: true))
        XCTAssertFalse(schedule.shouldRunDisplayLink(isVisible: true, isAnimating: false))
        XCTAssertFalse(schedule.finishFrame(isVisible: true))
        XCTAssertFalse(schedule.shouldRunDisplayLink(isVisible: true, isAnimating: false))
        XCTAssertTrue(schedule.shouldRunDisplayLink(isVisible: true, isAnimating: true))
    }

    func testStaticUpdateWhileBusyKeepsItsUrgentDrawPending() {
        var schedule = GlassBorderRenderSchedule()
        schedule.requestUrgentFrame()
        XCTAssertTrue(schedule.beginFrame(isVisible: true))
        schedule.requestUrgentFrame()
        XCTAssertFalse(schedule.beginFrame(isVisible: true))
        XCTAssertTrue(schedule.finishFrame(isVisible: true))
        XCTAssertTrue(schedule.hasUrgentFramePending, "Completion must request the latest static draw")
        XCTAssertFalse(schedule.shouldRunDisplayLink(isVisible: true, isAnimating: false))
        XCTAssertTrue(schedule.beginFrame(isVisible: true))
        XCTAssertFalse(schedule.shouldRunDisplayLink(isVisible: true, isAnimating: false))
    }

    func testInvisibleOrStaticOpticsDoNotRequestAnimation() {
        XCTAssertTrue(GlassBorderMotionPolicy.hasAnimatedContribution(GlassBorderOptics()))
        for optics in [GlassBorderOptics(reflectionStrength: 0), GlassBorderOptics(thickness: 0),
                       GlassBorderOptics(ior: 1, dispersion: 0),
                       GlassBorderOptics(gooey: 0, lightMotion: 0, liquid: 0)] {
            XCTAssertFalse(GlassBorderMotionPolicy.hasAnimatedContribution(optics))
        }
    }

    func testMotionRunsOnlyWhileVisibleAndAllowed() {
        XCTAssertEqual(GlassBorderMotionPolicy.framesPerSecond(isVisible: true, reduceMotion: false), 30)
        XCTAssertEqual(GlassBorderMotionPolicy.framesPerSecond(isVisible: false, reduceMotion: false), 0)
        XCTAssertEqual(GlassBorderMotionPolicy.framesPerSecond(isVisible: true, reduceMotion: true), 0)
        XCTAssertEqual(GlassBorderMotionPolicy.framesPerSecond(isVisible: false, reduceMotion: true), 0)
    }

    func testResizeBurstQueuesOnlyOneLatestFrame() {
        var schedule = GlassBorderRenderSchedule()
        XCTAssertTrue(schedule.beginFrame(isVisible: true))
        for _ in 0..<100 { XCTAssertFalse(schedule.beginFrame(isVisible: true)) }
        XCTAssertTrue(schedule.isFrameInFlight)
        XCTAssertTrue(schedule.finishFrame(isVisible: true))
        XCTAssertTrue(schedule.beginFrame(isVisible: true))
        XCTAssertFalse(schedule.finishFrame(isVisible: true), "Completion must not create an idle redraw loop")
        XCTAssertFalse(schedule.isFrameInFlight)
    }

    func testHidingDropsPendingWorkAndShowingCanRenderAgain() {
        var schedule = GlassBorderRenderSchedule()
        XCTAssertFalse(schedule.beginFrame(isVisible: false))
        XCTAssertFalse(schedule.isFrameInFlight)
        XCTAssertTrue(schedule.beginFrame(isVisible: true))
        XCTAssertFalse(schedule.beginFrame(isVisible: true))
        XCTAssertFalse(schedule.finishFrame(isVisible: false))
        XCTAssertFalse(schedule.isFrameInFlight)
        XCTAssertTrue(schedule.beginFrame(isVisible: true))
        XCTAssertFalse(schedule.finishFrame(isVisible: true))
    }

    func testUnavailableDrawableReleasesTheSlotWithoutRetrying() {
        var schedule = GlassBorderRenderSchedule()
        XCTAssertTrue(schedule.beginFrame(isVisible: true))
        XCTAssertFalse(schedule.finishFrame(isVisible: false))
        XCTAssertFalse(schedule.finishFrame(isVisible: true))
        XCTAssertTrue(schedule.beginFrame(isVisible: true), "A later real invalidation can recover")
    }

    func testUrgentUpdatesDuringAFrameSurviveUntilTheLatestFrameIsAdmitted() {
        var schedule = GlassBorderRenderSchedule()
        XCTAssertTrue(schedule.beginFrame(isVisible: true))
        for _ in 0..<100 { schedule.requestUrgentFrame() }
        XCTAssertFalse(schedule.beginFrame(isVisible: true))
        XCTAssertTrue(schedule.finishFrame(isVisible: true))
        XCTAssertTrue(schedule.hasUrgentFramePending,
                      "A busy renderer must service the latest configuration before another animation tick")
        XCTAssertTrue(schedule.beginFrame(isVisible: true))
        XCTAssertFalse(schedule.hasUrgentFramePending)
        XCTAssertFalse(schedule.finishFrame(isVisible: true), "Completion cannot create another frame")
    }

    func testDisplayTickCanSatisfyAnUrgentRequestWithoutAnExtraQueuedFrame() {
        var schedule = GlassBorderRenderSchedule()
        schedule.requestUrgentFrame()
        XCTAssertTrue(schedule.beginFrame(isVisible: true))
        XCTAssertFalse(schedule.hasUrgentFramePending,
                       "The later coalesced callback must skip a request already served by a display tick")
        XCTAssertFalse(schedule.finishFrame(isVisible: true))
    }

    func testOrdinaryBusyDisplayTicksDoNotBecomeUrgentCompletionLoops() {
        var schedule = GlassBorderRenderSchedule()
        XCTAssertTrue(schedule.beginFrame(isVisible: true))
        XCTAssertFalse(schedule.beginFrame(isVisible: true))
        XCTAssertTrue(schedule.finishFrame(isVisible: true))
        XCTAssertFalse(schedule.hasUrgentFramePending)
        XCTAssertFalse(schedule.finishFrame(isVisible: true))
    }

    func testHidingCancelsPendingUrgentWork() {
        var schedule = GlassBorderRenderSchedule()
        schedule.requestUrgentFrame()
        schedule.cancelUrgentFrame()
        XCTAssertFalse(schedule.hasUrgentFramePending)
        XCTAssertTrue(schedule.beginFrame(isVisible: true))
        schedule.requestUrgentFrame()
        XCTAssertFalse(schedule.finishFrame(isVisible: false))
        XCTAssertFalse(schedule.hasUrgentFramePending)
        XCTAssertTrue(schedule.beginFrame(isVisible: true))
        XCTAssertFalse(schedule.finishFrame(isVisible: true))
    }
}
