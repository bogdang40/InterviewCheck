import XCTest
@testable import memanager

/// The pure resolvers behind the design renderers: section catalog, per
/// section color, step progress, shortcut pairing, banners, and validators.
final class DesignRendererResolverTests: XCTestCase {
    func testAvailableSectionsFollowBlueprintOrder() {
        let sections = DesignSectionCatalog.availableSections(in: DesignRenderFixtures.content)

        XCTAssertEqual(sections.map(\.id), SystemDesignBlueprint.sections.map(\.id))
        XCTAssertEqual(sections.first?.title, "Requirements")
        XCTAssertEqual(sections.last?.symbol, "flag.checkered")
        XCTAssertEqual(sections.first { $0.id == "architecture" }?.expectedStepCount, 4)
    }

    func testSectionColorsAreStableByBlueprintPosition() {
        XCTAssertEqual(DesignSectionToneResolver.speakerIndex(for: "requirements"), 0)
        XCTAssertEqual(DesignSectionToneResolver.speakerIndex(for: "wrapUp"), 9)
        XCTAssertEqual(DesignSectionToneResolver.speakerIndex(for: "unknown"), 0)
    }

    func testStepProgressClampsAndLabels() {
        let progress = DesignStepProgress(stepCount: 3, expectedStepCount: 4, currentIndex: 9)

        XCTAssertEqual(progress.currentIndex, 2)
        XCTAssertEqual(progress.positionLabel, "step 3 of 3")
        XCTAssertEqual(progress.budgetLabel, "3 of 4 steps")
        XCTAssertEqual(progress.budgetTone, .warning)
        XCTAssertTrue(progress.hasPrevious)
        XCTAssertFalse(progress.hasNext)
    }

    func testStepProgressCompletionFollowsReportOverBudget() {
        let budgetOnly = DesignStepProgress(stepCount: 2, expectedStepCount: 2, currentIndex: 0)
        XCTAssertEqual(budgetOnly.budgetTone, .success)

        let reportSaysIncoherent = DesignStepProgress(stepCount: 2, expectedStepCount: 2, currentIndex: 0, isComplete: false)
        XCTAssertEqual(reportSaysIncoherent.budgetTone, .warning)

        let empty = DesignStepProgress(stepCount: 0, expectedStepCount: nil, currentIndex: 3)
        XCTAssertEqual(empty.positionLabel, "no steps")
        XCTAssertFalse(empty.hasSteps)
        XCTAssertEqual(DesignStepProgress(stepCount: 1, expectedStepCount: nil, currentIndex: 0).budgetLabel, "1 step")
    }

    func testShortcutPairingMergesTheTrailingKey() {
        XCTAssertEqual(DesignShortcutHints.pair("Cmd+Option+Left", "Cmd+Option+Right"), "Cmd+Option+Left/Right")
        XCTAssertEqual(DesignShortcutHints.pair("Cmd+Up", "Cmd+Down"), "Cmd+Up/Down")
        XCTAssertEqual(DesignShortcutHints.pair("Cmd+.", "Cmd+Shift+,"), "Cmd+. Cmd+Shift+,")
        XCTAssertEqual(KeyCapFormatter.glyphs(for: DesignShortcutHints.pair("Cmd+Up", "Cmd+Down")), "⌘↑/↓")
    }

    func testAPIMethodTones() {
        XCTAssertEqual(DesignAPIMethodTone.tone(for: "get"), .success)
        XCTAssertEqual(DesignAPIMethodTone.tone(for: "POST"), .info)
        XCTAssertEqual(DesignAPIMethodTone.tone(for: "PATCH"), .warning)
        XCTAssertEqual(DesignAPIMethodTone.tone(for: "DELETE"), .critical)
        XCTAssertEqual(DesignAPIMethodTone.tone(for: "TRACE"), .neutral)
    }

    func testTextValidatorDropsPlaceholders() {
        XCTAssertFalse(DesignTextValidator.isMeaningful(nil))
        XCTAssertFalse(DesignTextValidator.isMeaningful("   "))
        XCTAssertFalse(DesignTextValidator.isMeaningful("---"))
        XCTAssertFalse(DesignTextValidator.isMeaningful("ok"))
        XCTAssertTrue(DesignTextValidator.isMeaningful("Shard by user id"))
    }

    func testSettledBannerPrecedence() {
        XCTAssertNil(DesignCompletenessPresenter.settledBanner(report: nil, recoveryInProgress: false))

        let recovering = DesignCompletenessPresenter.settledBanner(report: nil, recoveryInProgress: true)
        XCTAssertEqual(recovering?.tone, .info)

        let content = DesignRenderFixtures.content
        let report = SystemDesignCompletenessReport.from(content: content, recoveryAttempted: true)
        let banner = DesignCompletenessPresenter.settledBanner(report: report, recoveryInProgress: true)
        XCTAssertEqual(banner?.tone, report.isComplete ? .success : .warning)
        XCTAssertTrue(banner?.message.hasSuffix("Recovery was attempted.") == true)
    }

    func testLiveBannerPrefersRecoveryAndHidesCompleteReports() {
        let content = DesignRenderFixtures.content
        let report = SystemDesignCompletenessReport.from(content: content, recoveryAttempted: false)

        XCTAssertEqual(DesignCompletenessPresenter.liveBanner(report: report, recoveryInProgress: true)?.tone, .info)
        let settled = DesignCompletenessPresenter.liveBanner(report: report, recoveryInProgress: false)
        if report.isComplete {
            XCTAssertNil(settled)
        } else {
            XCTAssertEqual(settled?.title, "Generation incomplete")
        }
    }

    func testSectionIssueOnlyForIncompleteSections() {
        let complete = SystemDesignSectionCompleteness(id: "wrapUp", title: "Wrap-Up", expectedStepCount: 1, actualStepCount: 1, coherenceIssues: [])
        XCTAssertNil(DesignCompletenessPresenter.sectionIssue(complete))

        let short = SystemDesignSectionCompleteness(id: "components", title: "Components", expectedStepCount: 3, actualStepCount: 1, coherenceIssues: ["Step 2 shares no identifier with step 1"])
        let issue = DesignCompletenessPresenter.sectionIssue(short)
        XCTAssertEqual(issue?.tone, .warning)
        XCTAssertTrue(issue?.message.contains("missing 2") == true)
        XCTAssertTrue(issue?.message.contains("shares no identifier") == true)
    }
}
