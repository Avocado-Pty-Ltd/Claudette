import Foundation

/// Runs a cheap Haiku pass over a completed turn to produce conversational output:
///
/// - `narration`: one warm, first-person sentence for TTS.
/// - `tags`: 4–8 single- or two-word ideas to fly around the orb.
/// - `snippets`: 2–4 short display strings (verbs, filenames, one-line code beats).
///
/// The heavy Claude turn already ran; this is a purely descriptive follow-up so
/// the voice/orb layer doesn't sound like a status monitor.
@MainActor
final class ConversationalInterpreter {
    struct Interpretation: Equatable, Codable {
        var narration: String
        var tags: [String]
        var snippets: [String]
    }

    private var currentTask: Task<Void, Never>?

    /// Cancels any in-flight interpretation and starts a new one. Delivers to `completion`
    /// on the main actor; nil means the pass failed or was skipped (fall back to heuristics).
    func interpret(
        assistantText: String,
        actionPhrases: [String],
        completion: @escaping @MainActor (Interpretation?) -> Void
    ) {
        currentTask?.cancel()
        let text = assistantText
        let phrases = actionPhrases
        currentTask = Task {
            let result = await Self.run(assistantText: text, actionPhrases: phrases)
            guard !Task.isCancelled else { return }
            await MainActor.run { completion(result) }
        }
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }

    // MARK: - Implementation

    nonisolated private static func run(assistantText: String, actionPhrases: [String]) async -> Interpretation? {
        guard let claudePath = ClaudeChatSession.locateClaudeBinary() else { return nil }
        let prompt = buildPrompt(assistantText: assistantText, actionPhrases: actionPhrases)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: claudePath)
        // `--print` = one-shot, `--model haiku` = cheap+fast. We don't pass `--resume`
        // so this call runs in a fresh throwaway session and doesn't pollute the user's
        // real project session. No tools allowed — we only want text back.
        task.arguments = [
            "--print",
            "--model", "haiku",
            "--output-format", "text",
            "--permission-mode", "plan",
            prompt
        ]

        let stdout = Pipe()
        let stderr = Pipe()
        task.standardOutput = stdout
        task.standardError = stderr

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "dumb"
        env["CI"] = "1"
        env["CLAUDE_CODE_DISABLE_TERMINAL_TITLE"] = "1"
        task.environment = env

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Interpretation?, Never>) in
                task.terminationHandler = { _ in
                    let data = stdout.fileHandleForReading.readDataToEndOfFile()
                    let raw = String(data: data, encoding: .utf8) ?? ""
                    cont.resume(returning: parseJSON(raw))
                }
                do {
                    try task.run()
                } catch {
                    cont.resume(returning: nil)
                }
            }
        } onCancel: {
            if task.isRunning { task.terminate() }
        }
    }

    nonisolated private static func buildPrompt(assistantText: String, actionPhrases: [String]) -> String {
        let actions: String
        if actionPhrases.isEmpty {
            actions = "(none)"
        } else {
            actions = actionPhrases.map { "- \($0)" }.joined(separator: "\n")
        }

        // Cap the assistant text so we don't blow up the Haiku call on a 10k-char reply.
        let capped = assistantText.count > 1600
            ? String(assistantText.prefix(1600)) + "…"
            : assistantText

        return """
        You are the warm, conversational voice of a hands-free coding assistant. \
        A turn of work just finished. Convert it into voice-friendly output that \
        will be read aloud and displayed around a glowing orb.

        Actions the assistant took this turn:
        \(actions)

        The assistant's own written reply:
        \"\"\"
        \(capped)
        \"\"\"

        Respond with EXACTLY ONE JSON object and nothing else. No markdown fences, \
        no prose before or after. Schema:

        {
          "narration": string,   // 2–4 natural sentences spoken in first person ("I did X, then Y."). Include the actual conclusion or answer — don't just say what tools ran. Up to ~800 chars. Plain prose only, no markdown.
          "tags":     string[],  // 4–8 single- or two-word ideas summarising what happened. Lower case, no punctuation.
          "snippets": string[]   // 2–4 short (max 40 char) display strings — verbs, filenames, or one-line beats like "swift build ✓" or "+5 −2".
        }

        The narration will be read aloud, so it must sound like a person telling \
        their collaborator what they found out, not a status report. Include the \
        substantive answer or result, not just a summary of the mechanical steps.

        If nothing meaningful happened, still return the schema with a short honest narration \
        and a few reasonable tags.
        """
    }

    /// Pulls the first `{ … }` object out of the model's raw response and decodes it.
    /// Defensive because Haiku sometimes wraps JSON in code fences or leading prose.
    ///
    /// If JSON parsing fails but the model returned prose, treat the prose itself as
    /// narration — a "half-succeed" degraded path that's still way better than the
    /// mechanical action-list fallback that composeTurnSummary produces.
    nonisolated private static func parseJSON(_ raw: String) -> Interpretation? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let obj = extractJSON(from: trimmed) { return obj }

        // No parseable JSON. If Haiku returned prose, salvage it as narration.
        // Strip obvious instruction echo like `Here is the JSON:` or code fences.
        var prose = trimmed
        prose = prose.replacingOccurrences(of: "```[\\s\\S]*?```", with: " ", options: .regularExpression)
        prose = prose.replacingOccurrences(of: "^Here('|)s (the |a |your |).*?JSON.*?:\\s*", with: "", options: [.regularExpression, .caseInsensitive])
        prose = prose.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prose.isEmpty, prose.count < 4000 else { return nil }
        return Interpretation(narration: prose, tags: [], snippets: [])
    }

    nonisolated private static func extractJSON(from trimmed: String) -> Interpretation? {
        guard let start = trimmed.firstIndex(of: "{") else { return nil }
        var depth = 0
        var end: String.Index?
        for idx in trimmed[start...].indices {
            let ch = trimmed[idx]
            if ch == "{" { depth += 1 }
            else if ch == "}" {
                depth -= 1
                if depth == 0 { end = idx; break }
            }
        }
        guard let e = end else { return nil }
        let jsonSlice = trimmed[start...e]

        guard let data = String(jsonSlice).data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Interpretation.self, from: data)
    }
}
