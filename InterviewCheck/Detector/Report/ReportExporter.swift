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
        if let data = PaginatedPDF.data(ReportAttributedText.make(report)) {
            try? data.write(to: url)
        }
    }

    /// Every answer from every saved interview, for a spreadsheet.
    static func exportCSV(_ reports: [InterviewReportData]) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "\(AppBrand.name) interviews.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? InterviewCSV.make(reports).write(to: url, atomically: true, encoding: .utf8)
    }

    /// The macOS share sheet (Mail, Messages, AirDrop…) with the PDF.
    static func share(_ report: InterviewReportData) {
        guard let data = PaginatedPDF.data(ReportAttributedText.make(report)),
              let window = NSApp.keyWindow, let view = window.contentView else { return }
        let name = report.interview.candidateName.isEmpty ? "Interview" : report.interview.candidateName
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("interviewcheck-share", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("\(name) interview report.pdf")
        guard (try? data.write(to: file, options: .atomic)) != nil else { return }
        let picker = NSSharingServicePicker(items: [file])
        let anchor = NSRect(x: view.bounds.maxX - 220, y: view.bounds.maxY - 40, width: 1, height: 1)
        picker.show(relativeTo: anchor, of: view, preferredEdge: .minY)
    }

    /// File › Print: the same pages as the PDF, through the print panel.
    static func print(_ report: InterviewReportData) {
        let operation = NSPrintOperation(view: PaginatedPDF.textView(ReportAttributedText.make(report)),
                                         printInfo: PaginatedPDF.printInfo())
        operation.jobTitle = "\(report.interview.candidateName.isEmpty ? "Interview" : report.interview.candidateName) interview report"
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.run()
    }

    private static func savePanel(_ report: InterviewReportData, type: UTType, extension ext: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        let name = report.interview.candidateName.isEmpty ? "Interview" : report.interview.candidateName
        panel.nameFieldStringValue = "\(name) interview report.\(ext)"
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// Lays formatted text out on US Letter pages with margins, like printing it.
@MainActor
enum PaginatedPDF {
    static let paperSize = NSSize(width: 612, height: 792)
    static let margin: CGFloat = 54

    static func printInfo() -> NSPrintInfo {
        let printInfo = NSPrintInfo()
        printInfo.paperSize = paperSize
        printInfo.topMargin = margin
        printInfo.bottomMargin = margin
        printInfo.leftMargin = margin
        printInfo.rightMargin = margin
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.isVerticallyCentered = false
        return printInfo
    }

    /// The text laid out at the printable width.
    static func textView(_ attributed: NSAttributedString) -> NSTextView {
        let width = paperSize.width - 2 * margin
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        textView.textStorage?.setAttributedString(attributed)
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        if let used = textView.layoutManager?.usedRect(for: textView.textContainer!) {
            textView.frame.size.height = max(used.height, 100)
        }
        return textView
    }

    static func data(_ attributed: NSAttributedString) -> Data? {
        let printInfo = printInfo()
        let textView = textView(attributed)

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
