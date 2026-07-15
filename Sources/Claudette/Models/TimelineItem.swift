import Foundation

struct TimelineItem: Identifiable, Equatable {
    let id: UUID
    var kind: Kind
    var createdAt: Date

    init(id: UUID = UUID(), kind: Kind, createdAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
    }

    enum Kind: Equatable {
        case userText(String, images: [UserImage] = [])
        case assistantText(text: String, isStreaming: Bool)
        case thinking(String)
        case action(ActionEvent)
        case system(String)
        case pendingPermission(PendingPermission)
    }
}

/// Claude Code has asked "can I use this tool?" via a `control_request` event.
/// Instead of a modal, we render this inline in the timeline as a conversational
/// question — the next user utterance becomes the answer. Voice-friendly: the
/// prompt text is spoken via TTS in orb mode; the user replies by talking back.
struct PendingPermission: Equatable, Identifiable {
    let id: UUID
    /// The CLI's `request_id` — echoed back on control_response so it knows
    /// which pending prompt we're answering.
    let requestId: String
    /// Tool name from the request (e.g. "Bash", "WebFetch").
    let toolName: String
    /// One-line summary of the tool's input, safe to show in the card and
    /// speak via TTS. For Bash this is the command; for other tools it's a
    /// short JSON preview.
    let summary: String
    /// Full input JSON, pretty-printed. Shown in the card's expanded body.
    let inputJSON: String
    /// Natural-language question Claudette asked ("May I run …?"). Kept on
    /// the model so the timeline still reads cleanly if the user scrolls
    /// back to a resolved permission from an earlier turn.
    let prompt: String
    var status: Status
    /// Free-text reason the user gave. Present on `.denied` (their guidance
    /// verbatim, so Claude can respond to it); nil on `.allowed`.
    var reason: String?

    enum Status: String { case pending, allowed, denied }

    init(id: UUID = UUID(),
         requestId: String,
         toolName: String,
         summary: String,
         inputJSON: String,
         prompt: String,
         status: Status = .pending,
         reason: String? = nil) {
        self.id = id
        self.requestId = requestId
        self.toolName = toolName
        self.summary = summary
        self.inputJSON = inputJSON
        self.prompt = prompt
        self.status = status
        self.reason = reason
    }
}

/// An image attached to a user message. Stored inline so it survives session
/// state changes and can be rendered as a thumbnail in the timeline without
/// re-reading from disk.
struct UserImage: Equatable, Identifiable {
    let id: UUID
    let data: Data
    /// MIME type like "image/png" — used verbatim in the Anthropic content block.
    let mediaType: String
    /// Original filename if the image came from disk; nil for direct drops
    /// (e.g. an image dragged out of a browser without a filename).
    let filename: String?

    init(id: UUID = UUID(), data: Data, mediaType: String, filename: String? = nil) {
        self.id = id
        self.data = data
        self.mediaType = mediaType
        self.filename = filename
    }
}

struct ActionEvent: Identifiable, Equatable {
    let id: String
    var name: String
    var inputJSON: String
    var startedAt: Date
    var status: Status
    var result: String
    var isError: Bool

    // Extracted fields for skimmable display
    var filePath: String?
    var command: String?
    var pattern: String?
    var url: String?
    var oldString: String?
    var newString: String?
    var edits: [EditPair]?
    var description: String?
    var content: String?
    var summary: String?
    var todos: [TodoEntry]?
    var questions: [InteractiveQuestion]?

    enum Status: String {
        case running, success, error
    }

    var category: ActionCategory {
        ActionCategory.of(toolName: name)
    }

    var humanTitle: String {
        switch category {
        case .edit, .multiEdit:
            if let file = shortFile { return "Editing \(file)" }
            return "Editing file"
        case .write:
            if let file = shortFile { return "Writing \(file)" }
            return "Writing file"
        case .read:
            if let file = shortFile { return "Reading \(file)" }
            return "Reading file"
        case .bash:
            return command.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? "Running command"
        case .search:
            if let p = pattern, !p.isEmpty { return "Searching for \(p)" }
            return "Searching"
        case .glob:
            if let p = pattern, !p.isEmpty { return "Finding files: \(p)" }
            return "Finding files"
        case .web:
            if let u = url { return "Fetching \(hostname(u))" }
            return "Fetching URL"
        case .todo:
            return "Updating plan"
        case .task:
            return description ?? "Running sub-agent"
        case .ask:
            if let q = questions?.first?.question, !q.isEmpty { return q }
            return "Asking a question"
        case .other:
            return name
        }
    }

