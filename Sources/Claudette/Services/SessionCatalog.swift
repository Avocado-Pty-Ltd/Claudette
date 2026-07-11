import Foundation

/// A past chat session for a given project, as stored by the `claude` CLI at
/// `~/.claude/projects/<slug>/<session-id>.jsonl`.
struct SessionInfo: Identifiable, Equatable {
    let id: String              // session_id (== filename minus .jsonl)
    var title: String           // first user prompt, best-effort
    var modifiedAt: Date
    var messageCount: Int       // rough count of user+assistant records
    var fileURL: URL
}

enum SessionCatalog {
    /// Return the sessions for `project` sorted by most recently modified.
    static func sessions(for project: Project) -> [SessionInfo] {
        let dir = projectsRoot().appendingPathComponent(slug(for: project.path), isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return [] }

        var results: [SessionInfo] = []
        for url in files where url.pathExtension == "jsonl" {
            let sessionId = url.deletingPathExtension().lastPathComponent
            guard UUID(uuidString: sessionId) != nil else { continue }
            let mDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            let (title, msgs) = summarize(url: url)
            results.append(SessionInfo(
                id: sessionId,
                title: title,
                modifiedAt: mDate,
                messageCount: msgs,
                fileURL: url
            ))
        }
        return results.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// Locate the JSONL file for a specific session ID under `project`. Rejects any
    /// value that isn't a valid UUID so a slash-command like `/resume ../../etc/passwd`
    /// can't traverse outside the project session directory.
    static func sessionURL(for project: Project, sessionId: String) -> URL? {
        guard UUID(uuidString: sessionId) != nil else { return nil }
        let dir = projectsRoot().appendingPathComponent(slug(for: project.path), isDirectory: true)
        let candidate = dir.appendingPathComponent("\(sessionId).jsonl")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    // MARK: - Helpers

    private static func projectsRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    /// Claude Code slugifies the absolute path by prepending `-` and replacing `/` with `-`.
    private static func slug(for path: String) -> String {
        let stripped = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return "-" + stripped.replacingOccurrences(of: "/", with: "-")
    }

    /// Peek at the JSONL to pull out a rough title (first user message) and message count.
    /// Reads only what's needed: bounded scan of the file.
    private static func summarize(url: URL) -> (title: String, count: Int) {
        guard let data = try? Data(contentsOf: url) else { return ("(session)", 0) }
        guard let text = String(data: data, encoding: .utf8) else { return ("(session)", 0) }
        var title: String? = nil
        var count = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            let type = obj["type"] as? String
            if type == "user" || type == "assistant" { count += 1 }
            if title == nil, type == "user", let msg = obj["message"] as? [String: Any] {
                if let s = msg["content"] as? String {
                    title = firstLine(of: s)
                } else if let arr = msg["content"] as? [[String: Any]] {
                    for block in arr {
                        if block["type"] as? String == "text", let t = block["text"] as? String {
                            title = firstLine(of: t)
                            break
                        }
                    }
                }
            }
        }
        return (title ?? "(session)", count)
    }

    private static func firstLine(of text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = trimmed.split(separator: "\n").first.map(String.init) ?? trimmed
        let limit = 80
        if firstLine.count > limit { return String(firstLine.prefix(limit)) + "…" }
        return firstLine
    }
}
