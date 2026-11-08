import AppKit
import UniformTypeIdentifiers

/// Saves a report as Markdown or PDF where the interviewer chooses.
@MainActor
enum ReportExporter {
    static func exportMarkdown(_ report: InterviewReportData) {
        guard let url = savePanel(report, type: .plainText, extension: "md") else { return }
        try? InterviewReportComposer.markdown(report).write(to: url, atomically: true, encoding: .utf8)
    }

    static func exportPDF(_ report: InterviewReportData) {
        guard let url = savePanel(report, type: .pdf, extension: "pdf") else { return }
        if let data = PaginatedPDF.data(html: InterviewReportComposer.html(report)) {
            try? data.write(to: url)
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

/// Lays HTML out on US Letter pages with margins, like printing it.
@MainActor
enum PaginatedPDF {
    static let paperSize = NSSize(width: 612, height: 792)
    static let margin: CGFloat = 54

    static func data(html: String) -> Data? {
        guard let attributed = NSAttributedString(
            html: Data(html.utf8),
            options: [.documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil
        ) else { return nil }

        let printInfo = NSPrintInfo()
        printInfo.paperSize = paperSize
        printInfo.topMargin = margin
        printInfo.bottomMargin = margin
        printInfo.leftMargin = margin
        printInfo.rightMargin = margin
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.isVerticallyCentered = false

        let width = paperSize.width - 2 * margin
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        textView.textStorage?.setAttributedString(attributed)
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        if let used = textView.layoutManager?.usedRect(for: textView.textContainer!) {
            textView.frame.size.height = max(used.height, 100)
        }

        // A print job saved to a file paginates exactly like printing.
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("interviewcheck-report-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: output) }
        printInfo.jobDisposition = .save
        printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = output
        let operation = NSPrintOperation(view: textView, printInfo: printInfo)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard operation.run() else { return nil }
        return try? Data(contentsOf: output)
    }
}
