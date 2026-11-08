import Foundation

/// Résumés recruiters email to the interviewer ("Jane's CV for tomorrow").
/// The server searches recent mail for the candidate's name or email; only
/// an attachment that names the candidate, or a CV in a message whose
/// subject names them, is taken. Read-only, like the invite sync.
extension MailInviteConnector: ResumeFinder {
    static let resumeLookBack: TimeInterval = 90 * 24 * 3600
    static let maxResumeBytes = 10 * 1024 * 1024

    public func findResume(for candidate: ExternalCandidate, into folder: URL) async throws -> FoundResume? {
        guard findsResumes else { return nil }
        let tokens = Self.nameTokens(candidate.name)
        // IMAP quoting takes plain ASCII only; a name outside it is searched by email.
        let terms = ([candidate.name] + [candidate.email].compactMap { $0 })
            .filter { $0.allSatisfy { $0.isASCII && $0 != "\"" && $0 != "\\" } && $0.count >= 4 }
        guard !terms.isEmpty, !tokens.isEmpty || candidate.email != nil else { return nil }

        let session = try await signIn()
        defer { session.close() }
        _ = try await examine(session)
        do {
            let since = IMAPSession.searchDate(Date().addingTimeInterval(-Self.resumeLookBack))
            let search = terms.count == 2 ? "OR TEXT \"\(terms[0])\" TEXT \"\(terms[1])\"" : "TEXT \"\(terms[0])\""
            let found = try await session.command("UID SEARCH SINCE \(since) \(search)")
            let uids = found.compactMap(IMAPParser.searchResults).flatMap { $0 }.sorted().suffix(20)
            guard !uids.isEmpty else { return nil }

            // Each message's documents and its subject, sender and date.
            var best: (uid: Int, part: IMAPBodyStructure.Part, header: [String: String], strength: Int)?
            let lines = try await session.command(
                "UID FETCH \(uids.map(String.init).joined(separator: ",")) (UID BODYSTRUCTURE BODY.PEEK[HEADER.FIELDS (SUBJECT FROM DATE)])")
            for line in lines {
                guard let attributes = IMAPParser.fetchAttributes(line), let uid = attributes["UID"]?.text.flatMap(Int.init),
                      let structure = attributes["BODYSTRUCTURE"] else { continue }
                let header = Self.headers(attributes.first { $0.key.hasPrefix("BODY[HEADER") }?.value.text ?? "")
                for part in IMAPBodyStructure.documentParts(structure) where (part.size ?? 0) <= Self.maxResumeBytes {
                    let strength = Self.matchStrength(filename: part.filename ?? "", subject: header["subject"] ?? "", tokens: tokens)
                    guard strength > 0 else { continue }
                    if best == nil || (strength, uid) > (best!.strength, best!.uid) { best = (uid, part, header, strength) }
                }
            }
            guard let best else { return nil }
            let body = try await session.command("UID FETCH \(best.uid) (UID BODY.PEEK[\(best.part.section)])")
            _ = try? await session.command("LOGOUT")
            for line in body {
                guard let attributes = IMAPParser.fetchAttributes(line),
                      case .string(let raw)? = attributes["BODY[\(best.part.section)]"],
                      let data = MIMEDecoding.data(raw, encoding: best.part.encoding), !data.isEmpty else { continue }
                let name = Self.safeFileName(best.part.filename ?? "resume.pdf")
                let file = folder.appendingPathComponent(name)
                try data.write(to: file, options: .atomic)
                let date = best.header["date"].map { $0.components(separatedBy: " ").prefix(4).joined(separator: " ") }
                return FoundResume(file: file, filename: name,
                                   origin: [best.header["from"], date].compactMap { $0 }.joined(separator: ", "))
            }
            return nil
        } catch {
            throw Self.mapped(error)
        }
    }

    static func matchStrength(filename: String, subject: String, tokens: [String]) -> Int {
        ResumeMatching.strength(filename: filename, subject: subject, tokens: tokens)
    }

    static func nameTokens(_ text: String) -> [String] { ResumeMatching.tokens(text) }

    /// "Subject: …", "From: …", "Date: …" (folded lines joined, encoded words decoded).
    static func headers(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        let unfolded = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n ", with: " ")
            .replacingOccurrences(of: "\n\t", with: " ")
        for line in unfolded.components(separatedBy: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].lowercased()
            result[key] = MIMEDecoding.headerText(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        return result
    }

    static func safeFileName(_ name: String) -> String { ResumeMatching.safeFileName(name) }
}
