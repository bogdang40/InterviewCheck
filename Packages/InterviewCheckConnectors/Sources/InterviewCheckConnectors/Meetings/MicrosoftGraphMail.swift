import Foundation

/// Résumés emailed to an Outlook mailbox, through Microsoft Graph search
/// (opted in: it needs the Mail.Read permission). Same strict matching as
/// the IMAP mailbox: the file must name the candidate, or be a CV in a
/// message whose subject names them.
extension MicrosoftGraphConnector: ResumeFinder {
    public func findResume(for candidate: ExternalCandidate, into folder: URL) async throws -> FoundResume? {
        guard mailResumes else { return nil }
        let tokens = ResumeMatching.tokens(candidate.name)
        let terms = [candidate.name, candidate.email].compactMap { $0 }
            .map { $0.replacingOccurrences(of: "\"", with: "") }.filter { $0.count >= 4 }
        guard !terms.isEmpty, !tokens.isEmpty else { return nil }
        let api = try await client()
        let since = Date().addingTimeInterval(-90 * 24 * 3600)
        var best: (message: JSONValue, attachment: JSONValue, strength: Int, received: Date)?
        // One plain search per term (all its words must appear); results merged.
        var messages: [JSONValue] = []
        var seen = Set<String>()
        for term in terms {
            let found = try await api.getJSON("me/messages", query: [
                URLQueryItem(name: "$search", value: "\"\(term)\""),
                URLQueryItem(name: "$select", value: "id,subject,from,receivedDateTime,hasAttachments"),
                URLQueryItem(name: "$top", value: "25"),
            ])["value"].array
            for message in found where message["hasAttachments"].bool == true
                && (message["receivedDateTime"].date ?? .distantPast) >= since {
                if let id = message["id"].string, seen.insert(id).inserted { messages.append(message) }
            }
        }
        for message in messages {
            guard let id = message["id"].string else { continue }
            let attachments = try await api.getJSON("me/messages/\(id)/attachments", query: [
                URLQueryItem(name: "$select", value: "id,name,contentType,size"),
            ])["value"].array
            for attachment in attachments {
                guard let name = attachment["name"].string, ResumeMatching.isDocument(name),
                      (attachment["size"].double ?? 0) <= 10 * 1024 * 1024 else { continue }
                let strength = ResumeMatching.strength(filename: name, subject: message["subject"].string ?? "", tokens: tokens)
                let received = message["receivedDateTime"].date ?? .distantPast
                guard strength > 0 else { continue }
                if best == nil || (strength, received) > (best!.strength, best!.received) {
                    best = (message, attachment, strength, received)
                }
            }
        }
        guard let best, let messageID = best.message["id"].string, let attachmentID = best.attachment["id"].string else { return nil }
        let name = ResumeMatching.safeFileName(best.attachment["name"].string ?? "resume.pdf")
        let file = ExternalFile(kind: .resume, filename: name,
                                url: api.url("me/messages/\(messageID)/attachments/\(attachmentID)/$value"), needsAuth: true)
        let saved = try await FileDownload.save(file, into: folder, client: api, transport: api.transport)
        let sender = best.message.at("from.emailAddress.name").string ?? best.message.at("from.emailAddress.address").string
        let date = best.received.formatted(date: .abbreviated, time: .omitted)
        return FoundResume(file: saved, filename: name, origin: [sender, date].compactMap { $0 }.joined(separator: ", "))
    }
}
