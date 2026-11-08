import SwiftUI

/// Settings as an overlay screen: a page rail on the left and the selected
/// page on the right. Replaces the separate Settings window so the pages
/// share the stealth overlay's look and its screen capture protection.
struct SettingsScreen: View {
    @ObservedObject private var settings = SettingsManager.shared
    @ObservedObject private var access = AccessController.shared
    @ObservedObject private var navigator = OverlayNavigator.shared
    @State private var previewPane: SettingsPane?
    @State private var providerDraft = AIProviderSettingsDraft()
    @State private var didLoadDraft = false
    @State private var showsReadiness = false

    init(initialPane: SettingsPane? = nil) {
        _previewPane = State(initialValue: initialPane)
    }

    private var selectedPane: Binding<SettingsPane> {
        Binding(get: { previewPane ?? navigator.settingsPane }, set: { pane in
            if previewPane != nil { previewPane = pane } else { navigator.settingsPane = pane }
            showsReadiness = false
        })
    }

    var body: some View {
        GeometryReader { geometry in
            let usesRail = geometry.size.width >= 700
            let contentWidth = geometry.size.width - (usesRail ? SettingsPaneRail.width(showsLabels: true) + 1 : 0)
            VStack(spacing: 0) {
                if !usesRail { compactNavigation }
                HStack(spacing: 0) {
                    if usesRail {
                        VStack(spacing: 0) {
                            SettingsPaneRail(
                                panes: SettingsPane.available(isAdmin: access.isAdmin),
                                selection: selectedPane,
                                showsLabels: true
                            )
                            Button("Session readiness") { showsReadiness = true }
                                .buttonStyle(.overlay(.ghost, size: .small))
                                .padding(DesignTokens.Spacing.sm)
                        }
                        .frame(width: SettingsPaneRail.width(showsLabels: true))
                        Hairline(axis: .vertical)
                    }
                    if showsReadiness {
                        SessionReadinessView(onBack: { showsReadiness = false }, onSelectPane: { selectedPane.wrappedValue = $0 })
                    } else {
                        SettingsPaneHost(
                            pane: selectedPane.wrappedValue,
                            providerDraft: $providerDraft,
                            availableWidth: contentWidth
                        )
                    }
                }
            }
            .environment(\.settingsBreakpoint, OverlayLayout.breakpoint(for: contentWidth))
            .background(OverlayPalette.readingSurface)
        }
        .onAppear {
            if !didLoadDraft { providerDraft.load(from: settings); didLoadDraft = true }
        }
        .onChange(of: settings.providerConfigurationVersion) { _, _ in
            providerDraft.refreshCredentials(from: settings)
        }
        .onChange(of: access.isAdmin) { _, isAdmin in
            if selectedPane.wrappedValue == .admin, !isAdmin { selectedPane.wrappedValue = .account }
        }
        .onChange(of: navigator.settingsPane) { _, _ in showsReadiness = false }
    }

    private var compactNavigation: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Menu {
                ForEach(SettingsPane.available(isAdmin: access.isAdmin)) { pane in
                    Button { selectedPane.wrappedValue = pane } label: {
                        Label(pane.title, systemImage: pane.systemImage)
                    }
                }
            } label: {
                Label(selectedPane.wrappedValue.title, systemImage: selectedPane.wrappedValue.systemImage)
                    .font(OverlayType.callout)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Settings page")
            Spacer(minLength: 0)
            Button("Readiness") { showsReadiness = true }
                .buttonStyle(.overlay(.ghost, size: .small))
        }
        .padding(DesignTokens.Spacing.md)
        .background(OverlayPalette.surface)
    }
}

/// Scrolling column for one pane: the pane's header and content laid out
/// at the reading width so long helper text stays readable.
struct SettingsPaneHost: View {
    let pane: SettingsPane
    @Binding var providerDraft: AIProviderSettingsDraft
    let availableWidth: CGFloat

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xl) {
                SurfaceHeader(pane.title, systemImage: pane.systemImage, subtitle: pane.caption)
                SettingsPaneContent(pane: pane, providerDraft: $providerDraft)
            }
            .frame(maxWidth: 1100, alignment: .leading)
            .padding(OverlayLayout.stageInset)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .id(pane)
    }
}

#if DEBUG && XCODE_RUNNING_FOR_PREVIEWS
#Preview {
    SettingsScreen()
        .frame(width: 800, height: 600)
}
#endif
