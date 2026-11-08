import Foundation
import Combine

final class SessionController: ObservableObject {
    static let shared = SessionController()
    @Published var session = Session()
    @Published var currentSection: MentorResponse.Section = .problem
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var quickAssistResponse: String?
    @Published var quickAssistTurns: [QuickAssistThread.Turn] = []
    @Published var selectedQuickAssistTurnIndex: Int?
    @Published var quickAssistStreamingDraft: String?
    /// Interrupted text stays inspectable without overwriting a persisted turn.
    @Published var quickAssistInterruptedAnswer: QuickAssistInterruptedAnswer?
    @Published var quickAssistRequestQuestion: String?
    @Published var quickAssistLastStableResponse: String?
    @Published var quickAssistLastStableTurnID: UUID?
    @Published var quickAssistThreadSummaries: [QuickAssistThreadSummary] = []
    @Published var activeQuickAssistThreadID: String? {
        didSet {
            if oldValue != activeQuickAssistThreadID {
                quickAssistInterruptedAnswer = nil
                quickAssistRequestQuestion = nil
            }
        }
    }
    @Published var quickAssistSelectedHistoryThreadID: String?
    @Published var quickAssistHistorySearchQuery: String = ""
    @Published var quickAssistQuestionFocusNonce: Int = 0
    @Published var quickAssistHistorySearchFocusNonce: Int = 0
    @Published var isOverlayWindowVisible = false
    @Published var overlayFocusTarget: OverlayFocusTarget?
    @Published var overlaySelectionState = OverlaySelectionState()
    @Published var quickAssistPendingDeletionThreadID: String?
    @Published var isQuickAssistLoading = false
    @Published var quickAssistForceTools: Bool = false
    @Published var quickAssistToolCallEvents: [ProjectToolCallEvent] = []
    @Published var quickAssistReasoningEvents: [ProjectToolReasoningEvent] = []
    @Published var quickAssistSelectedToolTrace: QuickAssistToolTrace?
    @Published var quickAssistSelectedReasoningFlow: QuickAssistReasoningFlow?
    let reasoningFlowBuilder = QuickAssistReasoningFlowBuilder()
    /// Cache generation for the live tool trace / reasoning flow. The two
    /// derived values are read on every MentorView body pass (per token while
    /// streaming) but only change when an event lands, so presenting the
    /// trace (JSON decoding every tool call) is keyed off this revision.
    var quickAssistFlowRevision: UInt64 = 0
    var quickAssistFlowCachedRevision: UInt64 = .max
    var quickAssistFlowCachedToolTrace: QuickAssistToolTrace?
    var quickAssistFlowCachedReasoningFlow: QuickAssistReasoningFlow?
    @Published var isTranscriptViewVisible = false
    @Published var isQuickAssistViewVisible = false
    @Published var quickAssistQuestion: String = "" {
        didSet {
            // Typing a question predicts an imminent ask; warm the capture
            // cache off the main thread (no-op while warm or in flight).
            if !quickAssistQuestion.isEmpty, quickAssistQuestion != oldValue {
                screenshotService.prewarmFreshFullScreenCache()
            }
        }
    }
    /// Last transcript entry that already triggered a screenshot prewarm.
    var lastScreenshotPrewarmEntryID: UUID?
    @Published var quickAssistExtraContext: String = ""
    @Published var quickAssistExtraContextExpanded = false
    @Published var quickAssistContextStatusMessage: String?
    @Published var quickAssistActiveTier: QuickAssistModelTier = .fast
    @Published var quickAssistSelectedMode: QuickAssistThreadMode = .auto
    @Published var quickAssistResolvedMode: QuickAssistThreadMode?
    @Published var quickAssistRouteSummary: String?
    @Published var quickAssistRouteOverrideIntent: QuickAssistIntent?
    @Published var quickAssistAnswerFamilyBadge: QuickAssistAnswerFamilyBadge?
    @Published var quickAssistMemorySnippets: [String] = []
    @Published var quickAssistRelatedMemorySnippets: [RelatedMemorySnippet] = []
    @Published var quickAssistVerificationRecord: QuickAssistVerificationRecord?
    @Published var quickAssistSelectedTurnFeedbackStatus: QuickAssistTurnFeedbackStatus = .none
    @Published var quickAssistRecoveryPlan: QuickAssistRecoveryPlan?
    @Published var quickAssistExperimentThreadID: String?
    @Published var quickAssistExperimentComparison: WorkstreamThreadComparison?
    @Published var activeQuickAssistExperiment: QuickAssistExperiment?
    @Published var activeScrollTarget: ScrollTarget = .main
    @Published var activeHubNudge: HubNudge?
    @Published var activeInterviewMoment: InterviewMoment?
    @Published var liveResponseCards: [ResponseCard] = []
    @Published var activeLiveResponseCardIndex: Int = 0
    @Published var teleprompterPinnedResponseCard: ResponseCard?
    @Published var workstreamTimelineEvents: [WorkstreamTimelineEvent] = []
    @Published var workstreamTimelineFilter: WorkstreamTimelineFilter = WorkstreamTimelineFilter()
    @Published var selectedWorkstreamTimelineEventID: String?
    @Published var activeCoachFindings: [CoachFindingRecord] = []
    @Published var workstreamCompareLeftThreadID: String?
    @Published var workstreamCompareRightThreadID: String?
    
