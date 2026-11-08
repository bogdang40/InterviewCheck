import SwiftUI

/// One Solve section: a slim header with the stage name and the advice
/// for it, then the section renderer inside a reading width column.
struct SolveSectionContent: View {
    let section: MentorResponse.Section
    let response: MentorResponse
    let isStreaming: Bool
    let width: CGFloat

    @ObservedObject private var controller = SessionController.shared

    private var text: String {
        response.content(for: section).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                    ScrollViewRegistrar(target: .main)
                        .frame(width: 0, height: 0)

                    header

                    if text.isEmpty {
                        sectionPending
                    } else {
                        renderer
                    }
                }
                .padding(OverlayLayout.stageInset)
                .frame(maxWidth: OverlayLayout.readingWidth(for: width) + 2 * OverlayLayout.stageInset, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .onChange(of: controller.systemDesignSectionIndex) { _, index in
                scrollToDesignSection(at: index, proxy: proxy)
            }
        }
    }

    /// The design section cards carry their blueprint id, so a hotkey or
    /// phase rail change brings the active card to the top.
    private func scrollToDesignSection(at index: Int, proxy: ScrollViewProxy) {
        guard section == .systemDesign else { return }
        let content = controller.parsedSystemDesignContent ?? response.parsedSystemDesign
        let ids = DesignPhaseCatalog.availableSectionIDs(in: content)
        guard ids.indices.contains(index) else { return }
        withAnimation(DesignTokens.Motion.sectionExpand) {
            proxy.scrollTo(ids[index], anchor: .top)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text(section == .tests ? "Suggested checks" : section.title)
                .font(OverlayType.title)
                .foregroundStyle(OverlayPalette.textPrimary)
            Text(SolveSectionGuide.advice(for: section))
                .font(OverlayType.caption)
                .foregroundStyle(OverlayPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if isStreaming {
                ToneBadge(text: "Generating", tone: .info, systemImage: "arrow.triangle.2.circlepath")
            }
        }
    }

    private var sectionPending: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            if isStreaming {
                ProgressView().controlSize(.small)
                Text("This section is still being written.")
            } else {
                Text("The answer did not include this section.")
            }
        }
        .font(OverlayType.body)
        .foregroundStyle(OverlayPalette.textSecondary)
        .padding(.top, DesignTokens.Spacing.sm)
    }

    @ViewBuilder
    private var renderer: some View {
        switch section {
        case .problem:
            ProblemSectionView(content: response.parsedProblem)
        case .clarifyingQuestions:
            QuestionsSectionView(content: response.parsedQuestions)
        case .implementation:
            ImplementationSectionView(content: response.parsedImplementation)
        case .tests:
            TestsSectionView(content: response.parsedTests)
        case .complexity:
            ComplexitySectionView(content: response.parsedComplexity)
        case .systemDesign:
            if let message = controller.systemDesignContextStatusMessage {
                ToneBanner(tone: .warning, message: message)
            }
            SystemDesignSectionView(content: controller.parsedSystemDesignContent ?? response.parsedSystemDesign)
        }
    }
}
