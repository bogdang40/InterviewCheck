import SwiftUI

/// Plan and build: one mode strip, then the step list, the finished code,
/// or the spoken script. The host owns the scroll view; nothing here does.
struct ImplementationSectionView: View {
    enum ViewMode: String, CaseIterable, Hashable {
        case progressive
        case fullCode
        case script

        var title: String {
            switch self {
            case .progressive: return "Step by step"
            case .fullCode: return "Full code"
            case .script: return "Script"
            }
        }

        var systemImage: String {
            switch self {
            case .progressive: return "list.number"
            case .fullCode: return "doc.text"
            case .script: return "text.alignleft"
            }
        }
    }

    let content: ImplementationContent
    @ObservedObject private var settings = SettingsManager.shared
    @State private var viewMode: ViewMode

    init(content: ImplementationContent, initialMode: ViewMode = .progressive) {
        self.content = content
        _viewMode = State(initialValue: initialMode)
    }

    private var modeItems: [SegmentItem<ViewMode>] {
        ViewMode.allCases.map { mode in
            SegmentItem(id: mode, title: mode.title, systemImage: mode.systemImage)
        }
    }

    var body: some View {
        if content.hasStructuredSteps {
            structured
        } else if content.hasContent {
            fallback
        } else {
            Text("No implementation yet.")
                .font(OverlayType.body)
                .foregroundStyle(OverlayPalette.textSecondary)
        }
    }

    private var structured: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            modeStrip

            switch viewMode {
            case .progressive:
                ImplementationStepList(content: content, fontSize: settings.fontSize)
            case .fullCode:
                ImplementationFullCodeView(content: content)
            case .script:
                ImplementationScriptView(content: content)
            }
        }
    }

    private var modeStrip: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            SegmentStrip(items: modeItems, selection: $viewMode)
            Spacer(minLength: 0)
            Text("\(content.steps.count) steps")
                .font(OverlayType.caption)
                .foregroundStyle(OverlayPalette.textTertiary)
                .lineLimit(1)
        }
    }

    private var fallback: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            ToneBanner(tone: .info, message: "Step parsing was unavailable, so this is the raw answer.")
            SpeakableMarkdownView(
                text: content.rawContent,
                fontSize: settings.fontSize,
                showChunkIndicators: true,
                chunkTrackingMode: .teleprompter
            )
        }
    }
}
