import Foundation

/// A provider-neutral piece of user message content.
/// Providers map each piece onto their own private wire-format block type,
/// so the shared assembly logic never leaks provider specifics.
enum AIMessageContentPiece: Equatable {
    case imageBase64(String, mediaType: String)
    case text(String)
}

/// Assembles the ordered image-plus-text content sequence shared by all AI providers.
///
/// Every provider sends the same payload shape for a given flow: all screenshots
/// first (in capture order), followed by exactly one text block whose prompt is
/// produced by PromptBuilder. This type owns that ordering and prompt assembly in
/// one place; each provider keeps only a tiny adapter that maps pieces onto its
/// own wire-format structs.
struct AIMessageContentAssembler {
    /// Default media type for attached screenshots. JPEG for smaller payloads.
    static let defaultImageMediaType = "image/jpeg"

    /// Solve flow content: screenshots, then transcript plus the analysis instruction.
    func solveContent(
        context: SessionContext,
        imageMediaType: String = AIMessageContentAssembler.defaultImageMediaType
    ) -> [AIMessageContentPiece] {
        var content: [AIMessageContentPiece] = []

        // Add screenshots as images
        for base64Image in context.screenshots {
            content.append(.imageBase64(base64Image, mediaType: imageMediaType))
        }

        // Add transcript and instruction
        var textContent = ""
        if !context.transcript.isEmpty {
            textContent += "## Audio Transcript:\n\(context.transcript)\n\n"
        }
        textContent += "Please analyze the above context (screenshots and transcript) and provide a detailed breakdown of the coding problem and solution."

        content.append(.text(textContent))

        return content
    }

    /// System design flow content: screenshots, then the system design user prompt.
    func systemDesignContent(
        context: SessionContext,
        imageMediaType: String = AIMessageContentAssembler.defaultImageMediaType
    ) -> [AIMessageContentPiece] {
        var content: [AIMessageContentPiece] = []

        // Add screenshots as images
        for base64Image in context.screenshots {
            content.append(.imageBase64(base64Image, mediaType: imageMediaType))
        }

        // Add transcript and system design instruction
        let prompt = PromptBuilder.buildSystemDesignUserPrompt(
            transcript: context.transcript,
            hasImages: !context.screenshots.isEmpty,
            contextManifest: context.contextEnvelope?.manifest
        )

        content.append(.text(prompt))

        return content
    }

    /// Quick Assist flow content: screenshots, then the full Quick Assist prompt.
    func quickAssistContent(
        context: QuickAssistContext,
        imageMediaType: String = AIMessageContentAssembler.defaultImageMediaType
    ) -> [AIMessageContentPiece] {
        var content: [AIMessageContentPiece] = []

        for base64Image in context.screenshots {
            content.append(.imageBase64(base64Image, mediaType: imageMediaType))
        }

        let prompt = PromptBuilder.buildQuickAssistPrompt(context: context)
        content.append(.text(prompt))

        return content
    }

    /// ML Guide flow content: screenshots, then the ML Guide user prompt.
    func mlGuideContent(
        context: MLGuideContext,
        imageMediaType: String = AIMessageContentAssembler.defaultImageMediaType
    ) -> [AIMessageContentPiece] {
        var content: [AIMessageContentPiece] = []

        for base64Image in context.screenshots {
            content.append(.imageBase64(base64Image, mediaType: imageMediaType))
        }

        let prompt = PromptBuilder.buildMLGuideUserPrompt(
            transcript: context.transcript,
            question: context.question,
            extraContext: context.extraContext,
            realtimePrompt: context.realtimePrompt,
            hasImages: !context.screenshots.isEmpty,
            previousResponse: context.previousResponse,
            datasetSummary: context.datasetSummary
        )
        content.append(.text(prompt))

        return content
    }
}
