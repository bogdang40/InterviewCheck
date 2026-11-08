import Foundation

protocol ProjectSemanticScanner {
    var supportedExtensions: Set<String> { get }
    func scan(file: ProjectTextFile) -> ProjectSemanticFileScan
}
