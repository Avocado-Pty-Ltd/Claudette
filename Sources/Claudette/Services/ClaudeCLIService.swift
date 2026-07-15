import Foundation
import Combine
import AppKit

@MainActor
final class ClaudeChatSession: ObservableObject {
    @Published private(set) var timeline: [TimelineItem] = []
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var sessionId: String?
    @Published private(set) var lastError: String?
    @Published private(set) var activeAction: ActionEvent?
    /// Narrator-style summary of what happened in the last completed turn.
    /// Published once per turn end so TTS can speak it exactly once.
    @Published private(set) var lastTurnSummary: String?
    /// Conversational interpretation of the last completed turn — narration to speak,
    /// tags and snippets to fly around the orb. Emitted after a short Haiku pass or
    /// as a heuristic fallback if that pass fails.
    @Published private(set) var interpretation: ConversationalInterpreter.Interpretation?
    /// True while the interpreter is still working on the current turn — used by the
    /// orb to show a "thinking" glow after Claude finishes but before the narration
    /// arrives.
    @Published private(set) var isInterpreting: Bool = false
    /// Short in-flight beats to speak while the turn is running: "let me look at
    /// ChatView.swift", "searching the codebase", "running that command". Emitted
    /// whenever a new tool_use starts. TTS queues these so multiple beats stack.
    @Published private(set) var liveNarration: String?
    /// Visual-only stream of Claude's own reply text, chunked at sentence boundaries.
    /// Unlike `liveNarration` this is NOT spoken by TTS — the final `interpretation`
    /// narration handles TTS. This exists so the crawl can show Claude's live planning
    /// prose ("I'll check the auth middleware first…") as it streams in.
    @Published private(set) var streamingChunk: String?
    /// Rolling buffer rendered inside the orb sphere as the refracted ticker.
    /// This is a HUMAN-READABLE reconstruction of what Claude Code would print
    /// to a terminal — user prompts, `⏺ Tool(args)` call lines, `  ⎿ result`
    /// summaries, and Claude's own streamed prose interleaved. Not the raw
    /// stream-json events (those existed here previously but were unreadable).
    /// Capped at ~8 KB so it never grows without bound.
    @Published private(set) var rawLog: String = ""
    /// In-flight and recently-finished sub-agents from the Task tool. Rendered as
    /// small spheres orbiting the main orb, then dissolving after completion.
    @Published private(set) var subagents: [SubagentState] = []
    /// The most recent set of todos from the TodoWrite tool. Rendered as a floating
    /// checklist panel so the user can see Claude's live plan.
    @Published private(set) var todos: [TodoEntry] = []
    /// The most recent Bash / long-running tool for the monitor panel. Shows the
    /// command + first lines of output when it exists.
    @Published private(set) var latestMonitor: ActionEvent?
    @Published var cwdDisplay: String = ""
    @Published var permissionMode: PermissionMode

    let project: Project

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var buffer = Data()

    // Slash-command preferences that affect the next CLI launch.
    var preferredModel: String?
    /// Overrides `project.lastSessionId` for the next startProcess call. Set via /resume.
    private var pendingResumeSessionId: String?

    /// Maps tool_use id → index into `timeline` so we can update its status when results land.
    private var actionIndexByToolId: [String: Int] = [:]

    /// Ids we've already appended an action item for (so we don't duplicate when the final
    /// assistant message arrives after we've already streamed the tool_use).
    private var seenToolIds: Set<String> = []

    /// The id of the currently streaming assistant text item.
    private var currentAssistantTextId: UUID?

    /// Timeline index at which the current turn began. Everything at or after this index
    /// is fair game for the turn summary that gets narrated when the turn ends.
    private var turnStartIndex: Int = 0

    /// Character offset in the current assistant streaming text past which we've already
    /// emitted crawl beats. Prevents the same sentence from being emitted twice as the
    /// stream continues. Reset on each new turn.
    private var assistantStreamCursor: Int = 0

    private let interpreter = ConversationalInterpreter()
    /// Backstops the interpreter so a hung Haiku call doesn't leave the orb silent.
    private var interpretationTimeoutTask: Task<Void, Never>?

    /// In-flight tool-use permission prompts, as an ordered FIFO queue of the
    /// CLI's request_ids. While non-empty, the next user message is intercepted
    /// by `send()` and routed through `answerPermission` rather than sent to
    /// the CLI as a new user turn — Claude is blocked waiting on our
    /// control_response, so a fresh user message would deadlock the wire.
    ///
    /// Order matters. A dictionary was used previously but Swift dictionary
    /// iteration order is unspecified, so `.first` could route a user reply to
    /// the wrong pending request if two ever queued up. An array preserves
    /// arrival order — the user's reply is always applied to the oldest
    /// pending prompt, matching the on-screen top-to-bottom order of cards.
    private var pendingPermissions: [String] = []

    init(project: Project) {
        self.project = project
        self.cwdDisplay = project.displayPath
        self.permissionMode = project.permissionMode ?? PermissionMode.initial
    }

    // MARK: - Public API

    func send(_ prompt: String, images: [UserImage] = []) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        // Allow image-only messages (no text, but attachments present) so users
        // can drop a screenshot with no accompanying prose and still have the
        // model see it.
        guard !trimmed.isEmpty || !images.isEmpty else { return }

        // Slash commands are handled natively by Claudette, not forwarded to the CLI.
        if trimmed.hasPrefix("/") {
            handleSlashCommand(trimmed)
            return
        }

        // If Claude is blocked on a permission prompt, this message is the answer
        // to that prompt — route it through the control_response wire instead of
        // opening a new user turn. Otherwise the CLI would deadlock (it's still
        // reading for a control_response on the same request_id) and the user's
        // reply would sit in stdin ignored. Answer the OLDEST pending prompt
        // (FIFO), matching the visible top-to-bottom order of the cards.
        if let oldestPending = pendingPermissions.first {
            answerPermission(requestId: oldestPending, userText: prompt, images: images)
            return
        }

        timeline.append(TimelineItem(kind: .userText(prompt, images: images)))
        currentAssistantTextId = nil
        // Everything after the user's message belongs to this turn.
        turnStartIndex = timeline.count
        assistantStreamCursor = 0
        // Header the turn in the pretty log with `> <prompt>`, mirroring what a
        // real terminal shows. Normalize the prompt to a single line so multi-line
        // input doesn't break the single-line header format. Only prepend a
        // separator newline when the log already has content — turn 1 shouldn't
        // start with a blank first line.
        let singleLine = trimmed
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "  ", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let promptPreview = singleLine.count > 200 ? String(singleLine.prefix(200)) + "…" : singleLine
        let separator = rawLog.isEmpty ? "" : "\n"
        appendToPrettyLog("\(separator)> \(promptPreview)\n\n")
        // Speak an opener the moment the turn kicks off so the user hears the orb
        // "start listening" instead of a silent gap until the first tool call.
        liveNarration = Self.openerPhrase()

