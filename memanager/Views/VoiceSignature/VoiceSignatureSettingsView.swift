import SwiftUI

/// The Voice pane: how speakers are told apart, the transcription and
/// recognition keys, the enrolled voice profile, and the thresholds.
struct VoiceSignatureSettingsView: View {
    @ObservedObject private var store = VoiceSignatureStore.shared
    @StateObject private var enrollmentService = VoiceSignatureEnrollmentService()

    @State private var accessKeyEdited = false
    @State private var deepgramKeyEdited = false
    @State private var accessKey: String = ""
    @State private var deepgramApiKey: String = ""
    @State private var selectedPreset: VoiceStrictnessPreset = .balanced
    @State private var isEnrollmentPresented = false
    @State private var isLiveTestPresented = false
    @State private var isDeleteConfirmationPresented = false
    @State private var profileError: String?
    @State private var showsThresholds = false

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xl) {
            VoiceIdentificationSection(store: store)

            if store.useSourceBasedIdentification {
                VoiceEchoFilterSection(store: store)
            } else {
                VoiceLegacyIdentificationSection(store: store)
                VoiceLegacyMixSection(store: store)
            }

            VoiceProviderKeysSection(
                store: store,
                deepgramApiKey: Binding(get: { deepgramApiKey }, set: { value in
                    deepgramKeyEdited = true
                    deepgramApiKey = value
                    store.saveDeepgramApiKey(value)
                }),
                accessKey: Binding(get: { accessKey }, set: { value in
                    accessKeyEdited = true
                    accessKey = value
                    store.saveAccessKey(value)
                })
            )

            VoiceProfileSection(
                store: store,
                onEnroll: { isEnrollmentPresented = true },
                onDelete: { isDeleteConfirmationPresented = true }
            )

            DisclosureCard("Recognition thresholds and test", systemImage: "slider.horizontal.3", isExpanded: $showsThresholds) {
            VoiceThresholdsSection(
                store: store,
                selectedPreset: $selectedPreset,
                onLiveTest: { isLiveTestPresented = true }
            )
            }
            if let profileError { ToneBanner(tone: .critical, message: profileError) }
        }
        .onAppear(perform: loadCurrentSettings)
        .onChange(of: store.accessKeyStatus) { _, _ in hydrateKeys() }
        .onChange(of: store.deepgramApiKeyStatus) { _, _ in hydrateKeys() }
        .sheet(isPresented: $isEnrollmentPresented) {
            EnrollmentWizardView(enrollmentService: enrollmentService)
        }
        .sheet(isPresented: $isLiveTestPresented) {
            LiveTestView()
        }
        .alert("Delete the voice profile?", isPresented: $isDeleteConfirmationPresented) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if store.deleteProfile() {
                    store.isEnabled = false
                    profileError = nil
                } else {
                    profileError = "The voice profile could not be removed from the Keychain. It remains available; try again after checking Keychain access."
                }
            }
        } message: {
            Text("This removes your enrolled voice signature. Enroll again to use voice recognition.")
        }
    }

    private func loadCurrentSettings() {
        hydrateKeys()
        selectedPreset = VoiceStrictnessPreset.from(enter: store.thresholdEnterMe, exit: store.thresholdExitMe)
    }
    private func hydrateKeys() {
        if !accessKeyEdited, store.accessKeyStatus == .configured || store.accessKeyStatus == .notConfigured {
            accessKey = store.loadAccessKey() ?? ""
        }
        if !deepgramKeyEdited, store.deepgramApiKeyStatus == .configured || store.deepgramApiKeyStatus == .notConfigured {
            deepgramApiKey = store.loadDeepgramApiKey() ?? ""
        }
    }
}

#if DEBUG && XCODE_RUNNING_FOR_PREVIEWS
#Preview {
    ScrollView {
        VoiceSignatureSettingsView()
            .padding()
    }
    .frame(width: 560, height: 700)
}
#endif