    /// Short one-line preview shown next to the title on the compact card.
    var summaryChip: String? {
        switch category {
        case .edit, .multiEdit:
            let stats = diffStats
            if stats.additions == 0 && stats.deletions == 0 { return nil }
            return "+\(stats.additions) −\(stats.deletions)"
        case .write:
            let lines = (newString ?? content ?? "").split(separator: "\n").count
            return lines > 0 ? "\(lines) line\(lines == 1 ? "" : "s")" : nil
        case .read:
            if !result.isEmpty && status == .success {
                let lines = result.split(separator: "\n").count
                if lines > 0 { return "\(lines) line\(lines == 1 ? "" : "s")" }
            }
            return nil
        case .search, .glob:
            if status == .success && !result.isEmpty {
                let count = result.split(separator: "\n").count
                return "\(count) match\(count == 1 ? "" : "es")"
            }
            return nil
        case .bash:
            return exitCodeSummary
        case .todo:
            if let t = todos, !t.isEmpty {
                let done = t.filter { $0.status == "completed" }.count
                return "\(done)/\(t.count)"
            }
            return nil
        default:
            return nil
        }
    }

    var diffStats: (additions: Int, deletions: Int) {
        if let edits = edits, !edits.isEmpty {
            return edits.reduce((0, 0)) { acc, pair in
                let s = lineDiffStats(old: pair.old, new: pair.new)
                return (acc.0 + s.additions, acc.1 + s.deletions)
            }
        }
        if let old = oldString, let new = newString {
            return lineDiffStats(old: old, new: new)
        }
        if let content = content ?? newString {
            let lines = content.split(separator: "\n").count
            return (lines, 0)
        }
        return (0, 0)
    }

    private var exitCodeSummary: String? {
        // Bash results often include an exit code line at the end; keep it simple
        if isError { return "failed" }
        if status == .success { return nil }
        return nil
    }

    var shortFile: String? {
        guard let filePath else { return nil }
        return (filePath as NSString).lastPathComponent
    }

    private func hostname(_ url: String) -> String {
        URL(string: url)?.host ?? url
    }
}

struct EditPair: Equatable {
    var old: String
    var new: String
}

struct TodoEntry: Equatable {
    var content: String
    var status: String   // "pending", "in_progress", "completed"
    var priority: String?
}

struct InteractiveQuestion: Equatable {
    var question: String
    var header: String?
    var multiSelect: Bool
    var options: [InteractiveOption]
}

struct InteractiveOption: Equatable {
    var label: String
    var description: String?
}

enum ActionCategory {
    case read, edit, multiEdit, write, bash, search, glob, web, todo, task, ask, other

    static func of(toolName: String) -> ActionCategory {
        switch toolName.lowercased() {
        case "read": return .read
        case "edit": return .edit
        case "multiedit": return .multiEdit
        case "write": return .write
        case "bash", "shell": return .bash
        case "grep", "search": return .search
        case "glob": return .glob
        case "webfetch", "webrequest", "webread": return .web
        case "todowrite", "todoread": return .todo
        case "task", "taskcreate", "taskupdate", "agent": return .task
        case "askuserquestion", "userquestion", "ask": return .ask
        default: return .other
        }
    }

    var icon: String {
        switch self {
        case .read: return "doc.text"
        case .edit, .multiEdit: return "pencil"
        case .write: return "square.and.pencil"
        case .bash: return "terminal"
        case .search: return "magnifyingglass"
        case .glob: return "line.3.horizontal.decrease.circle"
        case .web: return "globe"
        case .todo: return "checklist"
        case .task: return "sparkles"
        case .ask: return "hand.raised"
        case .other: return "wrench.and.screwdriver"
        }
    }

    /// A soft tint used for icon backgrounds. Kept muted so the timeline stays calm.
    var tintHex: UInt32 {
        switch self {
        case .read: return 0x6A8AAF        // blue
        case .edit, .multiEdit: return 0xC96442  // accent orange
        case .write: return 0x8A6AAF       // purple
        case .bash: return 0x5A5854        // graphite
        case .search: return 0x8A7B4E      // muted gold
        case .glob: return 0x8A7B4E
        case .web: return 0x4E8A7A         // teal
        case .todo: return 0x7A8A4E        // olive
        case .task: return 0xC96442
        case .ask: return 0x8A6AAF         // purple
        case .other: return 0x6C6459
        }
    }
}

// MARK: - Simple line-diff stats

func lineDiffStats(old: String, new: String) -> (additions: Int, deletions: Int) {
    let oldLines = old.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let newLines = new.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    // Straight-line diff: a line is "removed" if not in new, "added" if not in old.
    // For an accurate count without LCS, we use a multiset delta.
    var oldCounts: [String: Int] = [:]
    var newCounts: [String: Int] = [:]
    for l in oldLines { oldCounts[l, default: 0] += 1 }
    for l in newLines { newCounts[l, default: 0] += 1 }
    var adds = 0
    var dels = 0
    for (line, count) in newCounts {
        let inOld = oldCounts[line] ?? 0
        if count > inOld { adds += count - inOld }
    }
    for (line, count) in oldCounts {
        let inNew = newCounts[line] ?? 0
        if count > inNew { dels += count - inNew }
    }
    return (adds, dels)
}
