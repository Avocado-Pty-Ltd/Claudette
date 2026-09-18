import Foundation

/// What one composition attempt produced.
///
/// File scope rather than nested in `RecipeComposer`: it's handed back from a
/// `nonisolated` call, and a type nested in a `@MainActor` class inherits that
/// isolation.
private enum ComposeOutcome: Sendable {
    case success(json: String, recipe: BrowserRecipe)
    case failure(String)
}

/// Turns a plain-English description into a browser-task recipe by asking Claude.
///
/// Rides the `claude` CLI the user already has authenticated, the same way
/// `ConversationalInterpreter` does: a one-shot `--print` call in a throwaway
/// session with no tools and no `--resume`, so it neither needs an API key of its
/// own nor pollutes the project conversation.
///
/// The hard part of a recipe isn't the JSON — it's knowing what to put in
/// `instructions`. That's exactly the part a model is good at drafting and a
/// form isn't.
@MainActor
final class RecipeComposer: ObservableObject {
    @Published private(set) var state: State = .idle

    enum State: Equatable {
        case idle
        case working
        /// Raw JSON as the model wrote it, plus the decoded recipe for the preview.
        case ready(json: String, recipe: BrowserRecipe)
        case failed(String)

        var isWorking: Bool { self == .working }
    }

    private var task: Task<Void, Never>?

    func compose(description: String) {
        let text = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !state.isWorking else { return }

        task?.cancel()
        state = .working
        task = Task { [weak self] in
            let outcome = await Self.run(description: text)
            guard !Task.isCancelled, let self else { return }
            switch outcome {
            case .success(let json, let recipe):
                self.state = .ready(json: json, recipe: recipe)
            case .failure(let message):
                self.state = .failed(message)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        if state.isWorking { state = .idle }
    }

    func reset() {
        cancel()
        state = .idle
    }

    // MARK: - The call

    nonisolated private static func run(description: String) async -> ComposeOutcome {
        guard let claudePath = ClaudeChatSession.locateClaudeBinary() else {
            return .failure("Couldn't find the `claude` CLI on your PATH. Recipe writing uses the Claude Code you're already signed into.")
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: claudePath)
        // One-shot, no tools, no --resume: a throwaway session that writes nothing
        // and leaves the user's project conversation alone.
        task.arguments = [
            "--print",
            "--model", "sonnet",
            "--output-format", "text",
            "--permission-mode", "plan",
            buildPrompt(description: description)
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

        let raw: String = await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
                task.terminationHandler = { proc in
                    let out = stdout.fileHandleForReading.readDataToEndOfFile()
                    let err = stderr.fileHandleForReading.readDataToEndOfFile()
                    let text = String(data: out, encoding: .utf8) ?? ""
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       proc.terminationStatus != 0 {
                        // Surface the CLI's own complaint — usually "not logged in".
                        let detail = String(data: err, encoding: .utf8) ?? ""
                        cont.resume(returning: "\u{0}" + detail)
                    } else {
                        cont.resume(returning: text)
                    }
                }
                do {
                    try task.run()
                } catch {
                    cont.resume(returning: "\u{0}" + error.localizedDescription)
                }
            }
        } onCancel: {
            if task.isRunning { task.terminate() }
        }

        if raw.hasPrefix("\u{0}") {
            let detail = String(raw.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(detail.isEmpty
                ? "The claude CLI exited without writing anything. Is it signed in? Try `claude auth`."
                : "The claude CLI failed: \(detail.prefix(400))")
        }

        guard let json = extractJSONObject(from: raw) else {
            let preview = raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)
            return .failure("Claude didn't return a JSON recipe. It said: \(preview)")
        }
        guard let data = json.data(using: .utf8) else {
            return .failure("Claude's recipe wasn't valid text.")
        }
        do {
            var recipe = try JSONDecoder().decode(BrowserRecipe.self, from: data)
            if recipe.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                recipe.name = "Untitled recipe"
            }
            return .success(json: json, recipe: recipe)
        } catch {
            return .failure("Claude's recipe didn't fit the format: \(error.localizedDescription)")
        }
    }

