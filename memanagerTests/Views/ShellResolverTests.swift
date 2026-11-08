import XCTest
@testable import memanager

/// Pure logic behind the shell: which surface is showing, what the live
/// strip says, and how the design phase rail maps onto blueprint sections.
final class ShellResolverTests: XCTestCase {

    // MARK: Surface resolution

    func testTranscriptCanCoverAssistWithoutClearingItsSelection() {
        let resolver = MentorSurfaceResolver(isQuickAssistVisible: true, isTranscriptVisible: true, currentSection: .systemDesign)
        XCTAssertEqual(resolver.surface, .transcript)
    }

    @MainActor
    func testTranscriptReturnsToThePriorLiveModeAndKeepsTheDraft() {
        let controller = SessionController.shared
        controller.resetSessionStateForTesting()
        defer { controller.resetSessionStateForTesting() }
        for (assist, section, expected) in [
            (true, MentorResponse.Section.implementation, MentorSurface.assist),
            (false, .implementation, .solve),
            (false, .systemDesign, .design)
        ] {
            controller.isQuickAssistViewVisible = assist
            controller.currentSection = section
            controller.quickAssistQuestion = "Unsent question"
            controller.showTranscriptLog()
            controller.showTranscriptLog()
            XCTAssertEqual(MentorSurfaceResolver(
                isQuickAssistVisible: controller.isQuickAssistViewVisible,
                isTranscriptVisible: controller.isTranscriptViewVisible,
                currentSection: controller.currentSection
            ).surface, .transcript)
            controller.hideTranscriptLog()
            XCTAssertEqual(MentorSurfaceResolver(
                isQuickAssistVisible: controller.isQuickAssistViewVisible,
                isTranscriptVisible: controller.isTranscriptViewVisible,
                currentSection: controller.currentSection
            ).surface, expected)
            XCTAssertEqual(controller.quickAssistQuestion, "Unsent question")
            XCTAssertEqual(controller.currentSection, section)
            XCTAssertEqual(controller.overlayFocusTarget, assist ? .quickAssistQuestion : .sectionTabs)
        }
    }

    func testTranscriptWinsOverSections() {
        let resolver = MentorSurfaceResolver(isQuickAssistVisible: false, isTranscriptVisible: true, currentSection: .systemDesign)
        XCTAssertEqual(resolver.surface, .transcript)
    }

    func testDesignSectionMapsToDesignSurface() {
        let resolver = MentorSurfaceResolver(isQuickAssistVisible: false, isTranscriptVisible: false, currentSection: .systemDesign)
        XCTAssertEqual(resolver.surface, .design)
    }

    func testCodingSectionsMapToSolve() {
        for section in MentorSurfaceResolver.solveSections {
            let resolver = MentorSurfaceResolver(isQuickAssistVisible: false, isTranscriptVisible: false, currentSection: section)
            XCTAssertEqual(resolver.surface, .solve, "\(section) should resolve to Solve")
        }
        XCTAssertFalse(MentorSurfaceResolver.solveSections.contains(.systemDesign))
    }

    // MARK: Live question

    func testQuestionMarkAndOpenersReadAsQuestions() {
        XCTAssertTrue(LiveQuestionResolver.looksLikeQuestion("How would you scale this?"))
        XCTAssertTrue(LiveQuestionResolver.looksLikeQuestion("Tell me about a time you disagreed with a manager"))
        XCTAssertTrue(LiveQuestionResolver.looksLikeQuestion("walk me through the design"))
        XCTAssertFalse(LiveQuestionResolver.looksLikeQuestion("Thanks, that makes sense."))
    }

    func testPartialFromTheOtherPartyOverridesFinishedEntries() {
        let entries = [makeEntry(.speaker(0), "Tell me about yourself."), makeEntry(.me, "Sure, I lead the payments team.")]
        let question = LiveQuestionResolver.resolve(entries: entries, partialOther: "And what did you ship last quarter", partialOtherSpeaker: .speaker(0))
        XCTAssertEqual(question?.text, "And what did you ship last quarter")
        XCTAssertEqual(question?.isPartial, true)
        XCTAssertEqual(question?.isQuestion, true)
    }

