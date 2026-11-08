import Foundation
import Combine

extension SessionController {
    /// When the other party just asked something, capture the screen in the
    /// background so the follow up Cmd+/ hits a warm cache.
    private func prewarmScreenshotForLikelyQuestion(entries: [TranscriptEntry]) {
        guard let last = entries.last, last.id != lastScreenshotPrewarmEntryID else { return }
        guard QuickAssistScreenshotPrewarmPolicy.shouldPrewarm(for: last) else { return }
        lastScreenshotPrewarmEntryID = last.id
        screenshotService.prewarmFreshFullScreenCache()
    }
    func setupBindings() {
        // Sync audio transcript. Audio-path publishers can fire off the main
        // thread; hop before touching @Published state, and keep the
        // subscriptions weak so test-constructed controllers can deallocate.
        audioService.$transcript
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transcript in
                self?.session.transcript = transcript
            }
            .store(in: &cancellables)

        audioService.$transcriptEntries
            .receive(on: DispatchQueue.main)
            .sink { [weak self] entries in
                self?.session.transcriptEntries = entries
            }
            .store(in: &cancellables)

        audioService.$transcriptEntries
            .receive(on: DispatchQueue.main)
            .sink { [weak self] entries in
                guard let self else { return }
                self.interviewSignalEngine.consume(
                    entries: entries,
                    captureState: self.audioService.captureState,
                    enabled: self.settings.hubProactiveNudgesEnabled
                )
                PacingDirector.shared.ingest(entries: entries)
                self.prewarmScreenshotForLikelyQuestion(entries: entries)
            }
            .store(in: &cancellables)

        PacingDirector.shared.statePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.pacingState = state
            }
            .store(in: &cancellables)

        canvasDirector.$scene
            .receive(on: DispatchQueue.main)
            .sink { [weak self] scene in
                self?.canvasScene = scene
            }
            .store(in: &cancellables)

        Publishers.CombineLatest(
            PracticeStore.shared.cardsPublisher,
            PracticeStore.shared.schedulesPublisher
        )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                guard let self else { return }
                self.practiceCardsDueCount = PracticeStore.shared.dueCards(on: Date()).count
            }
            .store(in: &cancellables)

        // Sync screenshots
        screenshotService.$screenshots
            .receive(on: DispatchQueue.main)
            .sink { [weak self] screenshots in
                self?.session.screenshots = screenshots
            }
            .store(in: &cancellables)

        audioService.$captureState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.syncSessionState(with: state)
            }
            .store(in: &cancellables)

        settings.$providerConfigurationVersion
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.loadProviderSettings()
            }
            .store(in: &cancellables)

        interviewSignalEngine.$activeNudge
            .receive(on: DispatchQueue.main)
            .sink { [weak self] nudge in
                guard let self else { return }
                switch self.currentSignalDisposition() {
                case .clear:
                    self.activeHubNudge = nil
                case .hold:
                    break
                case .apply:
                    self.activeHubNudge = nudge
                }
            }
            .store(in: &cancellables)

        interviewSignalEngine.$activeMoment
            .receive(on: DispatchQueue.main)
            .sink { [weak self] moment in
                guard let self else { return }
                switch self.currentSignalDisposition() {
                case .clear:
                    self.activeInterviewMoment = nil
                case .hold:
                    break
                case .apply:
                    self.activeInterviewMoment = moment
                }
            }
            .store(in: &cancellables)

        interviewSignalEngine.$responseCards
            .receive(on: DispatchQueue.main)
            .sink { [weak self] cards in
                guard let self else { return }
                switch self.currentSignalDisposition() {
                case .clear:
                    self.liveResponseCards = []
                case .hold:
                    break
                case .apply:
                    self.liveResponseCards = cards
                    if self.activeLiveResponseCardIndex >= cards.count {
                        self.activeLiveResponseCardIndex = 0
                    }
                    if let card = cards.first,
                       let moment = self.activeInterviewMoment {
                        self.logger.logResponseCardEvent(
                            name: "response_card_shown",
                            sessionId: self.session.id.uuidString,
                            momentId: moment.id,
                            card: card
                        )
                    }
                }
            }
            .store(in: &cancellables)

        settings.$hubProactiveNudgesEnabled
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                if !enabled {
                    self.activeHubNudge = nil
                    self.activeInterviewMoment = nil
                    self.liveResponseCards = []
                    self.teleprompterPinnedResponseCard = nil
                    self.interviewSignalEngine.reset()
                }
            }
            .store(in: &cancellables)

        settings.$hubFailureCoachEnabled
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled {
                    self.evaluateProactiveFailureCoach(force: true)
                } else {
                    self.activeCoachFindings = []
                }
            }
            .store(in: &cancellables)

        settings.$hubMemoryEnabled
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                if !enabled {
                    self.quickAssistMemorySnippets = []
                    self.quickAssistRelatedMemorySnippets = []
                } else {
                    self.refreshQuickAssistRelatedMemoryContext(trigger: .quickAssistView)
                }
            }
            .store(in: &cancellables)

        settings.$openAIQuickAssistDisplayMode
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshQuickAssistDisplayedResponse()
            }
            .store(in: &cancellables)

        settings.$openAIVoiceGuardEnabled
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshQuickAssistDisplayedResponse()
            }
            .store(in: &cancellables)

        $quickAssistHistorySearchQuery
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.syncSelectedQuickAssistHistoryThreadID()
            }
            .store(in: &cancellables)

    }
    private func currentSignalDisposition() -> SessionSignalGate.Disposition {
        SessionSignalGate.disposition(
            proactiveNudgesEnabled: settings.hubProactiveNudgesEnabled,
            isLoading: isLoading,
            isStreaming: isStreaming,
            isQuickAssistLoading: isQuickAssistLoading,
            isMLGuideLoading: isMLGuideLoading
        )
    }
    /// Starts app-lifetime background work (pacing sampling and the periodic
    /// silence/failure-coach evaluation). Owned by AppDelegate's launch and
    /// terminate hooks rather than by binding setup, so constructing a
    /// controller (in tests, previews) never starts global timers.
    func startRuntimeServices() {
        guard runtimeServiceCancellables.isEmpty else { return }
        PacingDirector.shared.start()
        Timer.publish(every: 8, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] now in
                guard let self else { return }
                self.interviewSignalEngine.evaluateSilence(
                    now: now,
                    lastTranscriptAt: self.session.transcriptEntries.last?.timestamp,
                    captureState: self.audioService.captureState,
                    enabled: self.settings.hubProactiveNudgesEnabled
                )
                self.evaluateProactiveFailureCoach(now: now)
            }
            .store(in: &runtimeServiceCancellables)
    }
    func stopRuntimeServices() {
        runtimeServiceCancellables.removeAll()
        PacingDirector.shared.stop()
    }
}
