import AppKit
import SwiftUI
import XCTest
@testable import memanager

/// Renders every Solve section at the regular and compact widths, plus the
/// implementation modes, to PNG files for visual inspection. Opt in with
/// MEMANAGER_RENDER_SMOKE=1 (TEST_RUNNER_MEMANAGER_RENDER_SMOKE=1 through
/// xcodebuild); files land in MEMANAGER_RENDER_DIR or the temp dir.
@MainActor
final class SolveRenderTests: XCTestCase {
    private static let widths: [CGFloat] = [800, 440]

    override func setUpWithError() throws {
        try super.setUpWithError()
        try OverlayRenderHarness.skipUnlessEnabled()
    }

    func testRenderSolveSectionsAtEveryWidth() async throws {
        let response = OverlayRenderFixtures.codingResponse
        for width in Self.widths {
            for section in MentorSurfaceResolver.solveSections {
                let name = "solve-\(section.title.lowercased())-\(Int(width))"
                try await OverlayRenderHarness.render(name, size: CGSize(width: width, height: 900)) {
                    SolveSectionContent(section: section, response: response, isStreaming: false, width: width)
                }
            }
        }
    }

    func testRenderImplementationModes() async throws {
        let content = OverlayRenderFixtures.codingResponse.parsedImplementation
        let modes: [(String, ImplementationSectionView.ViewMode)] = [
            ("solve-implementation-script", .script),
            ("solve-implementation-fullcode", .fullCode)
        ]
        for (name, mode) in modes {
            for width in Self.widths {
                try await OverlayRenderHarness.render("\(name)-\(Int(width))", size: CGSize(width: width, height: 900)) {
                    ScrollView {
                        ImplementationSectionView(content: content, initialMode: mode)
                            .padding(OverlayLayout.stageInset)
                            .frame(maxWidth: OverlayLayout.readingWidth(for: width) + 2 * OverlayLayout.stageInset, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    func testRenderPopulatedSolveGenerationActions() async throws {
        let controller = SessionController.shared
        let originalResponse = controller.session.response
        let originalSection = controller.currentSection
        let originalLoading = controller.isLoading
        let originalStreaming = controller.isStreaming
        defer {
            controller.session.response = originalResponse
            controller.currentSection = originalSection
            controller.isLoading = originalLoading
            controller.isStreaming = originalStreaming
        }
        controller.session.response = OverlayRenderFixtures.codingResponse
        for section in [MentorResponse.Section.problem, .complexity] {
            controller.currentSection = section
            for busy in [false, true] {
                controller.isLoading = busy
                controller.isStreaming = busy
                for width: CGFloat in [400, 800] {
                    let name = "solve-actions-\(section == .problem ? "first" : "last")-\(busy ? "busy" : "settled")-\(Int(width))"
                    try await OverlayRenderHarness.render(name, size: CGSize(width: width, height: 700), validate: { view in
                        if section == .complexity && width == 400 {
                            try OverlayRenderHarness.assertHorizontalSelectionAtTrailingEdge(in: view)
                        }
                    }) {
                        SolveSurface(width: width)
                    }
                }
            }
        }
    }
}
