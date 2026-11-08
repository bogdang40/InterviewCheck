import Foundation

final class ProjectSemanticScannerRegistry {
    static let shared = ProjectSemanticScannerRegistry()

    private let scanners: [ProjectSemanticScanner]

    init(
        scanners: [ProjectSemanticScanner] = [
            SwiftDeclarationScanner(),
            PythonDeclarationScanner(),
            RustDeclarationScanner(),
            CFamilyDeclarationScanner()
        ]
    ) {
        self.scanners = scanners
    }

    func scanner(for fileExtension: String) -> ProjectSemanticScanner? {
        scanners.first { $0.supportedExtensions.contains(fileExtension.lowercased()) }
    }

    func supports(_ fileExtension: String) -> Bool {
        scanner(for: fileExtension) != nil
    }
}
