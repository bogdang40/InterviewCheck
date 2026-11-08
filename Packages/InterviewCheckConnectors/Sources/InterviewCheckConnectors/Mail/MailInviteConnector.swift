import Foundation

/// Interview invites from any mailbox over IMAP: Gmail, iCloud, Yahoo,
/// Fastmail, Zoho, or a company mail server. It reads the calendar parts of
/// recent messages (read-only; nothing is marked as read), keeps the latest
/// version of each invite and drops cancelled ones.
public struct MailInviteConnector: InterviewSource {
    public let kind = ConnectorKind.imapMail
    let host: String
    let port: UInt16
    let email: String
    let password: String
    let folder: String
    let extraKeywords: [String]
    /// Every invite in the folder counts (a mailbox kept for interviews).
    let everyInvite: Bool
    /// Prepare may look for a candidate's emailed résumé (on unless turned off).
    let findsResumes: Bool
    let openStream: @Sendable (String, UInt16) async throws -> IMAPStream
    let cache: MailInviteCache

    /// Messages looked at per sync (newest first) and invites read.
    static let messageLimit = 500
    static let inviteLimit = 150
    /// Invites usually arrive days or weeks ahead.
    static let lookBack: TimeInterval = 60 * 24 * 3600

    init(credentials: ConnectorCredentials,
         openStream: @escaping @Sendable (String, UInt16) async throws -> IMAPStream = MailInviteConnector.networkStream,
         cache: MailInviteCache = .shared) throws {
        guard let email = credentials["email"]?.trimmingCharacters(in: .whitespaces), !email.isEmpty else {
            throw ConnectorError.missingCredential("Email address")
        }
        guard let password = credentials["password"], !password.isEmpty else { throw ConnectorError.missingCredential("App password") }
        let typedHost = credentials["host"]?.trimmingCharacters(in: .whitespaces) ?? ""
        let (hostPart, portPart) = Self.split(typedHost)
        guard let host = hostPart ?? Self.knownHost(for: email) else {
            throw ConnectorError.missingCredential("IMAP server (for example imap.example.com)")
        }
        self.host = host
        self.port = portPart ?? 993
        self.email = email
        self.password = password
        let folder = credentials["folder"]?.trimmingCharacters(in: .whitespaces) ?? ""
        self.folder = folder.isEmpty ? "INBOX" : folder
        self.extraKeywords = credentials["keywords"]?.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } ?? []
        self.everyInvite = credentials["everyInvite"] == "true"
        self.findsResumes = credentials["noResumes"] != "true"
        self.openStream = openStream
        self.cache = cache
    }

    static let networkStream: @Sendable (String, UInt16) async throws -> IMAPStream = { host, port in
        let stream = NetworkIMAPStream(host: host, port: port)
        do {
            try await stream.open()
        } catch {
            // Offline: stop the connection instead of leaving it retrying.
            stream.close()
            throw error
        }
        return stream
    }

    /// The IMAP server of the big mail providers, from the address.
    static func knownHost(for email: String) -> String? {
        guard let domain = email.split(separator: "@").last?.lowercased() else { return nil }
        switch domain {
        case "gmail.com", "googlemail.com": return "imap.gmail.com"
        case "icloud.com", "me.com", "mac.com": return "imap.mail.me.com"
        case "yahoo.com", "ymail.com", "rocketmail.com": return "imap.mail.yahoo.com"
        case "aol.com": return "imap.aol.com"
        case "fastmail.com", "fastmail.fm": return "imap.fastmail.com"
        case "zoho.com", "zohomail.com": return "imap.zoho.com"
        case "gmx.com", "gmx.net": return "imap.gmx.com"
        case "proton.me", "protonmail.com": return nil // only through Proton Mail Bridge on this Mac
        default: return nil
        }
    }

    /// "imap.example.com:993" → host and port.
    static func split(_ typed: String) -> (String?, UInt16?) {
        guard !typed.isEmpty else { return (nil, nil) }
        let parts = typed.split(separator: ":")
        if parts.count == 2, let port = UInt16(parts[1]) { return (String(parts[0]), port) }
        return (typed, nil)
    }

    public func verify() async throws -> String {
        let session = try await signIn()
        defer { session.close() }
        let count = try await examine(session).count
        _ = try? await session.command("LOGOUT")
        return "\(email) \u{00B7} \(folder)\(count.map { " (\($0) messages)" } ?? "")"
    }

    public func upcomingInterviews(from start: Date, to end: Date) async throws -> [ExternalInterview] {
        let session = try await signIn()
        defer { session.close() }
        let validity = try await examine(session).uidValidity
        do {
            return try await invites(in: session, uidValidity: validity, from: start, to: end)
        } catch {
            throw Self.mapped(error)
        }
    }

    private func invites(in session: IMAPSession, uidValidity: String?, from start: Date,
                         to end: Date) async throws -> [ExternalInterview] {
        let since = IMAPSession.searchDate(start.addingTimeInterval(-Self.lookBack))
        let found = try await session.command("UID SEARCH SINCE \(since)")
        let all = found.compactMap(IMAPParser.searchResults).flatMap { $0 }.sorted()
        if all.count > Self.messageLimit {
            SyncNotes.note("Only the newest \(Self.messageLimit) of \(all.count) recent messages in \(folder) were checked for invites.")
        }
        let uids = all.suffix(Self.messageLimit)
        // Messages read on an earlier sync are not downloaded again (only when
        // the server gives a UIDVALIDITY, so UIDs are known to be stable).
        let cacheKey = uidValidity.map { "\(host)|\(email.lowercased())|\(folder)|\($0)" }
        let known = cacheKey.map(cache.events) ?? [:]
        var learned: [Int: [CalendarEvent]] = [:]

        // Which new messages carry a calendar part.
        var invites: [(uid: Int, parts: [IMAPBodyStructure.Part])] = []
        for chunk in uids.filter({ known[$0] == nil }).chunked(100) {
            let lines = try await session.command("UID FETCH \(chunk.map(String.init).joined(separator: ",")) (UID BODYSTRUCTURE)")
            for line in lines {
                guard let attributes = IMAPParser.fetchAttributes(line), let uid = attributes["UID"]?.text.flatMap(Int.init),
                      let structure = attributes["BODYSTRUCTURE"] else { continue }
                let parts = IMAPBodyStructure.calendarParts(structure)
                if parts.isEmpty { learned[uid] = [] } else { invites.append((uid, parts)) }
            }
        }

        // Newest first; invites past the limit are read on later syncs.
        if invites.count > Self.inviteLimit { SyncNotes.cut("new invites", read: Self.inviteLimit) }
        for invite in invites.sorted(by: { $0.uid > $1.uid }).prefix(Self.inviteLimit) {
            let sections = invite.parts.map { "BODY.PEEK[\($0.section)]" }.joined(separator: " ")
            let lines = try await session.command("UID FETCH \(invite.uid) (UID \(sections))")
            var events: [CalendarEvent] = []
            for line in lines {
                guard let attributes = IMAPParser.fetchAttributes(line) else { continue }
                for part in invite.parts {
                    guard case .string(let data)? = attributes["BODY[\(part.section)]"],
                          let text = MIMEDecoding.decode(data, encoding: part.encoding, charset: part.charset) else { continue }
                    events += ICSParser.events(in: text)
                }
            }
            learned[invite.uid] = events
        }
        _ = try? await session.command("LOGOUT")
        if let cacheKey { cache.update(cacheKey, with: learned, keeping: Set(uids)) }

        // Each invite keeps its latest revision; replies and counter-proposals
        // are not the organiser's invite.
        var latest: [String: (event: CalendarEvent, uid: Int)] = [:]
        for (uid, events) in known.merging(learned, uniquingKeysWith: { $1 }) where uids.contains(uid) {
            for event in events where event.isRevision {
                if let current = latest[event.id], (current.event.sequence, current.uid) >= (event.sequence, uid) { continue }
                latest[event.id] = (event, uid)
            }
        }

        return latest.values.map(\.event)
            .filter { !$0.isCancelled && $0.startsAt >= start && $0.startsAt <= end }
            .filter { everyInvite || InterviewEventClassifier.isInterview($0, extraKeywords: extraKeywords) }
            .map { InterviewEventClassifier.interview(from: $0, source: .imapMail) }
            .sorted { $0.startsAt < $1.startsAt }
    }

    func signIn() async throws -> IMAPSession {
        let session = IMAPSession(stream: try await openStream(host, port))
        do {
            try await session.greeting()
            try await session.command("LOGIN \(try IMAPSession.quoted(email)) \(try IMAPSession.quoted(password))")
            return session
        } catch IMAPError.rejected(_, let message) {
            session.close()
            let lowered = message.lowercased()
            if lowered.contains("application-specific") || lowered.contains("app password") || lowered.contains("web login") {
                throw ConnectorError.forbidden("this mailbox needs an app password, not the normal password")
            }
            throw ConnectorError.unauthorized
        } catch {
            session.close()
            throw Self.mapped(error)
        }
    }

    /// Opens the folder read-only; returns its message count and UIDVALIDITY when given.
    func examine(_ session: IMAPSession) async throws -> (count: Int?, uidValidity: String?) {
        do {
            let lines = try await session.command("EXAMINE \(try IMAPSession.quoted(folder))")
            var count: Int?
            var validity: String?
            for line in lines {
                let values = IMAPParser.values(line)
                if values.count == 3, values[2].text?.uppercased() == "EXISTS" { count = values[1].text.flatMap(Int.init) }
                let text = String(decoding: line, as: UTF8.self)
                if let range = text.range(of: #"\[UIDVALIDITY (\d+)\]"#, options: .regularExpression) {
                    validity = text[range].filter(\.isNumber)
                }
            }
            return (count, validity)
        } catch IMAPError.rejected {
            throw ConnectorError.unsupported("The folder \u{201C}\(folder)\u{201D} was not found in this mailbox.")
        } catch {
            throw Self.mapped(error)
        }
    }

    static func mapped(_ error: Error) -> Error {
        switch error {
        case IMAPError.closed: return ConnectorError.http(0, "The mail server closed the connection")
        case IMAPError.tooLarge: return ConnectorError.invalidResponse("a message part was too large")
        case IMAPError.rejected(let status, let message): return ConnectorError.http(0, "\(status) \(message)")
        default: return error
        }
    }
}
