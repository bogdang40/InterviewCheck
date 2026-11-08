import AppKit
import UniformTypeIdentifiers
import WebKit

/// Saves a report as Markdown or PDF where the interviewer chooses.
@MainActor
enum ReportExporter {
    static func exportMarkdown(_ report: InterviewReportData) {
        guard let url = savePanel(report, type: .plainText, extension: "md") else { return }
        try? InterviewReportComposer.markdown(report).write(to: url, atomically: true, encoding: .utf8)
    }

    static func exportPDF(_ report: InterviewReportData) {
        guard let url = savePanel(report, type: .pdf, extension: "pdf") else { return }
        let renderer = HTMLPDFRenderer()
        Task { @MainActor in
            if let data = await renderer.render(InterviewReportComposer.html(report)) {
                try? data.write(to: url)
            }
        }
    }

    private static func savePanel(_ report: InterviewReportData, type: UTType, extension ext: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        let name = report.interview.candidateName.isEmpty ? "Interview" : report.interview.candidateName
        panel.nameFieldStringValue = "\(name) interview report.\(ext)"
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// Renders HTML to a PDF with an offscreen web view.
@MainActor
final class HTMLPDFRenderer: NSObject, WKNavigationDelegate {
    private let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 612, height: 792))
    private var continuation: CheckedContinuation<Void, Never>?

    func render(_ html: String) async -> Data? {
        webView.navigationDelegate = self
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            webView.loadHTMLString(html, baseURL: nil)
        }
        return try? await webView.pdf(configuration: WKPDFConfiguration())
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            continuation?.resume()
            continuation = nil
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated {
            continuation?.resume()
            continuation = nil
        }
    }
}
