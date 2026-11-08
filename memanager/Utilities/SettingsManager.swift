import Foundation

final class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    let defaults = AppDefaults.standard
    private let borderShaderConfigurationStore = BorderShaderConfigurationStore(defaults: AppDefaults.standard)
    let keyPrefix = "memanager."
    let providerCredentials = ProviderCredentials()

    // MARK: - Provider Settings

    @Published private(set) var providerConfigurationVersion: Int = 0

    @Published var selectedProvider: AIProviderType {
        didSet {
            defaults.set(selectedProvider.rawValue, forKey: keyPrefix + "selectedProvider")
            bumpProviderConfigurationVersion()
        }
    }

    // MARK: - Appearance Settings

    @Published var overlayAppearance: OverlayAppearance {
        didSet {
            defaults.set(overlayAppearance.rawValue, forKey: keyPrefix + "overlayAppearance")
        }
    }

    @Published var borderShaderStyle: BorderShaderStyle {
        didSet {
            defaults.set(borderShaderStyle.rawValue, forKey: keyPrefix + "borderShaderStyle")
        }
    }

    @Published private(set) var glassBorderConfiguration: BorderShaderConfiguration
    @Published private(set) var liquidBorderConfiguration: BorderShaderConfiguration

    func updateConfiguration(_ configuration: BorderShaderConfiguration, for style: BorderShaderStyle) {
        do {
            guard let valid = try borderShaderConfigurationStore.save(configuration, for: style) else { return }
            switch style {
            case .glass: glassBorderConfiguration = valid
            case .liquid: liquidBorderConfiguration = valid
            case .none: break
            }
        } catch {
            NSLog("[SettingsManager] Failed to save %@ border configuration: %@", style.rawValue, error.localizedDescription)
        }
    }

    @Published var overlayOpacity: Double {
        didSet {
            defaults.set(overlayOpacity, forKey: keyPrefix + "overlayOpacity")
        }
    }

    @Published var fontSize: Double {
        didSet {
            defaults.set(fontSize, forKey: keyPrefix + "fontSize")
        }
    }

    @Published var overlayWidth: CGFloat {
        didSet {
            defaults.set(overlayWidth, forKey: keyPrefix + "overlayWidth")
        }
    }

    @Published var overlayAnchorEdge: OverlayAnchorEdge {
        didSet {
            defaults.set(overlayAnchorEdge.rawValue, forKey: keyPrefix + "overlayAnchorEdge")
        }
    }

    @Published var captureSystemAudio: Bool {
        didSet {
            defaults.set(captureSystemAudio, forKey: keyPrefix + "captureSystemAudio")
        }
    }

    @Published var showDiagnosticsOverlay: Bool {
        didSet {
            defaults.set(showDiagnosticsOverlay, forKey: keyPrefix + "showDiagnosticsOverlay")
        }
    }

    @Published var forceAppleSpeech: Bool {
        didSet {
            defaults.set(forceAppleSpeech, forKey: keyPrefix + "forceAppleSpeech")
        }
    }

    @Published var hubRouterEnabled: Bool {
        didSet {
            defaults.set(hubRouterEnabled, forKey: keyPrefix + "hubRouterEnabled")
        }
    }

    @Published var hubMemoryEnabled: Bool {
        didSet {
            defaults.set(hubMemoryEnabled, forKey: keyPrefix + "hubMemoryEnabled")
        }
    }

    // MARK: - Job Workspaces, Knowledge Graph, Access

    /// Inject the active Job Workspace brief into Quick Assist prompts.
    @Published var workspaceContextEnabled: Bool {
        didSet {
            defaults.set(workspaceContextEnabled, forKey: keyPrefix + "workspaceContextEnabled")
        }
    }

    /// Append a journal entry to the active workspace after each Quick Assist turn.
    @Published var workspaceJournalAutoRecordEnabled: Bool {
        didSet {
            defaults.set(workspaceJournalAutoRecordEnabled, forKey: keyPrefix + "workspaceJournalAutoRecordEnabled")
        }
    }

    /// Retrieve facts from the personal knowledge graph for Quick Assist prompts.
    @Published var knowledgeContextEnabled: Bool {
        didSet {
            defaults.set(knowledgeContextEnabled, forKey: keyPrefix + "knowledgeContextEnabled")
        }
    }

    /// Extract entities and relations from finished turns with an extra model call.
    @Published var knowledgeAutoExtractEnabled: Bool {
        didSet {
            defaults.set(knowledgeAutoExtractEnabled, forKey: keyPrefix + "knowledgeAutoExtractEnabled")
        }
    }

    /// Origin of the memanager access server (accounts, subscriptions, admin).
    @Published var accessServerBaseURL: String {
        didSet {
            defaults.set(accessServerBaseURL, forKey: keyPrefix + "accessServerBaseURL")
        }
    }

    @Published var hubProactiveNudgesEnabled: Bool {
        didSet {
            defaults.set(hubProactiveNudgesEnabled, forKey: keyPrefix + "hubProactiveNudgesEnabled")
        }
    }

    /// Feature 1 (Pacing Director): when disabled, the pacing overlay bar
    /// collapses and the pacing directive is not appended to Quick Assist
    /// prompts. The director itself keeps running so re-enabling is instant.
    @Published var pacingDirectorEnabled: Bool {
        didSet {
            defaults.set(pacingDirectorEnabled, forKey: keyPrefix + "pacingDirectorEnabled")
        }
    }

    /// Feature 2 (Live Reasoning Canvas): controls whether the visual canvas
    /// pane renders. The parser and director run regardless so the scene is
    /// always up-to-date when the user toggles the pane back on.
    @Published var canvasModeEnabled: Bool {
        didSet {
            defaults.set(canvasModeEnabled, forKey: keyPrefix + "canvasModeEnabled")
        }
    }

    /// Feature 3 (Deliberate Practice Studio): controls whether new decks are
    /// authored at session end and whether the Studio entry point is visible
    /// in the main overlay.
    @Published var practiceStudioEnabled: Bool {
        didSet {
            defaults.set(practiceStudioEnabled, forKey: keyPrefix + "practiceStudioEnabled")
        }
    }

    @Published var hubFailureCoachEnabled: Bool {
        didSet {
            defaults.set(hubFailureCoachEnabled, forKey: keyPrefix + "hubFailureCoachEnabled")
        }
    }

    @Published var hubFailureCoachAutoOpenTimeline: Bool {
        didSet {
            defaults.set(hubFailureCoachAutoOpenTimeline, forKey: keyPrefix + "hubFailureCoachAutoOpenTimeline")
        }
    }

    @Published var quickAssistAutoCompareEnabled: Bool {
        didSet {
            defaults.set(quickAssistAutoCompareEnabled, forKey: keyPrefix + "quickAssistAutoCompareEnabled")
        }
    }

    @Published var sessionAutoDebriefEnabled: Bool {
        didSet {
            defaults.set(sessionAutoDebriefEnabled, forKey: keyPrefix + "sessionAutoDebriefEnabled")
        }
    }

    @Published var sessionReplayStorageEnabled: Bool {
        didSet {
            defaults.set(sessionReplayStorageEnabled, forKey: keyPrefix + "sessionReplayStorageEnabled")
        }
    }

    @Published var openAIVoiceGuardEnabled: Bool {
        didSet {
            defaults.set(openAIVoiceGuardEnabled, forKey: keyPrefix + "openAIVoiceGuardEnabled")
        }
    }

    @Published var openAIQuickAssistDisplayMode: OpenAIQuickAssistDisplayMode {
        didSet {
            defaults.set(openAIQuickAssistDisplayMode.rawValue, forKey: keyPrefix + "openAIQuickAssistDisplayMode")
        }
    }

    @Published var quickAssistInteractionMode: QuickAssistInteractionMode {
        didSet {
            defaults.set(quickAssistInteractionMode.rawValue, forKey: keyPrefix + "quickAssistInteractionMode")
        }
    }

    // MARK: - Coding Preferences

    @Published var preferredLanguage: ProgrammingLanguage {
        didSet {
            defaults.set(preferredLanguage.rawValue, forKey: keyPrefix + "preferredLanguage")
        }
    }

    // MARK: - Quick Assist Prompts

    @Published private(set) var quickAssistPrompts: [QuickAssistPrompt] = []
    @Published private(set) var activeQuickAssistPromptID: UUID?

    // MARK: - ML Guide Prompts (separate from Quick Assist)
    
    @Published private(set) var mlGuidePrompts: [QuickAssistPrompt] = []
    @Published private(set) var activeMLGuidePromptID: UUID?

    // MARK: - Voice Signature Settings

    let voiceSignatureStore = VoiceSignatureStore.shared

    @Published var voiceSignatureEnabled: Bool {
        didSet {
            voiceSignatureStore.isEnabled = voiceSignatureEnabled
        }
    }

    @Published var thresholdEnterMe: Double {
        didSet {
            voiceSignatureStore.thresholdEnterMe = Float(thresholdEnterMe)
        }
    }

    @Published var thresholdExitMe: Double {
        didSet {
            voiceSignatureStore.thresholdExitMe = Float(thresholdExitMe)
        }
    }

    // MARK: - Initialization

    private init() {
        let keyPrefix = "memanager."

        let appearance = AppearancePreferences(defaults: defaults)
        let savedAnchorEdge = defaults.string(forKey: keyPrefix + "overlayAnchorEdge")
        let savedCaptureSystemAudio = defaults.bool(forKey: keyPrefix + "captureSystemAudio")

        // Load saved provider or default to Claude
        if let savedProvider = defaults.string(forKey: keyPrefix + "selectedProvider"),
           let provider = AIProviderType(rawValue: savedProvider) {
            selectedProvider = provider
        } else {
            selectedProvider = .claude
        }

        // Initialize appearance settings with defaults if needed
        overlayAppearance = .restored(from: defaults.string(forKey: keyPrefix + "overlayAppearance"))
        borderShaderStyle = .restored(from: defaults.string(forKey: keyPrefix + "borderShaderStyle"))
        glassBorderConfiguration = borderShaderConfigurationStore.load(for: .glass) ?? .glassDefault
        liquidBorderConfiguration = borderShaderConfigurationStore.load(for: .liquid) ?? .liquidDefault
        overlayOpacity = appearance.opacity
        fontSize = appearance.fontSize
        overlayWidth = appearance.width
        overlayAnchorEdge = OverlayAnchorEdge(rawValue: savedAnchorEdge ?? "") ?? .left
        // Default to true for system audio capture (captures Zoom/Teams/other apps)
        // UserDefaults.bool returns false for unset keys, so we check if the key exists
        captureSystemAudio = defaults.object(forKey: keyPrefix + "captureSystemAudio") == nil
            ? true
            : savedCaptureSystemAudio
        showDiagnosticsOverlay = defaults.bool(forKey: keyPrefix + "showDiagnosticsOverlay")
        forceAppleSpeech = defaults.bool(forKey: keyPrefix + "forceAppleSpeech")
        hubRouterEnabled = defaults.object(forKey: keyPrefix + "hubRouterEnabled") as? Bool ?? true
        hubMemoryEnabled = defaults.object(forKey: keyPrefix + "hubMemoryEnabled") as? Bool ?? true
        workspaceContextEnabled = defaults.object(forKey: keyPrefix + "workspaceContextEnabled") as? Bool ?? true
        workspaceJournalAutoRecordEnabled = defaults.object(forKey: keyPrefix + "workspaceJournalAutoRecordEnabled") as? Bool ?? true
        knowledgeContextEnabled = defaults.object(forKey: keyPrefix + "knowledgeContextEnabled") as? Bool ?? true
        knowledgeAutoExtractEnabled = defaults.object(forKey: keyPrefix + "knowledgeAutoExtractEnabled") as? Bool ?? false
        accessServerBaseURL = defaults.string(forKey: keyPrefix + "accessServerBaseURL") ?? SettingsManager.defaultAccessServerBaseURL
        hubProactiveNudgesEnabled = defaults.object(forKey: keyPrefix + "hubProactiveNudgesEnabled") as? Bool ?? false
        pacingDirectorEnabled = defaults.object(forKey: keyPrefix + "pacingDirectorEnabled") as? Bool ?? true
        canvasModeEnabled = defaults.object(forKey: keyPrefix + "canvasModeEnabled") as? Bool ?? true
        practiceStudioEnabled = defaults.object(forKey: keyPrefix + "practiceStudioEnabled") as? Bool ?? true
        hubFailureCoachEnabled = defaults.object(forKey: keyPrefix + "hubFailureCoachEnabled") as? Bool ?? true
        hubFailureCoachAutoOpenTimeline = defaults.object(forKey: keyPrefix + "hubFailureCoachAutoOpenTimeline") as? Bool ?? false
        quickAssistAutoCompareEnabled = defaults.object(forKey: keyPrefix + "quickAssistAutoCompareEnabled") as? Bool ?? false
        sessionAutoDebriefEnabled = defaults.object(forKey: keyPrefix + "sessionAutoDebriefEnabled") as? Bool ?? false
        sessionReplayStorageEnabled = defaults.object(forKey: keyPrefix + "sessionReplayStorageEnabled") as? Bool ?? false
        openAIVoiceGuardEnabled = defaults.object(forKey: keyPrefix + "openAIVoiceGuardEnabled") as? Bool ?? true
        openAIQuickAssistDisplayMode = OpenAIQuickAssistDisplayMode(rawValue: defaults.string(forKey: keyPrefix + "openAIQuickAssistDisplayMode") ?? "") ?? .guarded
        quickAssistInteractionMode = QuickAssistInteractionMode(rawValue: defaults.string(forKey: keyPrefix + "quickAssistInteractionMode") ?? "") ?? .technical

        // Load preferred programming language (default to C++ for coding interviews)
        if let savedLanguage = defaults.string(forKey: keyPrefix + "preferredLanguage"),
           let language = ProgrammingLanguage(rawValue: savedLanguage) {
            preferredLanguage = language
        } else {
            preferredLanguage = .cpp  // Default to C++ for coding interviews
        }

        // Load voice signature settings from VoiceSignatureStore
        voiceSignatureEnabled = voiceSignatureStore.isEnabled
        thresholdEnterMe = Double(voiceSignatureStore.thresholdEnterMe)
        thresholdExitMe = Double(voiceSignatureStore.thresholdExitMe)

        loadQuickAssistPrompts()
        loadMLGuidePrompts()

        // Migrate legacy Quick Assist prompts into the Mode store on first launch.
        ModeMigrator.runIfNeeded(defaults: defaults)
        providerCredentials.onChange = { [weak self] in self?.bumpProviderConfigurationVersion() }
        providerCredentials.reload()
    }

    func setQuickAssistPrompts(_ prompts: [QuickAssistPrompt], activeID: UUID?) {
        quickAssistPrompts = prompts
        if let activeID, prompts.contains(where: { $0.id == activeID }) {
            activeQuickAssistPromptID = activeID
        } else {
            activeQuickAssistPromptID = prompts.first?.id
        }
        persistQuickAssistPrompts()
    }

    func setMLGuidePrompts(_ prompts: [QuickAssistPrompt], activeID: UUID?) {
        mlGuidePrompts = prompts
        if let activeID, prompts.contains(where: { $0.id == activeID }) {
            activeMLGuidePromptID = activeID
        } else {
            activeMLGuidePromptID = prompts.first?.id
        }
        persistMLGuidePrompts()
    }

    private func loadMLGuidePrompts() {
        if let data = defaults.data(forKey: Self.mlGuidePromptsKey),
           let decoded = try? JSONDecoder().decode([QuickAssistPrompt].self, from: data) {
            mlGuidePrompts = decoded
        } else {
            mlGuidePrompts = [
                QuickAssistPrompt(title: "Default", prompt: "")
            ]
        }

        if let rawID = defaults.string(forKey: Self.mlGuideActivePromptKey),
           let id = UUID(uuidString: rawID),
           mlGuidePrompts.contains(where: { $0.id == id }) {
            activeMLGuidePromptID = id
        } else {
            activeMLGuidePromptID = mlGuidePrompts.first?.id
        }
    }

    private func loadQuickAssistPrompts() {
        if let data = defaults.data(forKey: Self.quickAssistPromptsKey),
           let decoded = try? JSONDecoder().decode([QuickAssistPrompt].self, from: data) {
            quickAssistPrompts = decoded
        } else {
            quickAssistPrompts = [
                QuickAssistPrompt(title: "Default", prompt: "")
            ]
        }

        if let rawID = defaults.string(forKey: Self.quickAssistActivePromptKey),
           let id = UUID(uuidString: rawID),
           quickAssistPrompts.contains(where: { $0.id == id }) {
            activeQuickAssistPromptID = id
        } else {
            activeQuickAssistPromptID = quickAssistPrompts.first?.id
        }
    }

    func bumpProviderConfigurationVersion() {
        providerConfigurationVersion &+= 1
    }
}
