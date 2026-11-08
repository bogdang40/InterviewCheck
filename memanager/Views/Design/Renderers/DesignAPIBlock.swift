import SwiftUI

/// Endpoints are selected locally so request and response bodies remain
/// readable instead of disappearing into a compact summary row.
struct DesignAPIBlock: View {
    let apiDesign: APIDesignBlock
    let fontSize: CGFloat
    @State private var selectedIndex = 0

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            DesignProseBlock(text: apiDesign.description, fontSize: fontSize)
            if !apiDesign.endpoints.isEmpty {
                SegmentStrip(items: apiDesign.endpoints.enumerated().map {
                    SegmentItem(id: $0.offset, title: "\($0.element.method.uppercased()) \($0.element.path)")
                }, selection: $selectedIndex)
                let endpoint = apiDesign.endpoints[min(selectedIndex, apiDesign.endpoints.count - 1)]
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                    Text("\(endpoint.method.uppercased()) \(endpoint.path)")
                        .font(OverlayType.mono).foregroundStyle(OverlayPalette.textPrimary)
                        .textSelection(.enabled)
                    DesignProseBlock(text: endpoint.description, fontSize: fontSize)
                    if let request = endpoint.requestBody, !request.isEmpty {
                        CodeBlockView(code: request, language: "json", label: "Request")
                    }
                    if let response = endpoint.responseBody, !response.isEmpty {
                        CodeBlockView(code: response, language: "json", label: "Response")
                    }
                }
                .padding(.vertical, DesignTokens.Spacing.sm)
            }
        }
        .onChange(of: apiDesign.endpoints.count) { _, count in
            selectedIndex = min(selectedIndex, max(0, count - 1))
        }
    }
}
