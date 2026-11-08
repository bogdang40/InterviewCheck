import Foundation

extension SessionController {
    func showTranscriptLog() {
        isTranscriptViewVisible = true
        isMLGuideViewVisible = false
        activeScrollTarget = .transcript
        overlayFocusTarget = .transcriptView
        returnOverlayToMentor()
    }
    func hideTranscriptLog() {
        isTranscriptViewVisible = false
        activeScrollTarget = isQuickAssistViewVisible ? .quickAssist : .main
        overlayFocusTarget = isQuickAssistViewVisible ? .quickAssistQuestion : .sectionTabs
    }
    // MARK: - Section Navigation

    func nextSection() {
        revealMentorSections()
        let allSections = MentorResponse.Section.allCases
        guard let currentIndex = allSections.firstIndex(of: currentSection),
              currentIndex < allSections.count - 1 else { return }
        currentSection = allSections[currentIndex + 1]
    }
    func previousSection() {
        revealMentorSections()
        let allSections = MentorResponse.Section.allCases
        guard let currentIndex = allSections.firstIndex(of: currentSection),
              currentIndex > 0 else { return }
        currentSection = allSections[currentIndex - 1]
    }
    func jumpToSection(_ index: Int) {
        revealMentorSections()
        let allSections = MentorResponse.Section.allCases
        guard index >= 0, index < allSections.count else { return }
        currentSection = allSections[index]
    }
    func selectSection(_ section: MentorResponse.Section) {
        revealMentorSections()
        currentSection = section
    }
    /// Puts the section surface on screen and returns the overlay to the
    /// mentor screen in case Workspaces, Knowledge, or Settings was showing.
    private func revealMentorSections() {
        isTranscriptViewVisible = false
        isQuickAssistViewVisible = false
        isMLGuideViewVisible = false
        activeScrollTarget = .main
        returnOverlayToMentor()
    }
    /// Same for the Quick Assist surface.
    func revealQuickAssistSurface() {
        isQuickAssistViewVisible = true
        isTranscriptViewVisible = false
        isMLGuideViewVisible = false
        activeScrollTarget = .quickAssist
        returnOverlayToMentor()
    }
    /// The surface flags above are published UI state and are only ever
    /// flipped on the main thread (hotkey dispatch, SwiftUI actions), but
    /// the methods that flip them predate actor annotations. The navigator
    /// is main actor bound, so the hop is asserted rather than awaited.
    private func returnOverlayToMentor() {
        MainActor.assumeIsolated {
            overlayNavigator.returnToMentor()
        }
    }
    // MARK: - Implementation Step Navigation

    func nextImplementationStep() {
        guard currentSection == .implementation else { return }
        guard expandedImplementationStep < implementationStepCount else { return }
        expandedImplementationStep += 1
    }
    func previousImplementationStep() {
        guard currentSection == .implementation else { return }
        guard expandedImplementationStep > 1 else { return }
        expandedImplementationStep -= 1
    }
    func setImplementationStepCount(_ count: Int) {
        implementationStepCount = max(0, count)
        if expandedImplementationStep < 1 || expandedImplementationStep > implementationStepCount {
            expandedImplementationStep = 1
        }
    }
    
    // MARK: - Teleprompter Mode (Chunk Navigation)

    func shouldConsumeTeleprompterHotkeys() -> Bool {
        !isQuickAssistViewVisible
    }
    func shouldConsumeQuickAssistHistoryHotkeys() -> Bool {
        isQuickAssistViewVisible
    }
    func isSystemDesignSurfaceActive() -> Bool {
        currentSection == .systemDesign && !isQuickAssistViewVisible
    }
    func shouldConsumeQuickAssistModeHotkeys() -> Bool {
        isQuickAssistViewVisible
    }
    
    func toggleTeleprompterMode() {
        teleprompterModeEnabled.toggle()
        if teleprompterModeEnabled {
            currentChunkIndex = 0
        }
    }
    
    func nextChunk() {
        // System Design section: teleprompter navigates chunks, otherwise navigate sections
        if currentSection == .systemDesign, systemDesignSectionCount > 0 {
            if teleprompterModeEnabled {
                // In teleprompter mode: navigate chunks, then advance to next section
                if currentChunkIndex < totalChunkCount - 1 {
                    currentChunkIndex += 1
                } else if systemDesignSectionIndex < systemDesignSectionCount - 1 {
                    // At last chunk of section - advance to next section
                    nextSystemDesignSection()
                    currentChunkIndex = 0
                }
            } else {
                // Not in teleprompter mode: navigate sections directly
                nextSystemDesignSection()
            }
            return
        }
        
        guard teleprompterModeEnabled else { return }
        guard currentChunkIndex < totalChunkCount - 1 else {
            // At last chunk - advance to next step if available
            if expandedImplementationStep < implementationStepCount {
                nextImplementationStep()
                currentChunkIndex = 0
            }
            return
        }
        currentChunkIndex += 1
    }
    
    func previousChunk() {
        // System Design section: teleprompter navigates chunks, otherwise navigate sections
        if currentSection == .systemDesign, systemDesignSectionCount > 0 {
            if teleprompterModeEnabled {
                // In teleprompter mode: navigate chunks, then go to previous section
                if currentChunkIndex > 0 {
                    currentChunkIndex -= 1
                } else if systemDesignSectionIndex > 0 {
                    // At first chunk of section - go to previous section
                    previousSystemDesignSection()
                    // Reset to last chunk of previous section (will be set when chunk count updates)
                    currentChunkIndex = max(0, totalChunkCount - 1)
                }
            } else {
                // Not in teleprompter mode: navigate sections directly
                previousSystemDesignSection()
            }
            return
        }
        
        guard teleprompterModeEnabled else { return }
        guard currentChunkIndex > 0 else {
            // At first chunk - go to previous step if available
            if expandedImplementationStep > 1 {
                previousImplementationStep()
                // Will be set to last chunk when chunk count is updated
                currentChunkIndex = max(0, totalChunkCount - 1)
            }
            return
        }
        currentChunkIndex -= 1
    }
    
    func setChunkCount(_ count: Int) {
        totalChunkCount = max(0, count)
        currentChunkIndex = max(0, min(currentChunkIndex, totalChunkCount - 1))
    }
    
    func resetChunkNavigation() {
        currentChunkIndex = 0
    }
}