    // MARK: - Prompt

    nonisolated private static func buildPrompt(description: String) -> String {
        // Cap the description so a pasted essay doesn't balloon the call.
        let capped = description.count > 4000
            ? String(description.prefix(4000)) + "…"
            : description

        return """
        You are writing a single configuration file for Claudette, a macOS app that \
        drives the open-source `browser-use` agent through a website and reports back.

        A "recipe" is a saved browser task. Here is the complete format — every field \
        is optional except `name`:

        {
          "name": string,              // short, human. Shows in a picker.
          "icon": string,              // an SF Symbol name, e.g. "tag", "cart", "newspaper", "person.2". Default "globe".
          "goal": string,              // the task itself, in the user's voice. REQUIRED if you set a schedule.
          "goalPlaceholder": string,   // hint text under the goal box for ad-hoc runs
          "startURL": string,          // where the agent opens
          "allowedDomains": [string],  // globs the agent is fenced to, e.g. ["*.example.com"]
          "readOnly": bool,            // default true. See below.
          "maxFindings": number,       // how many results to aim for. 3–10 is sensible.
          "instructions": string,      // THE IMPORTANT ONE. See below.
          "drafts": [                  // text to write for each result. Omit if the task is pure research.
            { "label": string, "limit": number|null, "guidance": string }
          ],
          "schedule": {                // omit entirely unless the user asked for one
            "enabled": bool,
            "days": [string],          // "monday".."sunday", or a group: "weekdays", "weekends", "daily"
            "at": string | [string],   // "09:00", "9:30am", or a name: "morning" (09:00), "midday", "afternoon", "evening", "night"
            "catchUpIfMissed": bool    // default false
          },
          "_comment": string           // optional: anything the user should know or check. Ignored by the app.
        }

        `instructions` is handed to the browsing agent verbatim and is where the real \
        substance goes. Write it as the user's own rules, in plain English: which pages \
        are worth opening, what counts as a good result, what to ignore, what to record \
        about each one. Several sentences. Be concrete. This field is the difference \
        between a recipe that works and one that wanders.

        `readOnly: true` means the agent can search, filter, sort, paginate and read, \
        but cannot submit a form, post, send, apply, subscribe or buy. Keep it true \
        unless the user's description clearly requires clicking through something — \
        and if you do set it false, say why in `_comment`.

        Use `drafts` when the user wants text written for each result (a reply, a note, \
        a message). Set `limit` when the destination has a character cap the user \
        mentioned; otherwise null.

        Only include `schedule` if the user asked for the task to run on its own. If \
        you include it, you must also write a concrete `goal`, because nobody is at the \
        keyboard to type one when it fires.

        If the description doesn't say which site, infer a sensible `startURL` and \
        `allowedDomains` only when they're obvious; otherwise leave them out and note \
        it in `_comment` rather than guessing at a URL that may not exist.

        Here is what the user wants:
        \"\"\"
        \(capped)
        \"\"\"

        Respond with EXACTLY ONE JSON object and nothing else — no markdown fences, no \
        prose before or after. Use two-space indentation.
        """
    }

    /// Pulls the first balanced `{ … }` object out of the model's response.
    /// Defensive because models sometimes wrap JSON in fences or leading prose.
    /// Brace counting is string-aware so a `{` inside `instructions` can't end it.
    nonisolated static func extractJSONObject(from raw: String) -> String? {
        guard let start = raw.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        for idx in raw[start...].indices {
            let ch = raw[idx]
            if escaped {
                escaped = false
                continue
            }
            if inString {
                if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
                continue
            }
            switch ch {
            case "\"": inString = true
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return String(raw[start...idx]) }
            default: break
            }
        }
        return nil
    }
}