    func testFallsBackToTheNewestOtherPartyLineAndSkipsTheUser() {
        let entries = [makeEntry(.speaker(1), "Why Stripe?"), makeEntry(.me, "Because of the scale.")]
        let question = LiveQuestionResolver.resolve(entries: entries, partialOther: "short", partialOtherSpeaker: .speaker(1))
        XCTAssertEqual(question?.text, "Why Stripe?")
        XCTAssertEqual(question?.speaker, .speaker(1))
        XCTAssertEqual(question?.isPartial, false)
    }

    func testNothingFromTheOtherPartyYieldsNil() {
        let entries = [makeEntry(.me, "Hello, can you hear me?")]
        XCTAssertNil(LiveQuestionResolver.resolve(entries: entries, partialOther: "", partialOtherSpeaker: .speaker(0)))
    }

    // MARK: Transcript rows

    func testRowsAppendPartialsAndHonourTheLimit() {
        let entries = (0..<5).map { makeEntry($0 % 2 == 0 ? .speaker(0) : .me, "line \($0)") }
        let rows = TranscriptRowsBuilder.rows(entries: entries, partialMe: " typing ", partialOther: "and me", partialOtherSpeaker: .speaker(0), limit: 4)
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows.suffix(2).map(\.isPartial), [true, true])
        XCTAssertEqual(rows[rows.count - 2].text, "typing")
        XCTAssertEqual(rows.last?.speaker, .speaker(0))
    }

    func testPartialRowsKeepStableIdentitiesAcrossRebuilds() {
        let first = TranscriptRowsBuilder.rows(entries: [], partialMe: "a", partialOther: "b", partialOtherSpeaker: .speaker(0), limit: nil)
        let second = TranscriptRowsBuilder.rows(entries: [], partialMe: "aa", partialOther: "bb", partialOtherSpeaker: .speaker(0), limit: nil)
        XCTAssertEqual(first.map(\.id), second.map(\.id))
    }

    func testRowLabelsAndQuestionFlag() {
        let row = TranscriptRowModel(id: UUID(), speaker: .speaker(2), text: "Which database would you pick?", isPartial: false, timestamp: nil, deepgramSpeakerId: 2)
        XCTAssertEqual(row.speakerLabel, "Speaker 3")
        XCTAssertTrue(row.isQuestion)
        let mine = TranscriptRowModel(id: UUID(), speaker: .me, text: "Which one?", isPartial: false, timestamp: nil, deepgramSpeakerId: nil)
        XCTAssertEqual(mine.speakerLabel, "You")
        XCTAssertFalse(mine.isQuestion, "the user's own questions are not marked")
    }

    // MARK: Design phases

    func testEveryBlueprintSectionBelongsToExactlyOnePhase() {
        for section in SystemDesignBlueprint.sections {
            let owners = DesignPhaseCatalog.phases.filter { $0.sectionIDs.contains(section.id) }
            XCTAssertEqual(owners.count, 1, "\(section.id) should belong to one phase")
        }
    }

    func testRailMarksEarlierPhasesCompleteAndFindsFirstSectionOfAPhase() {
        let available = ["requirements", "estimation", "architecture", "database", "tradeoffs", "wrapUp"]
        let rail = DesignPhaseCatalog.railItems(availableSectionIDs: available, currentSectionIndex: 3)
        XCTAssertEqual(rail.currentPhase, 3)
        XCTAssertEqual(rail.items.filter(\.isComplete).map(\.id), [0, 1, 2])
        XCTAssertEqual(DesignPhaseCatalog.firstSectionIndex(inPhase: 4, availableSectionIDs: available), 4)
        XCTAssertNil(DesignPhaseCatalog.firstSectionIndex(inPhase: 9, availableSectionIDs: available))
    }

    func testRailWithNoContentStartsAtRequirements() {
        let rail = DesignPhaseCatalog.railItems(availableSectionIDs: [], currentSectionIndex: 0)
        XCTAssertEqual(rail.currentPhase, 0)
        XCTAssertTrue(rail.items.allSatisfy { !$0.isComplete })
    }

    // MARK: Helpers

    private func makeEntry(_ speaker: TranscriptSpeaker, _ text: String) -> TranscriptEntry {
        TranscriptEntry(speaker: speaker, text: text, timestamp: Date(), deepgramSpeakerId: speaker.speakerNumber)
    }
}