    // ML Guide state (separate from Quick Assist)
    @Published var mlGuideResponse: String?
    @Published var isMLGuideLoading = false
    @Published var isMLGuideViewVisible = false
    @Published var mlGuideQuestion: String = ""
    @Published var mlGuideExtraContext: String = ""
    
    // Streaming response text (updated in real-time during solve)
    @Published var streamingResponseText: String = ""
    @Published var isStreaming = false
    
    // Solve mode - determines which prompt/format to use
    @Published var solveMode: SolveMode = .algorithm
    // Implementation step navigation
    @Published var expandedImplementationStep: Int = 1
    @Published var implementationStepCount: Int = 0
    
    // Teleprompter mode for chunk-by-chunk navigation
    @Published var teleprompterModeEnabled: Bool = false
    @Published var currentChunkIndex: Int = 0
    @Published var totalChunkCount: Int = 0
    @Published var currentSessionDebrief: SessionDebrief?
    @Published var isGeneratingDebrief: Bool = false
    @Published var debriefError: String?
    var reviewAnalyticsGate = SessionHistoryRequestGate()
    // Session history analytics
    @Published var currentSessionMetrics: DebriefMetrics?
    @Published var currentSkillReport: SkillProgressionReport = .empty
    @Published var currentProviderBreakdown: [ProviderSessionSummary] = []
    @Published var sessionCardMetadataMap: [String: SessionCardMetadata] = [:]
    var sessionCardMetadataRequestID = UUID()
    @Published var threadCardMetadataMap: [String: ThreadCardMetadata] = [:]
    var threadCardMetadataRequestID = UUID()
    // System design section navigation
    @Published var systemDesignSectionIndex: Int = 0
    @Published var systemDesignSectionCount: Int = 0
    @Published var systemDesignStepIndexBySection: [String: Int] = [:]
    @Published var systemDesignContextStatusMessage: String?
    @Published var systemDesignCompletenessReport: SystemDesignCompletenessReport?
    @Published var systemDesignRecoveryInProgress: Bool = false
    @Published var systemDesignStableFallbackActive: Bool = false
    @Published private(set) var parsedSystemDesignContent: SystemDesignContent?
    let settings = SettingsManager.shared
    let audioService: AudioCaptureService
    let sessionResumeService: SessionResuming
    let startAudioCapture: @MainActor (AudioCaptureService.StartReason) -> Void
    var isRestoredSessionAwaitingStart = false
    let screenshotService = ScreenshotService.shared
    let quickAssistCoordinator = QuickAssistCoordinator()
    let quickAssistIntentRouter = QuickAssistIntentRouter()
    let quickAssistCapabilityComposer = QuickAssistCapabilityComposer()
    let playbookRoutingOverlay = QuickAssistPlaybookRoutingOverlay()
    let behaviouralResponseStyleResolver = BehaviouralResponseStyleResolver()
    let interviewSignalEngine = InterviewSignalEngine.shared
    let workstreamTimelineRepository: WorkstreamTimelineProviding
    let sessionModeContextResolver: SessionModeContextResolving
    let quickAssistToolAvailabilityResolver: QuickAssistToolAvailabilityResolving
    private let injectedOverlayNavigator: OverlayNavigating?
    @MainActor var overlayNavigator: OverlayNavigating { injectedOverlayNavigator ?? OverlayNavigator.shared }
    let workstreamTimelineComposer = WorkstreamTimelineComposer()
    let proactiveFailureCoachEngine: ProactiveFailureCoachEvaluating
    let datasetProfiler: DatasetProfiling
    let responseVoiceGuard: ResponseVoiceGuarding
    let relatedMemoryService: RelatedMemoryRetrieving
    let routingPolicyEngine: QuickAssistRoutingPolicyEvaluating
    let evidencePackBuilder: QuickAssistEvidencePackBuilding
    let answerVerifier: QuickAssistAnswerVerifying
    let recoveryPlanner: QuickAssistRecoveryPlanning
    let experimentRunner: QuickAssistExperimentRunning
    let policyCalibrator: QuickAssistPolicyCalibrator
    let toolTracePresenter = QuickAssistToolTracePresenter()
    let toolBackedAnswerReviewer = QuickAssistToolBackedAnswerReviewer()
    let usesDefaultDebriefComposer: Bool
    var debriefComposer: SessionDebriefComposing
    let debriefMemoryBridge: DebriefMemoryBridging
    let sessionFocusLoader: SessionFocusLoading
    let skillProgressionTracker: SkillProgressionTracking
    let crossSessionCoach: CrossSessionCoachEvaluating
    var sessionFocusContext: SessionFocusContext = .empty
    var cachedSkillReport: SkillProgressionReport = .empty
    var cancellables = Set<AnyCancellable>()
    var runtimeServiceCancellables = Set<AnyCancellable>()
    var workstreamTimelineLoadGeneration = 0
    deinit {
        cancellables.forEach { $0.cancel() }
        runtimeServiceCancellables.forEach { $0.cancel() }
    }
    var aiProvider: AIProvider?
    var lastPauseToggleTime: TimeInterval = 0
    let pauseToggleCooldown: TimeInterval = 0.35
    var lastQuickAssistTriggerTime: TimeInterval = 0
    let quickAssistTriggerCooldown: TimeInterval = 0.15
    var solveTask: Task<Void, Never>?
    var quickAssistTask: Task<Void, Never>?
    var mlGuideTask: Task<Void, Never>?
    var sessionControlTask: Task<Void, Never>?
    var activeSolveRequestID = UUID()
    var activeQuickAssistRequestID = UUID()
    var activeMLGuideRequestID = UUID()
    /// Pacing Director projection. Updated whenever `PacingDirector.shared`
    /// publishes a new state after its hysteresis check. UI and prompt-building
    /// both read this single source instead of touching the director directly.
    @Published var pacingState: PacingState = .measuredBaseline
    /// Live Reasoning Canvas state. `streamingProseText` is the streaming
    /// response text minus any `canvas:*` fenced blocks; `canvasScene` is the
    /// aggregated scene graph built from those blocks.
    @Published var canvasScene: CanvasScene = .empty
    let canvasParser = StreamingCanvasParser()
    let canvasDirector = CanvasDirector()
    /// Feature 3 (Deliberate Practice Studio): count of practice cards that
    /// are due now. Drives the badge on the main overlay and the Studio
    /// header. Derived from `PracticeStore.shared` so it updates live as
    /// cards are authored or reviewed.
    @Published var practiceCardsDueCount: Int = 0
    @Published var isPracticeStudioVisible: Bool = false
    let practiceDeckBuilder = PracticeDeckBuilder(store: PracticeStore.shared)
    
