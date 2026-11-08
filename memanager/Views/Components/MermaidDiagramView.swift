import SwiftUI
import WebKit

/// A SwiftUI view that renders Mermaid diagrams using WKWebView
struct MermaidDiagramView: NSViewRepresentable {
    let diagram: String
    let sanitizedDiagram: String
    let retryDiagram: String
    let height: CGFloat
    let zoomScale: CGFloat
    let renderPolicy: MermaidRenderPolicy
    let diagramId: String  // For tracking in logs - stable based on content hash
    @Environment(\.colorScheme) var colorScheme
    
    init(
        diagram: String,
        height: CGFloat = 300,
        renderPolicy: MermaidRenderPolicy = .immediate,
        zoomScale: CGFloat = 1.0
    ) {
        self.diagram = diagram
        // Memoized: sanitizer heuristics, retry repair, and the MD5 identity
        // used to run on every re-init (every parent body pass).
        let derived = MermaidContentCaches.sanitizedContent(for: diagram)
        self.sanitizedDiagram = derived.sanitized
        self.retryDiagram = derived.retry
        self.diagramId = derived.diagramId
        self.height = height
        self.zoomScale = max(0.5, min(2.0, zoomScale))
        self.renderPolicy = renderPolicy
    }
    
    struct MermaidRenderPayload: Codable, Equatable {
        let contextID: String
        let diagramID: String
        let diagramText: String
        let retryDiagramText: String
        let theme: String
        let backgroundColor: String
        let textColor: String
        let zoomScale: Double
        let minHeight: Double
    }

    func makeNSView(context: Context) -> WKWebView {
        let diagramPreview = String(diagram.prefix(50)).replacingOccurrences(of: "\n", with: " ")
        SessionLogger.shared.logMermaidEvent(
            name: "makeNSView",
            details: "id=\(diagramId), height=\(height), zoom=\(String(format: "%.2f", zoomScale)), diagram=\(diagramPreview)..."
        )

        let configuration = WKWebViewConfiguration()
        if TestRuntime.isRunningUnitTests {
            configuration.websiteDataStore = .nonPersistent()
        }
        configuration.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        configuration.userContentController.add(context.coordinator, name: "mermaidHeight")
        configuration.userContentController.add(context.coordinator, name: "mermaidStatus")

        let webView = AutoSizingWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.contentHeight = height
        context.coordinator.webView = webView
        context.coordinator.diagramId = diagramId
        context.coordinator.loadBootstrapDocument(minHeight: height, reason: "makeNSView")

        // Make webview transparent
        webView.layer?.backgroundColor = NSColor.clear.cgColor

        return webView
    }
    
    func updateNSView(_ webView: WKWebView, context: Context) {
        let theme = colorScheme == .dark ? "dark" : "default"
        let backgroundColor = colorScheme == .dark ? "#20272b" : "#f6f6f2"
        let textColor = colorScheme == .dark ? "#eff5f6" : "#1d292d"
        let zoomValue = String(format: "%.2f", zoomScale)
        let renderContextID = "\(diagramId)|theme=\(theme)|height=\(Int(height.rounded()))|zoom=\(zoomValue)"

        // Skip update if the last successful context is still valid.
        if context.coordinator.renderState.lastSuccessfulRenderContextID == renderContextID &&
            !context.coordinator.renderState.needsReload &&
            context.coordinator.renderState.pendingRenderContextID == nil {
            return
        }

        // Skip duplicate scheduling while this context is already pending.
        if context.coordinator.renderState.pendingRenderContextID == renderContextID {
            return
        }

        SessionLogger.shared.logMermaidEvent(
            name: "updateNSView",
            details: "id=\(diagramId), isLoading=\(webView.isLoading), lastId=\(context.coordinator.lastLoadedDiagramId ?? "none"), zoom=\(zoomValue), lastSuccess=\(context.coordinator.renderState.lastSuccessfulRenderContextID ?? "none"), pending=\(context.coordinator.renderState.pendingRenderContextID ?? "none")"
        )

        context.coordinator.lastLoadedDiagramId = diagramId
        if let autoSizingView = webView as? AutoSizingWebView {
            autoSizingView.contentHeight = height
        }

        let payload = MermaidRenderPayload(
            contextID: renderContextID,
            diagramID: diagramId,
            diagramText: sanitizedDiagram,
            retryDiagramText: retryDiagram,
            theme: theme,
            backgroundColor: backgroundColor,
            textColor: textColor,
            zoomScale: Double(zoomScale),
            minHeight: Double(height)
        )

        context.coordinator.markRenderEnqueued(
            contextID: renderContextID,
            payload: payload,
            policy: renderPolicy
        )
        context.coordinator.scheduleRender(
            payload: payload,
            diagramID: diagramId,
            renderContextID: renderContextID,
            policy: renderPolicy
        )
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(minHeight: height)
    }
    
    /// Clean up WKWebView resources when the view is dismantled.
    /// This prevents crashes from script message handlers firing after deallocation.
    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        let diagramId = coordinator.diagramId ?? "unknown"
        SessionLogger.shared.logMermaidEvent(
            name: "dismantleNSView_start",
            details: "id=\(diagramId), isLoading=\(webView.isLoading)"
        )
        
        coordinator.cleanup()
        webView.stopLoading()
        webView.navigationDelegate = nil
        
        SessionLogger.shared.logMermaidEvent(
            name: "dismantleNSView_complete",
            details: "id=\(diagramId)"
        )
    }
    
}

// MARK: - Preview

#if DEBUG && XCODE_RUNNING_FOR_PREVIEWS
#Preview("Flowchart") {
    MermaidDiagramView(
        diagram: """
        flowchart TD
            Client[Client App] --> LB[Load Balancer]
            LB --> API1[API Server 1]
            LB --> API2[API Server 2]
            API1 --> Cache[Redis Cache]
            API2 --> Cache
            API1 --> DB[(PostgreSQL)]
            API2 --> DB
        """,
        height: 400
    )
    .frame(width: 600, height: 400)
    .background(Color.black.opacity(0.9))
}

#Preview("Sequence Diagram") {
    MermaidDiagramView(
        diagram: """
        sequenceDiagram
            participant C as Client
            participant A as API Gateway
            participant S as Service
            participant D as Database
            
            C->>A: Request
            A->>S: Forward
            S->>D: Query
            D-->>S: Results
            S-->>A: Response
            A-->>C: JSON
        """,
        height: 400
    )
    .frame(width: 600, height: 400)
    .background(Color.black.opacity(0.9))
}

#Preview("ER Diagram") {
    MermaidDiagramView(
        diagram: """
        erDiagram
            USER ||--o{ ORDER : places
            ORDER ||--|{ LINE_ITEM : contains
            PRODUCT ||--o{ LINE_ITEM : "ordered in"
            USER {
                int id PK
                string email
                string name
            }
            ORDER {
                int id PK
                int user_id FK
                datetime created_at
            }
        """,
        height: 400
    )
    .frame(width: 600, height: 400)
    .background(Color.black.opacity(0.9))
}
#endif
