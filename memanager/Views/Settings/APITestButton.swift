import SwiftUI

/// Progress and outcome of one connection test.
struct APITestState {
    var isLoading = false
    var result: APITestResult?
    private(set) var requestID: UUID?

    mutating func begin() -> UUID {
        let id = UUID()
        requestID = id
        isLoading = true
        result = nil
        return id
    }

    mutating func finish(_ result: APITestResult, requestID: UUID) {
        guard self.requestID == requestID else { return }
        self.result = result
        isLoading = false
    }

    mutating func invalidate() {
        requestID = nil
        result = nil
        isLoading = false
    }
}

/// A connection test the row can run: its label and the request to send.
struct APITestSlot: Identifiable {
    let id: String
    let label: String
    let state: Binding<APITestState>
    var isEnabled = true
    let run: () async -> APITestResult
}

/// Button that runs one test, showing a spinner while it is in flight.
struct APITestButton: View {
    let label: String
    @Binding var state: APITestState
    var isEnabled = true
    let run: () async -> APITestResult

    var body: some View {
        Button(action: start) {
            HStack(spacing: 6) {
                if state.isLoading {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "bolt.horizontal")
                }
                Text(state.isLoading ? "Testing" : label)
            }
        }
        .buttonStyle(.overlay(.secondary, size: .small))
        .disabled(state.isLoading || !isEnabled)
    }

    private func start() {
        guard isEnabled, !state.isLoading else { return }
        let requestID = state.begin()
        Task {
            let result = await run()
            await MainActor.run {
                state.finish(result, requestID: requestID)
            }
        }
    }
}

/// The outcome of a test as a banner: success or failure, elapsed time,
/// the server's message, and the model that answered.
struct APITestResultBanner: View {
    let result: APITestResult

    private var title: String {
        let seconds = String(format: "%.1fs", result.responseTime)
        return result.success ? "Connected in \(seconds)" : "Failed after \(seconds)"
    }

    private var message: String {
        guard let model = result.modelInfo, !model.isEmpty else { return result.message }
        return "\(result.message) Model: \(model)."
    }

    var body: some View {
        ToneBanner(tone: result.success ? .success : .critical, title: title, message: message)
    }
}

/// Row offering one or more connection tests with their results beneath.
struct APITestRow: View {
    @Environment(\.settingsBreakpoint) private var breakpoint
    var title = "Connection"
    var helper: String? = "Sends a small request with the saved key and model."
    let tests: [APITestSlot]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(title: title, helper: helper, layout: .adaptive) {
                let layout = breakpoint == .compact
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: DesignTokens.Spacing.sm))
                    : AnyLayout(HStackLayout(spacing: DesignTokens.Spacing.sm))
                layout {
                    ForEach(tests) { test in
                        APITestButton(label: test.label, state: test.state, isEnabled: test.isEnabled, run: test.run)
                    }
                }
            }
            ForEach(tests) { test in
                if let result = test.state.wrappedValue.result {
                    APITestResultBanner(result: result)
                        .padding(.horizontal, DesignTokens.Spacing.md)
                        .padding(.bottom, DesignTokens.Spacing.sm)
                }
            }
        }
    }
}
