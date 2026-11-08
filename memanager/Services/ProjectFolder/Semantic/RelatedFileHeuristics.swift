import Foundation

final class RelatedFileHeuristics {
    func candidate(
        target: ProjectTextFile,
        targetScan: ProjectSemanticFileScan?,
        candidate: ProjectTextFile,
        candidateScan: ProjectSemanticFileScan?
    ) -> ProjectRelatedFile? {
        guard target.relativePath != candidate.relativePath else { return nil }

        var score = 0
        var reasons: [String] = []
        let targetBase = normalizedBaseName(for: target.relativePath)
        let candidateBase = normalizedBaseName(for: candidate.relativePath)

        if isTestPair(targetBase: targetBase, targetPath: target.relativePath, candidatePath: candidate.relativePath) {
            score += 220
            reasons.append("test pair")
        }
        if targetBase == candidateBase {
            score += 90
            reasons.append("same basename")
        }
        if isExtensionPair(targetBase: targetBase, candidatePath: candidate.relativePath) {
            score += 80
            reasons.append("extension pair")
        }
        if sharesFeatureFolder(targetPath: target.relativePath, candidatePath: candidate.relativePath) {
            score += 40
            reasons.append("same feature folder")
        }
        if sharesDeclarationNames(targetScan: targetScan, candidateScan: candidateScan) {
            score += 60
            reasons.append("shared declaration names")
        }

        guard score > 0 else { return nil }
        return ProjectRelatedFile(
            path: candidate.relativePath,
            reason: reasons.joined(separator: ", "),
            score: score
        )
    }

    private func normalizedBaseName(for path: String) -> String {
        let stem = (path as NSString).deletingPathExtension
        let lastComponent = (stem as NSString).lastPathComponent
        if let base = lastComponent.split(separator: "+").first {
            return String(base).replacingOccurrences(of: "Tests", with: "")
        }
        return lastComponent.replacingOccurrences(of: "Tests", with: "")
    }

    private func isTestPair(targetBase: String, targetPath: String, candidatePath: String) -> Bool {
        let candidateName = ((candidatePath as NSString).deletingPathExtension as NSString).lastPathComponent
        let targetName = ((targetPath as NSString).deletingPathExtension as NSString).lastPathComponent
        return candidateName == "\(targetBase)Tests" || targetName == "\(targetBase)Tests"
    }

    private func isExtensionPair(targetBase: String, candidatePath: String) -> Bool {
        let candidateName = ((candidatePath as NSString).deletingPathExtension as NSString).lastPathComponent
        return candidateName.hasPrefix(targetBase + "+")
    }

    private func sharesFeatureFolder(targetPath: String, candidatePath: String) -> Bool {
        let targetFolder = (targetPath as NSString).deletingLastPathComponent
        let candidateFolder = (candidatePath as NSString).deletingLastPathComponent
        return !targetFolder.isEmpty && targetFolder == candidateFolder
    }

    private func sharesDeclarationNames(
        targetScan: ProjectSemanticFileScan?,
        candidateScan: ProjectSemanticFileScan?
    ) -> Bool {
        guard let targetScan, let candidateScan else { return false }
        let targetNames = Set(targetScan.declarations.map(\.name))
        let candidateNames = Set(candidateScan.declarations.map(\.name))
        return !targetNames.intersection(candidateNames).isEmpty
    }
}