    /// Last successful ML Guide response for follow-up continuations (Cmd+Shift+')
    var lastSuccessfulMLGuideResponse: String?
    
    /// Timestamp of when the last ML Guide completed.
    /// Used to filter transcript entries for ML Guide requests.
    var lastMLGuideTimestamp: Date?
    
    /// Cached dataset summary from the Interview data folder.
    /// Loaded once on first ML Guide trigger and reused for the session.
    var datasetSummary: String?
    var datasetSummaryLoadAttempted = false
    let quickAssistThreadLimit = 300
    var quickAssistStartsFreshThread = false
    let isMLGuideTemporarilyDisabled = true
    var lastQuickAssistMemoryNodeID: String?
    var lastSolveMemoryNodeID: String?
    var lastCoachEvaluationAt: Date?
    var pinnedMemoryNodeIDsByThread: [String: Set<String>] = [:]
    var quickAssistSelectedModeByThread: [String: QuickAssistThreadMode] = [:]
    /// Last classified family per thread, feeding probe inheritance on the
    /// next turn of the same thread.
    var quickAssistLastFamilyByThread: [String: String] = [:]
    var quickAssistCallByTurnID: [UUID: QuickAssistCallRecord] = [:]
    /// Injected logging facade; defaults to the production singleton.
    let logger: SessionLogger
    /// Internal (not private) so tests can construct an isolated controller
    /// with fakes; production code must keep using `shared`.
    init(
        workstreamTimelineRepository: WorkstreamTimelineProviding = WorkstreamTimelineRepository(),
        sessionModeContextResolver: SessionModeContextResolving = SessionModeContextResolver.shared,
        quickAssistToolAvailabilityResolver: QuickAssistToolAvailabilityResolving = QuickAssistToolAvailabilityResolver.shared,
        proactiveFailureCoachEngine: ProactiveFailureCoachEvaluating = ProactiveFailureCoachEngine(),
        datasetProfiler: DatasetProfiling = DatasetProfiler(),
        responseVoiceGuard: ResponseVoiceGuarding = ResponseVoiceGuard(),
        relatedMemoryService: RelatedMemoryRetrieving = RelatedMemoryService(),
        routingPolicyEngine: QuickAssistRoutingPolicyEvaluating = QuickAssistRoutingPolicyEngine(),
        evidencePackBuilder: QuickAssistEvidencePackBuilding = QuickAssistEvidencePackBuilder(),
        answerVerifier: QuickAssistAnswerVerifying = QuickAssistAnswerVerifier(),
        recoveryPlanner: QuickAssistRecoveryPlanning = QuickAssistRecoveryPlanner(),
        experimentRunner: QuickAssistExperimentRunning = QuickAssistExperimentRunner(),
        policyCalibrator: QuickAssistPolicyCalibrator = QuickAssistPolicyCalibrator(),
        debriefComposer: SessionDebriefComposing? = nil,
        debriefMemoryBridge: DebriefMemoryBridging = DebriefMemoryBridge(),
        sessionFocusLoader: SessionFocusLoading = SessionFocusLoader(),
        skillProgressionTracker: SkillProgressionTracking = SkillProgressionTracker(),
        crossSessionCoach: CrossSessionCoachEvaluating = CrossSessionCoachEvaluator(),
        overlayNavigator: OverlayNavigating? = nil,
        logger: SessionLogger = .shared,
        audioService: AudioCaptureService = .shared,
        sessionResumeService: SessionResuming = SessionResumeService.shared,
        startAudioCapture: (@MainActor (AudioCaptureService.StartReason) -> Void)? = nil
    ) {
        self.logger = logger
        self.audioService = audioService
        self.sessionResumeService = sessionResumeService
        self.startAudioCapture = startAudioCapture ?? { audioService.requestStart(reason: $0) }
        self.injectedOverlayNavigator = overlayNavigator
        self.workstreamTimelineRepository = workstreamTimelineRepository
        self.sessionModeContextResolver = sessionModeContextResolver
        self.quickAssistToolAvailabilityResolver = quickAssistToolAvailabilityResolver
        self.proactiveFailureCoachEngine = proactiveFailureCoachEngine
        self.datasetProfiler = datasetProfiler
        self.responseVoiceGuard = responseVoiceGuard
        self.relatedMemoryService = relatedMemoryService
        self.routingPolicyEngine = routingPolicyEngine
        self.evidencePackBuilder = evidencePackBuilder
        self.answerVerifier = answerVerifier
        self.recoveryPlanner = recoveryPlanner
        self.experimentRunner = experimentRunner
        self.policyCalibrator = policyCalibrator
        // AISessionDebriefComposer wired after aiProvider is loaded
        self.usesDefaultDebriefComposer = debriefComposer == nil
        self.debriefComposer = debriefComposer ?? TemplateSessionDebriefComposer()
        self.debriefMemoryBridge = debriefMemoryBridge
        self.sessionFocusLoader = sessionFocusLoader
        self.skillProgressionTracker = skillProgressionTracker
        self.crossSessionCoach = crossSessionCoach
        setupBindings()
        loadProviderSettings()
    }
    @MainActor
    func updateSessionResponse(
        _ response: MentorResponse?,
        precomputedParsedSystemDesign: SystemDesignContent? = nil
    ) {
        session.response = response

        guard let response else {
            parsedSystemDesignContent = nil
            return
        }

        let rawSystemDesign = response.systemDesign.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawSystemDesign.isEmpty else {
            parsedSystemDesignContent = nil
            return
        }

        if let precomputedParsedSystemDesign {
            parsedSystemDesignContent = precomputedParsedSystemDesign
            return
        }

        parsedSystemDesignContent = response.parsedSystemDesign
    }
}
