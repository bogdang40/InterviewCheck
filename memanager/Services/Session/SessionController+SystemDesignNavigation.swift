import Foundation

extension SessionController {
    // MARK: - System Design Section Navigation

    func setSystemDesignSectionCount(_ count: Int) {
        let oldCount = systemDesignSectionCount
        let oldIndex = systemDesignSectionIndex
        
        systemDesignSectionCount = max(0, count)
        if count <= 0 {
            systemDesignSectionIndex = 0
            systemDesignStepIndexBySection = [:]
            systemDesignCompletenessReport = nil
            self.logger.logSystemDesignEvent(
                name: "sectionCount_reset",
                details: "oldCount=\(oldCount), newCount=\(count), index reset to 0"
            )
            return
        }
        if systemDesignSectionIndex >= count {
            systemDesignSectionIndex = max(0, count - 1)
        }
        
        self.logger.logSystemDesignEvent(
            name: "sectionCount_updated",
            details: "oldCount=\(oldCount), newCount=\(count), oldIndex=\(oldIndex), newIndex=\(systemDesignSectionIndex)"
        )
    }
    func systemDesignStepIndex(for sectionID: String, stepCount: Int) -> Int {
        guard stepCount > 0 else { return 0 }
        let current = systemDesignStepIndexBySection[sectionID] ?? 0
        return max(0, min(current, stepCount - 1))
    }
    func setSystemDesignStepIndex(_ index: Int, for sectionID: String, stepCount: Int) {
        guard stepCount > 0 else {
            systemDesignStepIndexBySection.removeValue(forKey: sectionID)
            return
        }

        let clamped = max(0, min(index, stepCount - 1))
        systemDesignStepIndexBySection[sectionID] = clamped
    }
    func nextSystemDesignStep(in sectionID: String, stepCount: Int) {
        let current = systemDesignStepIndex(for: sectionID, stepCount: stepCount)
        guard current < stepCount - 1 else { return }
        setSystemDesignStepIndex(current + 1, for: sectionID, stepCount: stepCount)
    }
    func previousSystemDesignStep(in sectionID: String, stepCount: Int) {
        let current = systemDesignStepIndex(for: sectionID, stepCount: stepCount)
        guard current > 0 else { return }
        setSystemDesignStepIndex(current - 1, for: sectionID, stepCount: stepCount)
    }
    func nextSystemDesignProgressiveStepByHotkey() {
        guard currentSection == .systemDesign else {
            self.logger.logNavigationEvent(
                name: "hotkey_nextDesignStep_ignored",
                details: "currentSection=\(currentSection)"
            )
            return
        }

        guard let parsed = parsedSystemDesignContent else {
            self.logger.logNavigationEvent(
                name: "hotkey_nextDesignStep_noParsedContent"
            )
            return
        }

        let sectionIDs = orderedSystemDesignProgressiveSectionIDs(from: parsed)
        guard !sectionIDs.isEmpty else {
            self.logger.logNavigationEvent(
                name: "hotkey_nextDesignStep_noProgressiveSections"
            )
            return
        }

        let currentSectionPosition = max(0, min(systemDesignSectionIndex, sectionIDs.count - 1))
        if currentSectionPosition != systemDesignSectionIndex {
            systemDesignSectionIndex = currentSectionPosition
        }

        let currentSectionID = sectionIDs[currentSectionPosition]
        let currentStepCount = parsed.progressiveStepCount(for: currentSectionID)
        guard currentStepCount > 0 else { return }

        let currentStepIndex = systemDesignStepIndex(for: currentSectionID, stepCount: currentStepCount)
        if currentStepIndex < currentStepCount - 1 {
            setSystemDesignStepIndex(currentStepIndex + 1, for: currentSectionID, stepCount: currentStepCount)
            self.logger.logNavigationEvent(
                name: "hotkey_nextDesignStep",
                from: "\(currentSectionID)#\(currentStepIndex + 1)",
                to: "\(currentSectionID)#\(currentStepIndex + 2)"
            )
            return
        }

        guard currentSectionPosition < sectionIDs.count - 1 else {
            self.logger.logNavigationEvent(
                name: "hotkey_nextDesignStep_atEnd",
                details: "section=\(currentSectionID), step=\(currentStepIndex + 1)"
            )
            return
        }

        let nextSectionPosition = currentSectionPosition + 1
        let nextSectionID = sectionIDs[nextSectionPosition]
        let nextStepCount = parsed.progressiveStepCount(for: nextSectionID)
        guard nextStepCount > 0 else { return }

        systemDesignSectionIndex = nextSectionPosition
        setSystemDesignStepIndex(0, for: nextSectionID, stepCount: nextStepCount)
        self.logger.logNavigationEvent(
            name: "hotkey_nextDesignStep_crossSection",
            from: "\(currentSectionID)#\(currentStepIndex + 1)",
            to: "\(nextSectionID)#1"
        )
    }
    func previousSystemDesignProgressiveStepByHotkey() {
        guard currentSection == .systemDesign else {
            self.logger.logNavigationEvent(
                name: "hotkey_prevDesignStep_ignored",
                details: "currentSection=\(currentSection)"
            )
            return
        }

        guard let parsed = parsedSystemDesignContent else {
            self.logger.logNavigationEvent(
                name: "hotkey_prevDesignStep_noParsedContent"
            )
            return
        }

        let sectionIDs = orderedSystemDesignProgressiveSectionIDs(from: parsed)
        guard !sectionIDs.isEmpty else {
            self.logger.logNavigationEvent(
                name: "hotkey_prevDesignStep_noProgressiveSections"
            )
            return
        }

        let currentSectionPosition = max(0, min(systemDesignSectionIndex, sectionIDs.count - 1))
        if currentSectionPosition != systemDesignSectionIndex {
            systemDesignSectionIndex = currentSectionPosition
        }

        let currentSectionID = sectionIDs[currentSectionPosition]
        let currentStepCount = parsed.progressiveStepCount(for: currentSectionID)
        guard currentStepCount > 0 else { return }

        let currentStepIndex = systemDesignStepIndex(for: currentSectionID, stepCount: currentStepCount)
        if currentStepIndex > 0 {
            setSystemDesignStepIndex(currentStepIndex - 1, for: currentSectionID, stepCount: currentStepCount)
            self.logger.logNavigationEvent(
                name: "hotkey_prevDesignStep",
                from: "\(currentSectionID)#\(currentStepIndex + 1)",
                to: "\(currentSectionID)#\(currentStepIndex)"
            )
            return
        }

        guard currentSectionPosition > 0 else {
            self.logger.logNavigationEvent(
                name: "hotkey_prevDesignStep_atStart",
                details: "section=\(currentSectionID), step=\(currentStepIndex + 1)"
            )
            return
        }

        let previousSectionPosition = currentSectionPosition - 1
        let previousSectionID = sectionIDs[previousSectionPosition]
        let previousStepCount = parsed.progressiveStepCount(for: previousSectionID)
        guard previousStepCount > 0 else { return }

        systemDesignSectionIndex = previousSectionPosition
        setSystemDesignStepIndex(previousStepCount - 1, for: previousSectionID, stepCount: previousStepCount)
        self.logger.logNavigationEvent(
            name: "hotkey_prevDesignStep_crossSection",
            from: "\(currentSectionID)#1",
            to: "\(previousSectionID)#\(previousStepCount)"
        )
    }
    func resetSystemDesignStepIndices() {
        systemDesignStepIndexBySection = [:]
    }
    func nextSystemDesignSection() {
        guard currentSection == .systemDesign else {
            self.logger.logNavigationEvent(
                name: "nextSystemDesign_ignored",
                details: "currentSection=\(currentSection)"
            )
            return
        }
        guard systemDesignSectionIndex < systemDesignSectionCount - 1 else {
            self.logger.logNavigationEvent(
                name: "nextSystemDesign_atEnd",
                details: "index=\(systemDesignSectionIndex), count=\(systemDesignSectionCount)"
            )
            return
        }
        
        let oldIndex = systemDesignSectionIndex
        systemDesignSectionIndex += 1
        
        self.logger.logNavigationEvent(
            name: "nextSystemDesignSection",
            from: "\(oldIndex)",
            to: "\(systemDesignSectionIndex)",
            details: "count=\(systemDesignSectionCount)"
        )
    }
    func previousSystemDesignSection() {
        guard currentSection == .systemDesign else {
            self.logger.logNavigationEvent(
                name: "prevSystemDesign_ignored",
                details: "currentSection=\(currentSection)"
            )
            return
        }
        guard systemDesignSectionIndex > 0 else {
            self.logger.logNavigationEvent(
                name: "prevSystemDesign_atStart",
                details: "index=\(systemDesignSectionIndex)"
            )
            return
        }
        
        let oldIndex = systemDesignSectionIndex
        systemDesignSectionIndex -= 1
        
        self.logger.logNavigationEvent(
            name: "previousSystemDesignSection",
            from: "\(oldIndex)",
            to: "\(systemDesignSectionIndex)",
            details: "count=\(systemDesignSectionCount)"
        )
    }
    private func orderedSystemDesignProgressiveSectionIDs(from content: SystemDesignContent) -> [String] {
        SystemDesignSectionExpectation.all.compactMap { section in
            content.progressiveStepCount(for: section.id) > 0 ? section.id : nil
        }
    }
}
