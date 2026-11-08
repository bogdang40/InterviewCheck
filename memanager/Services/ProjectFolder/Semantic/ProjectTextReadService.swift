import Foundation

final class ProjectTextReadService {
    private let enumerator: ProjectEligibleFileEnumerator

    init(enumerator: ProjectEligibleFileEnumerator) {
        self.enumerator = enumerator
    }

    convenience init(context: ProjectToolContext) {
        self.init(enumerator: ProjectEligibleFileEnumerator(context: context))
    }

    func readSlice(path: String, offset: Int, limit: Int) throws -> ProjectLineSlice {
        let file = try enumerator.loadTextFile(relativePath: path)
        let slice = Array(file.lines.dropFirst(offset).prefix(limit))
        return ProjectLineSlice(
            relativePath: file.relativePath,
            offset: offset,
            lines: slice,
            totalLineCount: file.lines.count
        )
    }
}
