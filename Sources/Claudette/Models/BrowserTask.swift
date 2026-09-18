import Foundation

/// A piece of text the agent was asked to write — a reply, a summary, a message.
/// Nothing here has been submitted anywhere: the user reviews it, copies it, and
/// uses it themselves.
struct Draft: Identifiable, Codable, Hashable {
    var id = UUID()
    /// Echoes the label of the draft slot that asked for it, so the UI can match
    /// a draft back to the character limit the recipe declared.
    var label: String = ""
    var text: String = ""
    /// Where this draft would be used, when that differs from the finding's URL.
    var targetURL: String = ""

    enum CodingKeys: String, CodingKey {
        case label, text
        case targetURL = "target_url"
    }

    var url: URL? { WebLink.parse(targetURL) }
}

/// Every URL in a report comes from the model, which read it off a page — so it's
/// attacker-influenceable text, and it ends up at `NSWorkspace.open`. `URL(string:)`
/// happily builds `file:///…`, `smb://…` or any custom scheme, which would turn a
/// prompt injection on a visited page into "Claudette opened a local resource".
///
/// Parsing goes through here so there's one place that decides, and a new call site
/// can't quietly skip the check.
enum WebLink {
    static func parse(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return nil }
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        guard let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}

/// One result. A person, a page, a product, a post — whatever the goal was about.
struct Finding: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String = ""
    var subtitle: String = ""
    var url: String = ""
    /// Short factual chips the agent read off the page.
    var details: [String] = []
    var why: String = ""
    var confidence: Confidence = .medium
    var drafts: [Draft] = []

    enum CodingKeys: String, CodingKey {
        case title, subtitle, url, details, why, confidence, drafts
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

    var link: URL? { WebLink.parse(url) }
}

/// The result of one browser task — the sidecar's structured output.
struct TaskReport: Codable, Hashable {
    var goal: String = ""
    var summary: String = ""
    var findings: [Finding] = []
    var blockedReason: String = ""

    enum CodingKeys: String, CodingKey {
        case goal, summary, findings
        case blockedReason = "blocked_reason"
    }

    var isEmpty: Bool { findings.isEmpty }
    var draftCount: Int { findings.reduce(0) { $0 + $1.drafts.count } }

    /// Markdown rendering, used by "Copy all" and by "Send to chat" so Claude can
    /// pick the results up and rework them in the normal conversation.
    func markdown() -> String {
        var out = "## \(goal.isEmpty ? "Browser task" : goal)\n\n"
        if !summary.isEmpty { out += summary + "\n\n" }
        if !blockedReason.isEmpty { out += "> Run stopped early: \(blockedReason)\n\n" }

        for finding in findings {
            out += "### \(finding.title.isEmpty ? "Untitled result" : finding.title)"
            if !finding.subtitle.isEmpty { out += " — \(finding.subtitle)" }
            out += "\n"
            if !finding.url.isEmpty { out += "\(finding.url)\n" }
            if !finding.details.isEmpty { out += finding.details.joined(separator: " · ") + "\n" }
            if !finding.why.isEmpty { out += "\n_Why:_ \(finding.why)\n" }
            for draft in finding.drafts {
                out += "\n**\(draft.label.isEmpty ? "Draft" : draft.label)**\n"
                if !draft.targetURL.isEmpty { out += "\(draft.targetURL)\n" }
                out += "\n\(draft.text)\n"
            }
            out += "\n"
        }
        return out
    }
}

/// One line of live progress from the running agent — what it's looking at and
/// what it decided to do next. Rendered as the scrolling trace in the panel.
struct BrowserStep: Identifiable, Equatable {
    let id = UUID()
    var number: Int
    var url: String
    var title: String
    var goal: String
    var evaluation: String
    var actions: [String]

    /// Host plus path, so "example.com/search/results" reads at a glance instead
    /// of a 300-character query string.
    var shortURL: String {
        guard let u = URL(string: url), let host = u.host else { return url }
        let path = u.path
        return path.isEmpty || path == "/" ? host : host + path
    }
}
