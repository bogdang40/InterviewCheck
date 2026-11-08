import SwiftUI

/// Markdown with fenced blocks split out: prose goes through
/// `MarkdownText`, code through the unified code block, and mermaid fences
/// through the diagram views.
struct MarkdownRenderer: View {
    let text: String
    let fontSize: CGFloat
    let mermaidDisplayMode: MermaidDisplayMode

    init(
        text: String,
        fontSize: CGFloat = 14,
        mermaidDisplayMode: MermaidDisplayMode = .standard
    ) {
        self.text = text
        self.fontSize = fontSize
        self.mermaidDisplayMode = mermaidDisplayMode
    }

    private var segments: [FencedMarkdownSegment] {
        FencedMarkdownParser.parse(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            ForEach(segments) { segment in
                switch segment.kind {
                case .text(let value):
                    if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        MarkdownText(value, fontSize: fontSize)
                            .foregroundStyle(OverlayPalette.textPrimary)
                    }
                case .code(let languageHint, let code):
                    FencedMarkdownBlockView(
                        languageHint: languageHint,
                        code: code,
                        fontSize: fontSize,
                        mermaidDisplayMode: mermaidDisplayMode
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum MermaidDisplayMode: Equatable {
    case standard
    case adaptiveQuickAssist
}

/// Whether a mermaid block boots its WKWebView now or shows a lightweight
/// placeholder (used while the response is still streaming).
enum MermaidActivation: Equatable {
    case immediate
    case placeholder
}

struct FencedMarkdownBlockView: View {
    let languageHint: String?
    let code: String
    let fontSize: CGFloat
    let mermaidHeight: CGFloat
    let mermaidRenderPolicy: MermaidRenderPolicy
    let mermaidDisplayMode: MermaidDisplayMode
    let mermaidRenderSeed: String?
    let mermaidActivation: MermaidActivation

    init(
        languageHint: String?,
        code: String,
        fontSize: CGFloat,
        mermaidHeight: CGFloat = 300,
        mermaidRenderPolicy: MermaidRenderPolicy = .immediate,
        mermaidDisplayMode: MermaidDisplayMode = .standard,
        mermaidRenderSeed: String? = nil,
        mermaidActivation: MermaidActivation = .immediate
    ) {
        self.languageHint = languageHint
        self.code = code
        self.fontSize = fontSize
        self.mermaidHeight = mermaidHeight
        self.mermaidRenderPolicy = mermaidRenderPolicy
        self.mermaidDisplayMode = mermaidDisplayMode
        self.mermaidRenderSeed = mermaidRenderSeed
        self.mermaidActivation = mermaidActivation
    }

    private var diagramShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
    }

    var body: some View {
        if FencedMarkdownLanguageClassifier.isMermaidLanguage(languageHint) {
            if mermaidActivation == .placeholder {
                MermaidPlaceholderCard(height: mermaidHeight)
            } else {
                Group {
                    if mermaidDisplayMode == .adaptiveQuickAssist {
                        AdaptiveMermaidDiagramView(
                            diagram: code,
                            height: mermaidHeight,
                            renderPolicy: mermaidRenderPolicy,
                            splitProfile: .quickAssistAggressive
                        )
                    } else {
                        MermaidDiagramView(
                            diagram: code,
                            height: mermaidHeight,
                            renderPolicy: mermaidRenderPolicy
                        )
                    }
                }
                .id(mermaidViewIdentity)
                .clipShape(diagramShape)
                .overlay(diagramShape.stroke(OverlayPalette.hairline, lineWidth: 1))
            }
        } else {
            CodeBlockView(
                code: code,
                language: FencedMarkdownLanguageClassifier.primaryLanguage(from: languageHint),
                fontSize: fontSize
            )
        }
    }

    private var mermaidViewIdentity: String {
        let seedPrefix: String
        if let mermaidRenderSeed, !mermaidRenderSeed.isEmpty {
            seedPrefix = mermaidRenderSeed
        } else {
            seedPrefix = "mermaid"
        }
        let codeHash = String(code.hashValue)
        let modeTag = mermaidDisplayMode == .adaptiveQuickAssist ? "qa" : "std"
        return "\(seedPrefix)|\(modeTag)|\(codeHash)"
    }
}
