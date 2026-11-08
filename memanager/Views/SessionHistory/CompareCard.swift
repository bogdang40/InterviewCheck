import SwiftUI

/// Thread compare folded away by default: pick two threads, compare, and
/// read the highlights with both metric columns.
struct CompareCard: View {
    @ObservedObject private var controller = SessionController.shared
    let availableThreads: [QuickAssistThreadSummary]

    @State private var isExpanded = false
    @State private var leftThreadId: String?
    @State private var rightThreadId: String?
    @State private var comparison: WorkstreamThreadComparison?

    private var canCompare: Bool {
        guard let leftThreadId, let rightThreadId else { return false }
        return leftThreadId != rightThreadId
    }

    var body: some View {
        DisclosureCard("Thread compare", systemImage: "arrow.left.arrow.right", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                if availableThreads.count < 2 {
                    Text("Two threads are needed before they can be compared.")
                        .font(OverlayType.caption)
                        .foregroundStyle(OverlayPalette.textTertiary)
                } else {
                    pickers
                    if let comparison {
                        CompareResultView(comparison: comparison)
                    }
                }
            }
        }
        .onChange(of: leftThreadId) { _, _ in comparison = nil }
        .onChange(of: rightThreadId) { _, _ in comparison = nil }
        .onChange(of: availableThreads.map(\.id)) { _, ids in
            if let leftThreadId, !ids.contains(leftThreadId) { self.leftThreadId = nil }
            if let rightThreadId, !ids.contains(rightThreadId) { self.rightThreadId = nil }
        }
    }

    private var pickers: some View {
        WrappingFlowLayout(spacing: DesignTokens.Spacing.sm) {
            threadMenu(label: "Left", selection: $leftThreadId)
            threadMenu(label: "Right", selection: $rightThreadId)
            Button("Compare", action: compare)
                .buttonStyle(.overlay(.secondary, size: .small))
                .disabled(!canCompare)
        }
    }

    private func threadMenu(label: String, selection: Binding<String?>) -> some View {
        let title = availableThreads.first { $0.id == selection.wrappedValue }?.title ?? label
        return OverlayMenuButton(title: title) {
            ForEach(availableThreads) { thread in
                Button(thread.title) {
                    selection.wrappedValue = thread.id
                }
            }
        }
    }

    private func compare() {
        guard let leftThreadId, let rightThreadId, canCompare else {
            comparison = nil
            return
        }
        comparison = controller.compareQuickAssistThreads(leftThreadID: leftThreadId, rightThreadID: rightThreadId)
    }
}
