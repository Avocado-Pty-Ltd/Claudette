import Foundation

/// A comment Claudette drafted for one LinkedIn post. Nothing here has been
/// published — the agent that produced it is forbidden from posting. The user
/// reviews the draft in the prospect panel, copies it, and posts it themselves.
struct DraftComment: Identifiable, Codable, Hashable {
    var id = UUID()
    var postURL: String = ""
    var author: String = ""
    var postSummary: String = ""
    var postedAt: String = ""
    var draft: String = ""
    var rationale: String = ""

    enum CodingKeys: String, CodingKey {
        case postURL = "post_url"
        case author
        case postSummary = "post_summary"
        case postedAt = "posted_at"
        case draft
        case rationale
    }

    var url: URL? { URL(string: postURL) }
}

/// One person the agent thinks is worth connecting with, plus the note to send.
struct Prospect: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String = ""
    var headline: String = ""
    var profileURL: String = ""
    var location: String = ""
    var company: String = ""
    var mutualConnections: String = ""
    var why: String = ""
    var confidence: Confidence = .medium
    var connectionNote: String = ""
    var comments: [DraftComment] = []

    enum CodingKeys: String, CodingKey {
        case name, headline, location, company, why, confidence, comments
        case profileURL = "profile_url"
        case mutualConnections = "mutual_connections"
        case connectionNote = "connection_note"
    }

    enum Confidence: String, Codable, Hashable {
        case high, medium, low

        /// Unknown values decode to `.medium` rather than failing the whole
        /// report — one odd string from the model shouldn't cost the user a
        /// two-minute browser run.
        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Confidence(rawValue: raw.lowercased()) ?? .medium
        }

        var label: String {
            switch self {
            case .high: return "Strong match"
            case .medium: return "Worth a look"
            case .low: return "Thin evidence"
            }
        }

        var tintHex: UInt32 {
            switch self {
            case .high: return 0x4E8A7A    // teal
            case .medium: return 0x8A7B4E  // gold
            case .low: return 0x6C6459     // graphite
            }
        }
    }

    var url: URL? { URL(string: profileURL) }

    /// LinkedIn's note field caps at 300 characters. The card counts against
    /// this so an over-long note is visible before LinkedIn truncates it.
    static let noteLimit = 300
}

/// The full result of one prospecting run — the sidecar's structured output.
struct ProspectReport: Codable, Hashable {
    var goal: String = ""
    var summary: String = ""
    var prospects: [Prospect] = []
    var standaloneComments: [DraftComment] = []
    var blockedReason: String = ""

    enum CodingKeys: String, CodingKey {
        case goal, summary, prospects
        case standaloneComments = "standalone_comments"
        case blockedReason = "blocked_reason"
    }

    var isEmpty: Bool { prospects.isEmpty && standaloneComments.isEmpty }

    /// Every drafted comment in the report, whether it hung off a prospect or
    /// stood alone. Used for the counts in the panel header.
    var allComments: [DraftComment] {
        prospects.flatMap(\.comments) + standaloneComments
    }

    /// Markdown rendering of the report, used by "Send to chat" so Claude can
    /// pick the drafts up and rework them in the normal conversation.
    func markdown() -> String {
        var out = "## LinkedIn prospecting — \(goal)\n\n"
        if !summary.isEmpty { out += summary + "\n\n" }
        if !blockedReason.isEmpty { out += "> Run was cut short: \(blockedReason)\n\n" }

        for p in prospects {
            out += "### \(p.name)"
            if !p.headline.isEmpty { out += " — \(p.headline)" }
            out += "\n"
            if !p.profileURL.isEmpty { out += "\(p.profileURL)\n" }
            var facts: [String] = []
            if !p.company.isEmpty { facts.append(p.company) }
            if !p.location.isEmpty { facts.append(p.location) }
            if !p.mutualConnections.isEmpty { facts.append(p.mutualConnections) }
            if !facts.isEmpty { out += facts.joined(separator: " · ") + "\n" }
            if !p.why.isEmpty { out += "\n_Why:_ \(p.why)\n" }
            if !p.connectionNote.isEmpty { out += "\n**Connection note draft**\n\n\(p.connectionNote)\n" }
            for c in p.comments { out += "\n" + c.markdown(indentHeading: "**Comment draft**") }
            out += "\n"
        }

        if !standaloneComments.isEmpty {
            out += "### Other posts worth a comment\n\n"
            for c in standaloneComments { out += c.markdown(indentHeading: "**Comment draft**") + "\n" }
        }
        return out
    }
}

extension DraftComment {
    func markdown(indentHeading: String) -> String {
        var out = ""
        if !author.isEmpty || !postedAt.isEmpty {
            out += "_On \(author.isEmpty ? "a post" : author)'s post"
            if !postedAt.isEmpty { out += " (\(postedAt))" }
            out += "_\n"
        }
        if !postSummary.isEmpty { out += "\(postSummary)\n" }
        if !postURL.isEmpty { out += "\(postURL)\n" }
        if !draft.isEmpty { out += "\n\(indentHeading)\n\n\(draft)\n" }
        return out
    }
}

/// One line of live progress from the running agent — what it's looking at and
/// what it decided to do next. Rendered as the scrolling trace in the panel.
struct ProspectStep: Identifiable, Equatable {
    let id = UUID()
    var number: Int
    var url: String
    var title: String
    var goal: String
    var evaluation: String
    var actions: [String]

    /// Host + trimmed path, so "linkedin.com/search/results/people" reads at a
    /// glance instead of a 300-character query string.
    var shortURL: String {
        guard let u = URL(string: url), let host = u.host else { return url }
        let path = u.path
        return path.isEmpty || path == "/" ? host : host + path
    }
}
