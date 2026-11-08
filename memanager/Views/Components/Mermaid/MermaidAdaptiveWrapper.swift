import SwiftUI

// Chunking logic lives in MermaidDiagramChunker.swift.

/// SwiftUI container that keeps a mermaid diagram legible: conservative
/// chunking with a stepper, zoom controls, and a fullscreen sheet. The
/// diagram itself sits in the overlay card treatment.
struct AdaptiveMermaidDiagramView: View {
    let diagram: String
    let height: CGFloat
    let renderPolicy: MermaidRenderPolicy
    let splitProfile: MermaidDiagramChunker.SplitProfile

    private let showsFullscreenControl: Bool

    @State private var chunkingResult: MermaidDiagramChunker.Result
    @State private var selectedChunkIndex: Int
    @State private var zoomScale: CGFloat
    @State private var isFullscreenPresented = false

    init(
        diagram: String,
        height: CGFloat = 300,
        renderPolicy: MermaidRenderPolicy = .immediate,
        splitProfile: MermaidDiagramChunker.SplitProfile = .standard,
        initialChunkIndex: Int = 0,
        initialZoomScale: CGFloat = 1.0,
        showsFullscreenControl: Bool = true
    ) {
        self.diagram = diagram
        self.height = height
        self.renderPolicy = renderPolicy
        self.splitProfile = splitProfile
        self.showsFullscreenControl = showsFullscreenControl

        // Memoized: the splitting heuristics used to run on every parent
        // body pass just to seed state, result discarded.
        let initialResult = MermaidContentCaches.chunkingResult(diagram: diagram, profile: splitProfile)
        _chunkingResult = State(initialValue: initialResult)
        let clampedInitialIndex = max(0, min(initialChunkIndex, max(initialResult.chunks.count - 1, 0)))
        _selectedChunkIndex = State(initialValue: clampedInitialIndex)
        _zoomScale = State(initialValue: MermaidZoomPolicy.clamp(initialZoomScale))
    }

    private var safeChunkIndex: Int {
        guard !chunkingResult.chunks.isEmpty else { return 0 }
        return max(0, min(selectedChunkIndex, chunkingResult.chunks.count - 1))
    }

    private var activeChunk: MermaidDiagramChunker.Chunk {
        chunkingResult.chunks[safeChunkIndex]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            MermaidDiagramControls(zoomScale: $zoomScale, showsFullscreenControl: showsFullscreenControl) {
                isFullscreenPresented = true
                SessionLogger.shared.logMermaidEvent(name: "adaptive_fullscreen_open")
            }

            if chunkingResult.chunks.count > 1 {
                MermaidChunkStepper(chunks: chunkingResult.chunks, selectedIndex: safeChunkIndex) { index in
                    selectedChunkIndex = index
                }
            }

            MermaidDiagramView(
                diagram: activeChunk.diagram,
                height: height,
                renderPolicy: renderPolicy,
                zoomScale: zoomScale
            )
            .id(renderIdentity(for: activeChunk))
            .overlayCard(.base, cornerRadius: DesignTokens.Radius.md)
        }
        .onAppear {
            logChunkingEvent(result: chunkingResult)
            if chunkingResult.chunks.count > 1 {
                logStepChangeEvent(name: "adaptive_chunk_step_initial")
            }
        }
        .onChange(of: diagram) { _, newDiagram in
            let nextResult = MermaidContentCaches.chunkingResult(diagram: newDiagram, profile: splitProfile)
            chunkingResult = nextResult
            selectedChunkIndex = max(0, min(selectedChunkIndex, max(nextResult.chunks.count - 1, 0)))
            logChunkingEvent(result: nextResult)
            if nextResult.chunks.count > 1 {
                logStepChangeEvent(name: "adaptive_chunk_step_reset")
            }
        }
        .onChange(of: selectedChunkIndex) { _, _ in
            guard chunkingResult.chunks.count > 1 else { return }
            logStepChangeEvent(name: "adaptive_chunk_step_changed")
        }
        .sheet(isPresented: $isFullscreenPresented) {
            fullscreenSheet
        }
    }

    private var fullscreenSheet: some View {
        AdaptiveMermaidDiagramView(
            diagram: diagram,
            height: max(height, 560),
            renderPolicy: renderPolicy,
            splitProfile: splitProfile,
            initialChunkIndex: safeChunkIndex,
            initialZoomScale: zoomScale,
            showsFullscreenControl: false
        )
        .padding(DesignTokens.Spacing.xxl)
        .frame(minWidth: 960, minHeight: 700)
        .background(OverlayPalette.canvas)
        .overlay(alignment: .topTrailing) {
            Button("Done") {
                isFullscreenPresented = false
            }
            .keyboardShortcut(.escape, modifiers: [])
            .buttonStyle(.overlay(.secondary, size: .small))
            .padding(DesignTokens.Spacing.xxl)
        }
    }

    private func renderIdentity(for chunk: MermaidDiagramChunker.Chunk) -> String {
        "adaptive-\(chunk.id)-zoom-\(MermaidZoomPolicy.percent(zoomScale))"
    }

    private func logChunkingEvent(result: MermaidDiagramChunker.Result) {
        SessionLogger.shared.logMermaidEvent(
            name: "adaptive_chunking",
            details: "didSplit=\(result.didSplit), chunks=\(result.chunks.count), reason=\(result.reason), chars=\(result.metrics.characterCount), lines=\(result.metrics.nonEmptyLineCount), edges=\(result.metrics.edgeLineCount)"
        )
    }

    private func logStepChangeEvent(name: String) {
        let chunk = activeChunk
        SessionLogger.shared.logMermaidEvent(
            name: name,
            details: "step=\(safeChunkIndex + 1)/\(chunkingResult.chunks.count), title=\(chunk.title)"
        )
    }
}