        if process == nil {
            startProcess(initialPrompt: prompt, images: images)
        } else {
            // Second and subsequent turns on an existing process: startProcess isn't
            // called again, so isRunning was never flipped back on. Do it here so the
            // orb reflects "working" immediately, not only after the first stream
            // event lands.
            isRunning = true
            sendJSONLine([
                "type": "user",
                "message": [
                    "role": "user",
                    "content": Self.contentBlocks(text: prompt, images: images)
                ]
            ])
        }
    }

    /// Build the Anthropic-style content array for a user message. Images
    /// become base64 blocks so Claude Code forwards them straight to the model
    /// — no Read-tool round-trip, no temp files on disk. Text goes first so
    /// the model has the framing before the image, matching how the API docs
    /// recommend ordering for image-plus-text prompts.
    private static func contentBlocks(text: String, images: [UserImage]) -> [[String: Any]] {
        var blocks: [[String: Any]] = []
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            blocks.append(["type": "text", "text": text])
        }
        for img in images {
            blocks.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": img.mediaType,
                    "data": img.data.base64EncodedString()
                ]
            ])
        }
        return blocks
    }

    // MARK: - Slash commands

    private func handleSlashCommand(_ line: String) {
        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        let cmd = parts[0].lowercased()
        let arg = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""

        switch cmd {
        case "/clear", "/new":
            reset()
            appendSystem("New chat.")
        case "/help":
            appendSystem(Self.helpText)
        case "/resume":
            if !arg.isEmpty {
                resume(sessionId: arg)
            } else {
                NotificationCenter.default.post(name: .claudetteShowResumeSheet, object: nil)
            }
        case "/model":
            if arg.isEmpty {
                appendSystem("Usage: /model <sonnet|opus|haiku|full-name>. Current: \(preferredModel ?? "default")")
            } else {
                preferredModel = arg
                appendSystem("Model set to \(arg). Takes effect on the next chat (⌘T to start).")
            }
        case "/mode":
            if arg.isEmpty {
                let names = PermissionMode.allCases.map { $0.cliValue }.joined(separator: ", ")
                appendSystem("Current mode: \(permissionMode.label) (\(permissionMode.cliValue)). Options: \(names).")
            } else if let m = PermissionMode(rawValue: arg) {
                setPermissionMode(m)
            } else if let m = PermissionMode.allCases.first(where: { $0.cliValue.lowercased() == arg.lowercased() || $0.label.lowercased() == arg.lowercased() }) {
                setPermissionMode(m)
            } else {
                appendSystem("Unknown mode: \(arg). Options: \(PermissionMode.allCases.map { $0.cliValue }.joined(separator: ", ")).")
            }
        case "/reveal":
            NSWorkspace.shared.activateFileViewerSelecting([project.url])
        case "/session":
            if let sid = sessionId {
                appendSystem("Session ID: \(sid)")
            } else {
                appendSystem("No session yet — send a message to start one.")
            }
        default:
            appendSystem("Unknown slash command: \(cmd). Try /help.")
        }
    }

    /// Switch permission mode. Takes effect on the next CLI spawn — surfacing the change
    /// mid-conversation would require killing and re-launching, which loses context.
    func setPermissionMode(_ mode: PermissionMode) {
        guard mode != permissionMode else { return }
        permissionMode = mode
        appendSystem("Mode set to \(mode.label). Applies from the next chat (⌘T for fresh, or restart current).")
    }

    /// Public helper used by the resume-picker sheet. Loads the session's transcript
    /// from disk and populates the timeline so the user sees prior messages.
    ///
    /// Anything that isn't a well-formed UUID is rejected — the sessionId flows into
    /// both a filesystem path (SessionCatalog) and the `claude --resume` argv, so we
    /// harden it at the entry point rather than trusting every downstream reader.
    func resume(sessionId: String) {
        guard UUID(uuidString: sessionId) != nil else {
            appendSystem("That doesn't look like a valid session ID.")
            return
        }
        stop()
        timeline.removeAll()
        actionIndexByToolId.removeAll()
        seenToolIds.removeAll()
        currentAssistantTextId = nil
        activeAction = nil
        self.sessionId = sessionId
        pendingResumeSessionId = sessionId

        if let url = SessionCatalog.sessionURL(for: project, sessionId: sessionId) {
            hydrateTimeline(from: url)
        }

        if timeline.isEmpty {
            appendSystem("Resumed session \(String(sessionId.prefix(8))). Send a message to continue.")
        }
    }

    /// Read a session JSONL and replay its user/assistant records into `timeline`.
    /// Historical actions land as `.success` when their tool_result is found.
    private func hydrateTimeline(from url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        guard let text = String(data: data, encoding: .utf8) else { return }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else { continue }
            let type = obj["type"] as? String
            switch type {
            case "user":
                hydrateUserRecord(obj)
            case "assistant":
                // Same shape as a live assistant event — final blocks, no streaming.
                handleAssistantEvent(obj)
            default:
                // queue-operation, attachment, last-prompt, mode, permission-mode — skip.
                break
            }
        }

        // A hydrated action might be missing its tool_result if the session was cut off.
        // Downgrade any lingering .running to .error so the UI doesn't look mid-flight.
        for i in timeline.indices {
            if case var .action(event) = timeline[i].kind, event.status == .running {
                event.status = .error
                event.result = "(no result recorded — session ended before this tool returned)"
                event.isError = true
                timeline[i].kind = .action(event)
            }
        }
        activeAction = nil
    }

    private func hydrateUserRecord(_ obj: [String: Any]) {
        guard let message = obj["message"] as? [String: Any] else { return }

        // Content can be a bare String (older format) or an array of blocks.
        if let str = message["content"] as? String {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                timeline.append(TimelineItem(kind: .userText(trimmed)))
            }
            return
        }
        guard let content = message["content"] as? [[String: Any]] else { return }

        for block in content {
            let bType = block["type"] as? String
            switch bType {
            case "text":
                if let t = block["text"] as? String, !t.isEmpty {
                    timeline.append(TimelineItem(kind: .userText(t)))
                }
            case "tool_result":
                let toolId = block["tool_use_id"] as? String ?? ""
                let isError = (block["is_error"] as? Bool) ?? false
                var resultText = ""
                if let s = block["content"] as? String {
                    resultText = s
                } else if let arr = block["content"] as? [[String: Any]] {
                    resultText = arr.compactMap { $0["text"] as? String }.joined(separator: "\n")
                }
                completeAction(toolId: toolId, result: resultText, isError: isError)
            default:
                break
            }
        }
    }

    private static let helpText: String = """
    /clear or /new — start a fresh chat.
    /resume [id]   — pick a previous session for this folder.
    /model <name>  — switch model (sonnet, opus, haiku) for the next chat.
    /reveal        — open the project folder in Finder.
    /session       — show the current session ID.
    /help          — show this list.
    """

    func stop() {
        process?.terminate()
        cleanup()
    }

    func reset() {
        stop()
        timeline.removeAll()
        actionIndexByToolId.removeAll()
        seenToolIds.removeAll()
        currentAssistantTextId = nil
        activeAction = nil
        sessionId = nil
        lastError = nil
        interpretation = nil
        isInterpreting = false
        liveNarration = nil
        streamingChunk = nil
        assistantStreamCursor = 0
        rawLog = ""
        subagents.removeAll()
        todos.removeAll()
        latestMonitor = nil
        interpretationTimeoutTask?.cancel()
        interpreter.cancel()
    }

    // MARK: - Process lifecycle

    private func startProcess(initialPrompt: String, images: [UserImage] = []) {
        let claudePath = Self.locateClaudeBinary()
        guard let claudePath else {
            appendSystem("Could not find the `claude` CLI on your PATH. Install Claude Code and try again.")
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: claudePath)
        task.currentDirectoryURL = project.url

        var args = [
            "--print",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--permission-mode", permissionMode.cliValue,
            "--include-partial-messages"
        ]
        // Prefer the live sessionId (set by the CLI's `system.init` on the previous run)
        // so multi-turn conversations continue the same Claude Code session. The persisted
        // project.lastSessionId is a fallback for a fresh launch of the app.
        let resumeId = pendingResumeSessionId ?? sessionId ?? project.lastSessionId
        if let resumeId {
            args += ["--resume", resumeId]
        }
        if let preferredModel {
            args += ["--model", preferredModel]
        }
        pendingResumeSessionId = nil
        task.arguments = args

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "dumb"
        env["CI"] = "1"
        env["CLAUDE_CODE_DISABLE_TERMINAL_TITLE"] = "1"
        task.environment = env

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        task.standardInput = stdin
        task.standardOutput = stdout
        task.standardError = stderr

        self.process = task
        self.stdinPipe = stdin
        self.stdoutPipe = stdout
        self.stderrPipe = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in
                self?.appendStdoutData(data)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                self?.handleStderr(str)
            }
        }
        task.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                self?.handleTermination(status: proc.terminationStatus)
            }
        }

        do {
            try task.run()
            isRunning = true
            sendJSONLine([
                "type": "user",
                "message": [
                    "role": "user",
                    "content": Self.contentBlocks(text: initialPrompt, images: images)
                ]
            ])
        } catch {
            appendSystem("Failed to launch claude: \(error.localizedDescription)")
            cleanup()
        }
    }

    private func handleTermination(status: Int32) {
        isRunning = false
        activeAction = nil
        // Ignore normal exits: 0 = clean, 15 = SIGTERM (we killed it),
        // 143 = 128+SIGTERM which is how `claude --print` reports its own end-of-turn exit.
        if status != 0 && status != 15 && status != 143 {
            appendSystem("Claude process exited with status \(status).")
        }
        finalizeStreamingText()
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
    }

    private func cleanup() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        isRunning = false
        activeAction = nil
        finalizeStreamingText()
    }

    private func sendJSONLine(_ dict: [String: Any]) {
        guard let stdin = stdinPipe else { return }
        do {
            let data = try JSONSerialization.data(withJSONObject: dict, options: [])
            var line = data
            line.append(0x0A)
            try stdin.fileHandleForWriting.write(contentsOf: line)
        } catch {
            appendSystem("Failed to send message: \(error.localizedDescription)")
        }
    }

    // MARK: - Stdout parsing

    private func appendStdoutData(_ data: Data) {
        buffer.append(data)
        // Note: we deliberately do NOT mirror the raw stream-json into rawLog.
        // The individual event handlers below (handleAssistantEvent, completeAction,
        // appendStreamingText, etc.) synthesise a human-readable "pretty CLI" log
        // via appendToPrettyLog(…) so the orb ticker renders something legible.
        while let newlineIdx = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[..<newlineIdx]
            buffer.removeSubrange(...newlineIdx)
            if lineData.isEmpty { continue }
            handleStreamLine(Data(lineData))
        }
    }

    /// Append a chunk of pretty-CLI text to the rolling log, trimmed to ~8 KB.
    /// Callers pass either a full line ending in "\n" or an inline delta (for
    /// streaming prose) — either way, the buffer stays bounded and the orb
    /// re-renders on the @Published change.
    private func appendToPrettyLog(_ text: String) {
        guard !text.isEmpty else { return }
        rawLog += text
        let cap = 8000
        if rawLog.count > cap {
            rawLog = String(rawLog.dropFirst(rawLog.count - cap))
        }
    }

    private func handleStreamLine(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                NSLog("Claudette: non-JSON stdout: \(str)")
            }
            return
        }
        let type = obj["type"] as? String ?? ""
        switch type {
        case "system":
            handleSystemEvent(obj)
        case "assistant":
            // Any assistant activity means Claude is working. This flip is defensive:
            // between turns in a long-running process, isRunning would otherwise stay
            // false until a fresh startProcess, so the orb showed "idle" while Claude
            // was actually mid-turn.
            isRunning = true
            handleAssistantEvent(obj)
        case "user":
            isRunning = true
            handleUserEcho(obj)
        case "stream_event":
            isRunning = true
            handlePartialEvent(obj)
        case "result":
            handleResultEvent(obj)
        case "control_request":
            handleControlRequest(obj)
        default:
            NSLog("Claudette: unknown event type '\(type)'")
        }
    }

    // MARK: - Permission-prompt wire (control_request / control_response)
    //
    // Claude Code emits `control_request` whenever the model wants to use a
    // tool that isn't blanket-allowed by the current --permission-mode (Bash
    // and WebFetch are the common ones). The CLI blocks reading stdin for the
    // matching `control_response` before making the tool call, so we MUST
    // respond eventually or the turn deadlocks and Claude "loses the plot"
    // — hallucinating tool results or drifting off-topic.
    //
    // We turn each request into a conversational card in the timeline and
    // route the user's next utterance through `answerPermission`, rather
    // than showing a modal Allow/Deny dialog. That keeps the voice-first
    // flow intact ("May I run firebase deploy?" → user says "yeah").

    /// Parse a control_request event and turn it into a PendingPermission
    /// timeline card. Only `subtype: "can_use_tool"` is meaningfully surfaced
    /// today — anything else we auto-allow (Claude Code has other subtypes for
    /// its own internal signalling that don't want user attention).
    private func handleControlRequest(_ obj: [String: Any]) {
        guard let requestId = obj["request_id"] as? String,
              let request = obj["request"] as? [String: Any],
              let subtype = request["subtype"] as? String else {
            NSLog("Claudette: malformed control_request: %@", String(describing: obj))
            return
        }
        guard subtype == "can_use_tool" else {
            // Auto-ack any subtype we don't understand so the CLI doesn't stall.
            // Interrupt requests and similar are typically transparent to users.
            sendControlResponse(requestId: requestId, behavior: .allow)
            return
        }
        let toolName = (request["tool_name"] as? String) ?? "the tool"
        let input = (request["input"] as? [String: Any]) ?? [:]

        let summary = Self.summarize(toolName: toolName, input: input)
        let inputJSON = Self.prettyPrintJSON(input)
        let prompt = Self.composePermissionPrompt(toolName: toolName, summary: summary)

        let pending = PendingPermission(
            requestId: requestId,
            toolName: toolName,
            summary: summary,
            inputJSON: inputJSON,
            prompt: prompt
        )
        timeline.append(TimelineItem(kind: .pendingPermission(pending)))
        pendingPermissions.append(requestId)

        // Surface the ask into the voice channel too so orb mode isn't silent
        // while the user stares at a paused sphere.
        liveNarration = prompt

        // Claude is no longer "thinking" while waiting on the user — flip the
        // orb / activity indicator off so the UX reflects "your move".
        isRunning = false
        activeAction = nil
        appendToPrettyLog("? \(prompt)\n")
    }

    /// The user has typed / spoken a response while a permission was pending.
    /// Classify their intent, update the pending card, and forward the
    /// verdict as a control_response so Claude can resume.
    ///
    /// Images are preserved in the timeline entry so an attached screenshot
    /// (e.g. "here's why I'm skipping this") isn't silently dropped. They
    /// don't ride on the control_response wire — the CLI's response schema
    /// has no image slot — but they DO stay visible in the conversation.
    /// If the user sends images with no text, we treat it as a deny with a
    /// generic message: image-only replies to a yes/no prompt are almost
    /// never an affirmation of a destructive command.
    private func answerPermission(requestId: String, userText: String, images: [UserImage] = []) {
        // Show the user's answer in the timeline like a normal message, so the
        // pending card + response read as a natural conversation exchange.
        timeline.append(TimelineItem(kind: .userText(userText, images: images)))

        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        let intent: PermissionIntent = trimmed.isEmpty
            ? .deny   // image-only reply — not an affirmation
            : Self.classifyPermissionIntent(trimmed)
        switch intent {
        case .allow:
            sendControlResponse(requestId: requestId, behavior: .allow)
            updatePendingPermission(requestId: requestId) { p in
                p.status = .allowed
            }
            appendToPrettyLog("  ⎿ approved: \(trimmed)\n")
        case .deny:
            // Pass the user's exact words to Claude via the deny message so
            // the model sees the guidance ("run staging instead", "wait,
            // check the tests first") and can act on it in the next turn
            // rather than just seeing a bare "denied". Image-only replies
            // get a stock message; images themselves stay visible in the
            // timeline but don't go on the wire.
            let denyMessage = trimmed.isEmpty ? "User attached image(s) instead of approving." : trimmed
            sendControlResponse(requestId: requestId, behavior: .deny, message: denyMessage)
            updatePendingPermission(requestId: requestId) { p in
                p.status = .denied
                p.reason = trimmed.isEmpty ? nil : trimmed
            }
            appendToPrettyLog("  ⎿ denied: \(denyMessage)\n")
        }
        pendingPermissions.removeAll { $0 == requestId }
        // Claude will resume work on either verdict — allow triggers the tool
        // call, deny surfaces the user's message as the tool result and the
        // model composes a fresh reply.
        isRunning = true
    }

    /// Write the JSON envelope Claude Code expects on stdin for a permission
    /// verdict. See the Claude Agent SDK docs for the control_response shape;
    /// the CLI matches on `request_id` inside `response`.
    private func sendControlResponse(requestId: String,
                                     behavior: PermissionBehavior,
                                     message: String? = nil) {
        var innerResponse: [String: Any] = ["behavior": behavior.rawValue]
        if let message, behavior == .deny {
            innerResponse["message"] = message
        }
        sendJSONLine([
            "type": "control_response",
            "response": [
                "subtype": "success",
                "request_id": requestId,
                "response": innerResponse
            ]
        ])
    }

    private enum PermissionBehavior: String { case allow, deny }

    /// Find the pending permission by request_id, mutate it in place in the
    /// timeline, and re-publish so the card re-renders with the new status.
    private func updatePendingPermission(requestId: String,
                                         _ mutate: (inout PendingPermission) -> Void) {
        for i in timeline.indices.reversed() {
            if case var .pendingPermission(p) = timeline[i].kind, p.requestId == requestId {
                mutate(&p)
                timeline[i].kind = .pendingPermission(p)
                return
            }
        }
    }

    private enum PermissionIntent { case allow, deny }

    /// Local heuristic for "did the user say yes?" — deliberately conservative
    /// so ambiguous replies get routed through deny (with the user's words as
    /// the message), letting Claude interpret the guidance itself. False
    /// negatives are cheap (Claude just re-plans); false positives would run
    /// destructive commands the user didn't sanction.
    ///
    /// The classifier matches the ENTIRE normalised reply against a small
    /// whitelist of pure affirmations. An earlier version scanned individual
    /// tokens against a `yes` set, which meant "run staging instead" (contains
    /// `run`) or "ok but wait" (contains `ok`) would incorrectly allow a
    /// destructive tool call — the exact failure mode this classifier is
    /// supposed to prevent. Whole-phrase matching is more restrictive but
    /// unambiguous: if in doubt, deny and let the user's words guide Claude.
    private static func classifyPermissionIntent(_ text: String) -> PermissionIntent {
        // Normalise: lowercase, strip punctuation, collapse whitespace, trim.
        let cleaned = text
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9 ]", with: "", options: .regularExpression)
            .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return .deny }
        return allowPhrases.contains(cleaned) ? .allow : .deny
    }

    /// Complete phrases that count as an unambiguous "yes, run it". Extend
    /// with care — anything added here must be a self-contained affirmation
    /// with no possible qualifying tail. Colloquial variants are welcome
    /// ("yeah go for it"); anything that could be a fragment of a longer
    /// instruction ("run", "do") is not.
    private static let allowPhrases: Set<String> = [
        "y", "yes", "yep", "yup", "yeah", "yea",
        "ok", "okay", "k",
        "sure", "sure thing",
        "go", "go ahead", "go for it",
        "do it", "run it", "please do", "please",
        "confirm", "confirmed", "approved", "approve",
        "affirmative", "correct", "right",
        "yes please", "ok please",
        "yes go ahead", "yeah go ahead", "sure go ahead",
        "yes do it", "yeah do it", "sure do it",
        "yes run it", "yeah run it",
        "fine", "sounds good", "sounds good to me"
    ]

    /// Compose a natural sentence for the permission ask. Bash gets the
    /// command inline; other tools get a shorter framing since their input
    /// isn't as immediately readable.
    private static func composePermissionPrompt(toolName: String, summary: String) -> String {
        let lower = toolName.lowercased()
        switch lower {
        case "bash":
            return "May I run `\(summary)`?"
        case "webfetch", "webrequest", "webread":
            return "May I fetch \(summary)?"
        default:
            return "May I use the \(toolName) tool with \(summary)?"
        }
    }

    /// One-line human-readable summary of a tool_use input, safe for a card
    /// header and for TTS. Falls back to a compact JSON string for tools we
    /// don't special-case.
    private static func summarize(toolName: String, input: [String: Any]) -> String {
        switch toolName.lowercased() {
        case "bash":
            if let cmd = input["command"] as? String {
                return cmd.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        case "webfetch", "webrequest", "webread":
            if let url = input["url"] as? String { return url }
        default:
            break
        }
        return prettyPrintJSON(input)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
    }

    private static func prettyPrintJSON(_ obj: Any) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return String(describing: obj)
    }

    private func handleSystemEvent(_ obj: [String: Any]) {
        if let sid = obj["session_id"] as? String {
            self.sessionId = sid
        }
        if let cwd = obj["cwd"] as? String {
            self.cwdDisplay = shortenPath(cwd)
        }
    }

    private func handleAssistantEvent(_ obj: [String: Any]) {
        guard let message = obj["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return }

        for block in content {
            let bType = block["type"] as? String ?? ""
            switch bType {
            case "text":
                if let text = block["text"] as? String, !text.isEmpty {
                    finalizeStreamingText(with: text)
                }
            case "thinking":
                if let text = block["thinking"] as? String {
                    timeline.append(TimelineItem(kind: .thinking(text)))
                }
            case "tool_use":
                let id = block["id"] as? String ?? UUID().uuidString
                guard !seenToolIds.contains(id) else { continue }
                seenToolIds.insert(id)
                let name = block["name"] as? String ?? "tool"
                let input = block["input"] ?? [:]
                let inputJSON = prettyJSON(input)
                var event = ActionEvent(
                    id: id,
                    name: name,
                    inputJSON: inputJSON,
                    startedAt: Date(),
                    status: .running,
                    result: "",
                    isError: false
                )
                extractFields(from: input, into: &event)
                actionIndexByToolId[id] = timeline.count
                timeline.append(TimelineItem(kind: .action(event)))
                activeAction = event
                // Finish any streaming text so the action appears as a fresh event underneath.
                currentAssistantTextId = nil
                // Emit a live beat so the orb narrates what Claude is doing right now.
                if let phrase = Self.livePhrase(for: event) {
                    liveNarration = phrase
                }
                // Pretty-CLI line for the refracted sphere log: `⏺ Read(foo.ts)`.
                appendToPrettyLog("\n⏺ \(Self.prettyCallDescription(for: event))\n")
                // Sidecar visualisations for specific tool categories.
                switch event.category {
                case .task:
                    // A subagent has been spawned. Add it to the field so the UI can
                    // pop a small sphere out of the main orb. hueSeed makes each
                    // subagent visually distinct (deterministic by id).
                    subagents.append(SubagentState(
                        id: id,
                        label: event.description ?? "sub-agent",
                        startedAt: Date(),
                        hueSeed: abs(id.hashValue) % 5,
                        status: .running,
                        completedAt: nil
                    ))
                case .todo:
                    // A new plan snapshot — mirror it into the session's todos so
                    // the TodoPanel can render the checklist live.
                    if let ts = event.todos { todos = ts }
                case .bash:
                    latestMonitor = event
                default:
                    break
                }
            default:
                break
            }
        }
    }

    private func handleUserEcho(_ obj: [String: Any]) {
        guard let message = obj["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return }
        for block in content {
            if let type = block["type"] as? String, type == "tool_result" {
                let toolId = block["tool_use_id"] as? String ?? ""
                let isError = (block["is_error"] as? Bool) ?? false
                var text = ""
                if let s = block["content"] as? String {
                    text = s
                } else if let arr = block["content"] as? [[String: Any]] {
                    text = arr.compactMap { $0["text"] as? String }.joined(separator: "\n")
                }
                completeAction(toolId: toolId, result: text, isError: isError)
            }
        }
    }

    private func completeAction(toolId: String, result: String, isError: Bool) {
        guard let idx = actionIndexByToolId[toolId] else { return }
        guard case var .action(event) = timeline[idx].kind else { return }
        event.result = result
        event.isError = isError
        event.status = isError ? .error : .success
        timeline[idx].kind = .action(event)
        if activeAction?.id == toolId { activeAction = nil }
        // Emit a short "what just happened" beat so the voice narrates results as
        // well as intent. Skips the low-signal categories (read/edit) where the
        // pre-phase phrase was already enough.
        if let phrase = Self.resultPhrase(for: event) {
            liveNarration = phrase
        }
        // Mark subagent completion so the SubagentField knows to fade it out.
        if event.category == .task, let subIdx = subagents.firstIndex(where: { $0.id == toolId }) {
            subagents[subIdx].status = isError ? .error : .success
            subagents[subIdx].completedAt = Date()
            // Prune it from the list after a short delay so it fades out.
            Task { [weak self, toolId] in
                try? await Task.sleep(nanoseconds: 3_500_000_000)
                await MainActor.run { self?.subagents.removeAll { $0.id == toolId } }
            }
        }
        // Refresh the monitor panel's data when a Bash tool_result lands.
        if event.category == .bash { latestMonitor = event }
        // Pretty-CLI result line: `  ⎿ 128 lines` / `  ⎿ +12 −4` / etc.
        if let summary = Self.prettyResultSummary(for: event) {
            appendToPrettyLog("  ⎿ \(summary)\n")
        }
    }

    private func handlePartialEvent(_ obj: [String: Any]) {
        guard let event = obj["event"] as? [String: Any] else { return }
        let type = event["type"] as? String ?? ""
        switch type {
        case "content_block_delta":
            if let delta = event["delta"] as? [String: Any] {
                let dtype = delta["type"] as? String ?? ""
                if dtype == "text_delta", let text = delta["text"] as? String {
                    appendStreamingText(text)
                }
            }
        default:
            break
        }
    }

    private func appendStreamingText(_ text: String) {
        let combined: String
        if let id = currentAssistantTextId,
           let idx = timeline.firstIndex(where: { $0.id == id }),
           case let .assistantText(existing, _) = timeline[idx].kind {
            combined = existing + text
            timeline[idx].kind = .assistantText(text: combined, isStreaming: true)
        } else {
            combined = text
            let item = TimelineItem(kind: .assistantText(text: text, isStreaming: true))
            currentAssistantTextId = item.id
            timeline.append(item)
        }
        // Stream Claude's prose into the pretty log AS IT ARRIVES — character
        // by character, so the sphere shows the reply forming in real time
        // interleaved with `⏺` tool call lines.
        appendToPrettyLog(text)
        // Whenever the stream has advanced past a sentence boundary, publish the
        // newly-completed chunk so the crawl can display it live.
        emitStreamingChunkIfReady(fullText: combined)
    }

    /// Publish a chunk of Claude's streaming reply once it's big enough to be a
    /// meaningful beat on the crawl. We DELIBERATELY don't emit sentence-by-sentence —
    /// the crawl can't visually separate beats that arrive faster than the rise-rate
    /// would move them apart, so we wait for either a paragraph break (double newline)
    /// or ~220 characters of pending text before publishing.
    private func emitStreamingChunkIfReady(fullText: String, force: Bool = false) {
        let chars = Array(fullText)
        guard chars.count > assistantStreamCursor else { return }

        let cutoff: Int

        if force {
            // Turn is ending. Emit the ENTIRE remainder in one chunk, even if it
            // contains paragraph breaks. Previously we still snapped to the first
            // \n\n here, which meant lists + summaries following a colon-then-list
            // ("Here are four:\n1. …\n2. …\n\nSummary.") got truncated: voice cut
            // out after the last non-force-emitted sentence and never spoke the tail.
            cutoff = chars.count
        } else {
            let pendingCount = chars.count - assistantStreamCursor

            var breakIndex: Int? = nil
            var i = assistantStreamCursor
            while i < chars.count - 1 {
                if chars[i] == "\n", chars[i + 1] == "\n" {
                    breakIndex = i
                    break
                }
                i += 1
            }

            if let b = breakIndex {
                cutoff = b
            } else if pendingCount >= 160 {
                // Snap to last sentence terminator so mid-sentence doesn't get cut.
                var lastSentenceEnd = -1
                var j = assistantStreamCursor
                while j < chars.count {
                    if ".!?".contains(chars[j]) {
                        let next = j + 1
                        if next >= chars.count || chars[next].isWhitespace {
                            lastSentenceEnd = next
                        }
                    }
                    j += 1
                }
                guard lastSentenceEnd > assistantStreamCursor else { return }
                cutoff = lastSentenceEnd
            } else {
                return
            }
        }

        let chunkChars = chars[assistantStreamCursor..<cutoff]
        let raw = String(chunkChars).trimmingCharacters(in: .whitespacesAndNewlines)
        assistantStreamCursor = cutoff
        let cleaned = Self.stripMarkdownForSpeech(raw)
        guard cleaned.count >= 12 else { return }
        streamingChunk = cleaned
    }

    private func finalizeStreamingText(with text: String? = nil) {
        if let id = currentAssistantTextId,
           let idx = timeline.firstIndex(where: { $0.id == id }),
           case let .assistantText(existing, _) = timeline[idx].kind {
            let final = text ?? existing
            timeline[idx].kind = .assistantText(text: final, isStreaming: false)
            currentAssistantTextId = nil
        } else if let text, !text.isEmpty {
            timeline.append(TimelineItem(kind: .assistantText(text: text, isStreaming: false)))
        }
    }

    private func handleResultEvent(_ obj: [String: Any]) {
        finalizeStreamingText()
        // Flush any remaining assistant text as a final streaming chunk so shorter
        // replies (which never reached the size threshold) are still voiced.
        if let last = timeline.last, case let .assistantText(text, _) = last.kind {
            emitStreamingChunkIfReady(fullText: text, force: true)
        }
        activeAction = nil
        // `result` is the CLI's definitive "turn complete" signal, so we mark the session
        // idle here — even though the OS process may still take a beat to exit. Waiting
        // for `handleTermination` instead makes the UI look stuck (banner keeps saying
        // "Working…") and blocks the conversation loop from advancing to TTS + mic reopen.
        isRunning = false
        if let sid = obj["session_id"] as? String {
            self.sessionId = sid
        }
        if let subtype = obj["subtype"] as? String, subtype == "error_max_turns" {
            appendSystem("Reached maximum turns. Send another message to continue.")
        }
        // Emit the narrator summary once per turn.
        let summary = composeTurnSummary(fromIndex: turnStartIndex)
        if !summary.isEmpty { lastTurnSummary = summary }
        // Kick off the conversational interpretation for orb mode — a cheap Haiku pass
        // that converts the turn's actions + reply into narration/tags/snippets.
        startInterpretingTurn(summary: summary)
    }

    // MARK: - Live narration

    /// Short opener spoken as a new turn begins — before any tool has fired.
    /// Randomised across a small pool so it doesn't sound scripted.
    private static func openerPhrase() -> String {
        let pool = [
            "Okay, let me have a look.",
            "On it.",
            "Alright, one sec.",
            "Let me take a look at this.",
            "Give me a moment.",
            "Right, digging in."
        ]
        return pool.randomElement() ?? "On it."
    }

    /// A short "what I'm doing right now" beat for the given tool. Kept casual and
    /// present-tense so the orb feels like a person narrating their work.
    private static func livePhrase(for event: ActionEvent) -> String? {
        switch event.category {
        case .read:
            let file = event.shortFile ?? "this file"
            return [
                "Let me have a look at \(file).",
                "Reading \(file).",
                "Opening \(file).",
                "Pulling up \(file)."
            ].randomElement()
        case .edit, .multiEdit:
            let file = event.shortFile ?? "the file"
            return [
                "Editing \(file).",
                "Making changes to \(file).",
                "Updating \(file)."
            ].randomElement()
        case .write:
            let file = event.shortFile ?? "a new file"
            return [
                "Writing \(file).",
                "Creating \(file).",
                "Putting together \(file)."
            ].randomElement()
        case .bash:
            if let cmd = event.command?.trimmingCharacters(in: .whitespacesAndNewlines), !cmd.isEmpty {
                let head = cmd.split(separator: " ").first.map(String.init) ?? cmd
                return [
                    "Running \(head).",
                    "Let me try \(head).",
                    "Kicking off \(head)."
                ].randomElement()
            }
            return "Running a command."
        case .search:
            if let p = event.pattern, !p.isEmpty {
                return [
                    "Searching for \(p).",
                    "Grepping for \(p).",
                    "Looking for \(p) in the code."
                ].randomElement()
            }
            return "Searching the codebase."
        case .glob:
            if let p = event.pattern, !p.isEmpty {
                return "Looking for files matching \(p)."
            }
            return "Scanning the file tree."
        case .web:
            if let u = event.url, let host = URL(string: u)?.host {
                return [
                    "Checking \(host).",
                    "Fetching from \(host).",
                    "Reading \(host)."
                ].randomElement()
            }
            return "Checking the web."
        case .todo:
            return [
                "Updating my plan.",
                "Marking that off the list.",
                "Ticking through the plan."
            ].randomElement()
        case .task:
            return [
                "Delegating to a sub-agent.",
                "Spinning up a helper for this.",
                "Farming this out to a sub-agent."
            ].randomElement()
        case .ask:
            return "Asking you a quick question."
        case .other:
            return nil
        }
    }

    /// Short "OK, that landed" beat spoken right after a tool_result arrives.
    /// Only emitted for high-signal categories — read/edit/write already had a
    /// pre-phase phrase saying what was about to happen, so a second beat is noise.
    private static func resultPhrase(for e: ActionEvent) -> String? {
        if e.isError {
            switch e.category {
            case .bash: return ["Hmm, that failed. Let me look.",
                                "Command didn't like that.",
                                "Got an error — checking why."].randomElement()
            case .search, .glob: return "That search errored out."
            case .web:  return "The fetch didn't work."
            case .task: return "The sub-agent hit a snag."
            default:    return "That one errored."
            }
        }
        switch e.category {
        case .search:
            let count = e.result.split(separator: "\n").count
            if count == 0 { return "No matches — moving on." }
            if count == 1 { return "One hit. Let me look at it." }
            if count < 5  { return "A few matches. Digging in." }
            if count < 25 { return "\(count) matches — worth a closer look." }
            return "Lots of hits — narrowing it down."
        case .glob:
            let count = e.result.split(separator: "\n").count
            if count == 0 { return "Nothing matches that pattern." }
            if count == 1 { return "Found one file." }
            return "Found \(count) files."
        case .bash:
            let lower = e.result.lowercased()
            if lower.contains("error:") || lower.contains("fatal:") { return "Some errors in the output — reading them." }
            if lower.contains("warning:") { return "Compiled, a couple warnings." }
            return ["Command finished clean.",
                    "That ran fine.",
                    "Done — output looks good."].randomElement()
        case .web:
            return ["Got the page, reading it.",
                    "Fetched it, having a look."].randomElement()
        case .task:
            return "Sub-agent came back."
        case .todo:
            return "Plan updated."
        case .read, .edit, .multiEdit, .write, .ask, .other:
            return nil
        }
    }

    // MARK: - Pretty CLI reconstruction (for the refracted sphere log)

    /// Formats a tool call as `⏺ Read(foo.ts)`, `⏺ Bash(swift build)`, etc.
    /// Mirrors the visual language Claude Code uses in a real terminal so the
    /// text inside the orb sphere reads like actual CLI output, not JSON.
    private static func prettyCallDescription(for e: ActionEvent) -> String {
        let name: String
        switch e.category {
        case .read:      name = "Read"
        case .edit:      name = "Edit"
        case .multiEdit: name = "MultiEdit"
        case .write:     name = "Write"
        case .bash:      name = "Bash"
        case .search:    name = "Grep"
        case .glob:      name = "Glob"
        case .web:       name = "WebFetch"
        case .todo:      name = "TodoWrite"
        case .task:      name = "Task"
        case .ask:       name = "AskUserQuestion"
        case .other:     name = e.name
        }
        let arg: String
        switch e.category {
        case .read, .edit, .multiEdit, .write:
            arg = e.shortFile ?? ""
        case .bash:
            let cmd = (e.command ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            arg = cmd.count > 60 ? String(cmd.prefix(60)) + "…" : cmd
        case .search, .glob:
            arg = e.pattern ?? ""
        case .web:
            // Trim before parsing — CLI output can carry trailing newlines or
            // stray whitespace that would otherwise trip URL(string:) and leave
            // the raw whitespace-padded string in the log.
            let raw = (e.url ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            arg = raw.isEmpty ? "" : (URL(string: raw)?.host ?? raw)
        case .task:
            let d = (e.description ?? "sub-agent").trimmingCharacters(in: .whitespacesAndNewlines)
            arg = d.count > 60 ? String(d.prefix(60)) + "…" : d
        case .todo, .ask, .other:
            arg = ""
        }
        return arg.isEmpty ? name : "\(name)(\(arg))"
    }

    /// One-liner shown under a tool call — mirrors `  ⎿ 128 lines` / `+12 −4`
    /// style summaries a terminal user would see. Returns nil for categories
    /// where a summary line would just add noise.
    private static func prettyResultSummary(for e: ActionEvent) -> String? {
        if e.isError {
            let first = e.result
                .split(separator: "\n").first
                .map(String.init)?.trimmingCharacters(in: .whitespaces) ?? "error"
            let clipped = first.count > 80 ? String(first.prefix(80)) + "…" : first
            return "✗ " + clipped
        }
        switch e.category {
        case .read:
            let lines = e.result.split(separator: "\n").count
            return lines > 0 ? "\(lines) lines" : nil
        case .edit, .multiEdit, .write:
            let s = e.diffStats
            if s.additions > 0 || s.deletions > 0 {
                return "+\(s.additions) −\(s.deletions)"
            }
            return "done"
        case .bash:
            // First non-empty output line, capped. If empty, show "done".
            let firstOutput = e.result
                .split(separator: "\n")
                .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
                .map(String.init)?.trimmingCharacters(in: .whitespaces)
            guard let line = firstOutput, !line.isEmpty else { return "done" }
            return line.count > 80 ? String(line.prefix(80)) + "…" : line
        case .search, .glob:
            let count = e.result.split(separator: "\n").count
            return "\(count) match\(count == 1 ? "" : "es")"
        case .web:
            let bytes = e.result.utf8.count
            return "\(bytes) bytes"
        case .task:
            return "sub-agent complete"
        case .todo:
            let done = e.todos?.filter { $0.status == "completed" }.count ?? 0
            let total = e.todos?.count ?? 0
            return total > 0 ? "plan: \(done)/\(total)" : "plan updated"
        case .ask, .other:
            return nil
        }
    }

    // MARK: - Conversational interpretation

    private func startInterpretingTurn(summary: String) {
        interpretationTimeoutTask?.cancel()
        interpretation = nil
        isInterpreting = true

        let (actionPhrases, assistantText) = extractTurnData(fromIndex: turnStartIndex)
        let fallback = Self.fallbackInterpretation(
            summary: summary,
            actionPhrases: actionPhrases,
            assistantText: assistantText
        )

        interpreter.interpret(assistantText: assistantText, actionPhrases: actionPhrases) { [weak self] result in
            guard let self, self.isInterpreting else { return }
            self.isInterpreting = false
            self.interpretation = result ?? fallback
        }

        // Backstop: 20 seconds. Haiku with a big prompt (many tool calls + long
        // assistant reply) can easily take 8–15 s. A 6 s timeout was tripping too
        // often on real turns and forcing the mechanical fallback.
        interpretationTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard let self, self.isInterpreting else { return }
            self.isInterpreting = false
            self.interpretation = fallback
        }
    }

    /// Split the current turn's timeline slice into the raw ingredients the interpreter
    /// (and its fallback) need: the phrases describing tools used, and the final
    /// assistant text stripped of Markdown.
    private func extractTurnData(fromIndex: Int) -> (actionPhrases: [String], assistantText: String) {
        let start = max(0, min(fromIndex, timeline.count))
        let slice = Array(timeline[start...])
        var phrases: [String] = []
        var finalText = ""
        for item in slice {
            switch item.kind {
            case .action(let event):
                if let phrase = Self.actionPhrase(for: event) { phrases.append(phrase) }
            case .assistantText(let text, let streaming):
                if !streaming {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { finalText = trimmed }
                }
            default:
                break
            }
        }
        return (phrases, Self.stripMarkdownForSpeech(finalText))
    }

    /// Cheap synthetic interpretation used when the Haiku pass fails or times out.
    /// Not as natural as Haiku's output, but keeps the orb populated and honest.
    private static func fallbackInterpretation(
        summary: String,
        actionPhrases: [String],
        assistantText: String
    ) -> ConversationalInterpreter.Interpretation {
        // Tags: the first significant word from each action phrase, deduped, plus a
        // couple of fallback words if we have nothing.
        let stopwords: Set<String> = ["the", "a", "an", "some", "with"]
        var seen: Set<String> = []
        var tags: [String] = []
        for phrase in actionPhrases {
            for token in phrase.split(separator: " ") {
                let w = token.lowercased().trimmingCharacters(in: .punctuationCharacters)
                if w.count < 3 || stopwords.contains(w) { continue }
                if seen.insert(w).inserted { tags.append(w) }
                break
            }
            if tags.count >= 6 { break }
        }
        if tags.isEmpty { tags = ["idle"] }

        // Snippets: first 3 action phrases, each capped to fit a satellite.
        let snippets = actionPhrases.prefix(3).map { phrase -> String in
            phrase.count > 40 ? String(phrase.prefix(40)) + "…" : phrase
        }

        // Narration priority — the assistant's own reply is by far the most
        // conversational thing we have. The action list ("I read X, ran grep -r
        // …, read Y") reads like a shell transcript when spoken aloud, so we
        // ONLY fall back to it when Claude gave no textual reply at all.
        let narration: String = {
            let t = assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty {
                return firstFewSentences(t, sentences: 12, maxChars: 3000)
            }
            if !actionPhrases.isEmpty {
                // Compact, human-sounding summary — max 3 phrases, no shell text.
                let head = Array(actionPhrases.prefix(3))
                return "Took a look — " + naturalList(head) + "."
            }
            let s = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { return s }
            return "Done."
        }()

        return ConversationalInterpreter.Interpretation(
            narration: narration,
            tags: tags,
            snippets: Array(snippets)
        )
    }

    // MARK: - Turn narration

    /// Build the spoken payload for a completed turn.
    ///
    /// Rules:
    /// - If the assistant reply is short and Claude didn't do anything else this turn,
    ///   read the reply verbatim (Markdown stripped) so the conversation feels natural.
    /// - Otherwise, build a narrator-style summary: "I read X, edited Y, ran Z." + the
    ///   first sentence or two of the assistant's own explanation.
    private func composeTurnSummary(fromIndex: Int) -> String {
        let start = max(0, min(fromIndex, timeline.count))
        let slice = Array(timeline[start...])

        var actionPhrases: [String] = []
        var finalAssistantText: String = ""

        for item in slice {
            switch item.kind {
            case .action(let event):
                if let phrase = Self.actionPhrase(for: event) {
                    actionPhrases.append(phrase)
                }
            case .assistantText(let text, let streaming):
                if !streaming {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { finalAssistantText = trimmed }
                }
            default:
                break
            }
        }

        let cleanedText = Self.stripMarkdownForSpeech(finalAssistantText)

        // Short + no actions → just read the reply verbatim (up to a reasonable length).
        // 1600 chars is enough for a paragraph or two — the user should hear the full
        // answer, not just the first sentence.
        let verbatimCap = 1600
        if actionPhrases.isEmpty && !cleanedText.isEmpty && cleanedText.count <= verbatimCap {
            return cleanedText
        }

        var parts: [String] = []
        if !actionPhrases.isEmpty {
            parts.append("I " + Self.naturalList(actionPhrases) + ".")
        }
        if !cleanedText.isEmpty {
            // Take a full paragraph — the user asked for the "full output", not a
            // one-liner. TTS handles the length via its own char cap.
            parts.append(Self.firstFewSentences(cleanedText, sentences: 6, maxChars: 1400))
        }
        return parts.joined(separator: " ")
    }

    private static func actionPhrase(for e: ActionEvent) -> String? {
        // Skip anything still in flight or errored — those aren't part of "what got done".
        guard e.status == .success else { return nil }
        switch e.category {
        case .read:
            if let f = e.shortFile { return "read \(f)" }
            return "read a file"
        case .edit, .multiEdit:
            let s = e.diffStats
            if let f = e.shortFile {
                if s.additions > 0 && s.deletions > 0 {
                    return "edited \(f) with \(s.additions) added and \(s.deletions) removed"
                }
                if s.additions > 0 { return "edited \(f), adding \(s.additions) line\(s.additions == 1 ? "" : "s")" }
                if s.deletions > 0 { return "edited \(f), removing \(s.deletions) line\(s.deletions == 1 ? "" : "s")" }
                return "edited \(f)"
            }
            return "made an edit"
        case .write:
            if let f = e.shortFile { return "wrote \(f)" }
            return "wrote a file"
        case .bash:
            if let c = e.command {
                let cleaned = c.trimmingCharacters(in: .whitespacesAndNewlines)
                let short = cleaned.count > 60 ? String(cleaned.prefix(60)) + "…" : cleaned
                return "ran \(short)"
            }
            return "ran a command"
        case .search:
            if let p = e.pattern { return "searched for \(p)" }
            return "searched the project"
        case .glob:
            if let p = e.pattern { return "listed files matching \(p)" }
            return "listed project files"
        case .web:
            if let u = e.url, let host = URL(string: u)?.host { return "fetched \(host)" }
            return "fetched a URL"
        case .todo:
            return "updated the plan"
        case .task:
            return "ran a sub-agent"
        case .ask:
            return "asked a question"
        case .other:
            return nil
        }
    }

    private static func naturalList(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default:
            return items.dropLast().joined(separator: ", ") + ", and \(items.last!)"
        }
    }

    /// Remove Markdown noise so the text reads naturally when spoken.
    /// Does *not* truncate — length decisions happen upstream in `composeTurnSummary`.
    private static func stripMarkdownForSpeech(_ raw: String) -> String {
        var t = raw
        t = t.replacingOccurrences(of: "```[\\s\\S]*?```", with: " (code block) ", options: .regularExpression)
        t = t.replacingOccurrences(of: "`", with: "")
        t = t.replacingOccurrences(of: "**", with: "")
        t = t.replacingOccurrences(of: "__", with: "")
        // Multiline anchors so bulleted lists get the dashes stripped from every
        // line, not just the first. Without this, "- one\n- two" reads as
        // "one - two" and the voice literally says "dash".
        t = t.replacingOccurrences(of: "(?m)^#{1,6}\\s+", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "(?m)^\\s*[-*+]\\s+", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "(?m)^\\s*\\d+\\.\\s+", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^\\)]+\\)", with: "$1", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Take the first N sentences from `text`, capped at `maxChars`. Used when
    /// summarizing a long assistant reply into something that fits in a spoken beat.
    private static func firstFewSentences(_ text: String, sentences: Int, maxChars: Int) -> String {
        let parts = text.split(whereSeparator: { ".!?".contains($0) })
        var out = parts.prefix(sentences).joined(separator: ". ").trimmingCharacters(in: .whitespacesAndNewlines)
        if let last = out.last, !".!?".contains(last) { out += "." }
        if out.count > maxChars { out = String(out.prefix(maxChars)) + "…" }
        return out
    }

    // MARK: - Utilities

    private func extractFields(from raw: Any, into event: inout ActionEvent) {
        guard let input = raw as? [String: Any] else { return }
        event.filePath = (input["file_path"] ?? input["path"] ?? input["notebook_path"]) as? String
        event.command = input["command"] as? String
        event.pattern = (input["pattern"] ?? input["query"] ?? input["glob"]) as? String
        event.url = input["url"] as? String
        event.oldString = input["old_string"] as? String
        event.newString = input["new_string"] as? String
        event.content = input["content"] as? String
        event.description = input["description"] as? String

        if let edits = input["edits"] as? [[String: Any]] {
            event.edits = edits.compactMap { e in
                guard let old = e["old_string"] as? String, let new = e["new_string"] as? String else { return nil }
                return EditPair(old: old, new: new)
            }
        }
        if let todos = input["todos"] as? [[String: Any]] {
            event.todos = todos.compactMap { t in
                guard let content = t["content"] as? String, let status = t["status"] as? String else { return nil }
                return TodoEntry(content: content, status: status, priority: t["priority"] as? String)
            }
        }
        if let questions = input["questions"] as? [[String: Any]] {
            event.questions = questions.compactMap { q in
                guard let text = q["question"] as? String else { return nil }
                let options = (q["options"] as? [[String: Any]] ?? []).compactMap { o -> InteractiveOption? in
                    guard let label = o["label"] as? String else { return nil }
                    return InteractiveOption(label: label, description: o["description"] as? String)
                }
                return InteractiveQuestion(
                    question: text,
                    header: q["header"] as? String,
                    multiSelect: (q["multiSelect"] as? Bool) ?? false,
                    options: options
                )
            }
        }
    }

    private func prettyJSON(_ raw: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    private func handleStderr(_ str: String) {
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        NSLog("Claudette stderr: \(trimmed)")
        self.lastError = trimmed
    }

    private func appendSystem(_ text: String) {
        timeline.append(TimelineItem(kind: .system(text)))
    }

    /// Surface a voice-side error (ElevenLabs, mic, etc) as a system notice so users
    /// notice silent failures instead of just… not hearing anything.
    func appendVoiceError(_ text: String) {
        appendSystem("Voice: \(text)")
    }

    private func shortenPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) { return "~" + path.dropFirst(home.count) }
        return path
    }

    // MARK: - Subagent state

    struct SubagentState: Identifiable, Equatable {
        let id: String
        let label: String
        let startedAt: Date
        /// Deterministic hue index 0…4 so multiple concurrent subagents look distinct.
        let hueSeed: Int
        var status: Status
        /// When the tool_result landed. Nil while running. Once set, the sphere
        /// fades out and is pruned a few seconds later.
        var completedAt: Date?

        enum Status: String { case running, success, error }
    }

    nonisolated static func locateClaudeBinary() -> String? {
        let candidates = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            (ProcessInfo.processInfo.environment["HOME"] ?? "") + "/.claude/local/claude",
            (ProcessInfo.processInfo.environment["HOME"] ?? "") + "/.local/bin/claude"
        ]
        for path in candidates where !path.isEmpty && FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["which", "claude"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !s.isEmpty, FileManager.default.isExecutableFile(atPath: s) {
                return s
            }
        } catch {
            return nil
        }
        return nil
    }
}
