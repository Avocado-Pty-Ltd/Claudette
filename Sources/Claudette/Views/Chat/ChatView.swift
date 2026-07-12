import SwiftUI
import AppKit

struct ChatView: View {
    let project: Project
    @EnvironmentObject var session: ClaudeChatSession
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var voiceConfig: VoiceConfig
    @StateObject private var speechInput = SpeechInput()
    @StateObject private var speechOutput: SpeechOutput
    @State private var draft: String = ""
    @State private var showingResumeSheet = false
    @State private var conversationMode: Bool = false

    init(project: Project, voiceConfig: VoiceConfig? = nil) {
        self.project = project
        // Real init picks up the VoiceConfig from the environment; the parameter is here so
        // previews / tests can supply their own. Since @EnvironmentObject isn't available
        // in init, we lazily build a placeholder VoiceConfig here — the real one gets
        // injected via the environment, and SpeechOutput reads from it.
        let cfg = voiceConfig ?? VoiceConfig()
        _speechOutput = StateObject(wrappedValue: SpeechOutput(config: cfg))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if conversationMode {
                // Orb mode owns the whole surface — no timeline, no header, no input bar.
                // Push-to-talk on the orb replaces the auto-listen loop that used to cause
                // the "listens while talking" feedback loop.
                OrbConversationView(
                    session: session,
                    speechInput: speechInput,
                    speechOutput: speechOutput,
                    onExit: stopConversation
                )
                .transition(.opacity)
            } else {
                VStack(spacing: 0) {
                    header
                    Divider().overlay(Theme.Palette.border)
                    messageStream
                    InputBar(draft: $draft,
                             isRunning: session.isRunning,
                             onSend: send,
                             onStop: session.stop,
                             speechInput: speechInput)
                }
                .background(Theme.Palette.bgPrimary)

                if session.isRunning {
                    ActivityTicker(event: session.activeAction, isThinking: session.activeAction == nil)
                        .padding(.bottom, 96)
                        .padding(.horizontal, Theme.Metric.contentPadding)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .animation(.easeInOut(duration: 0.28), value: conversationMode)
        .animation(.easeInOut(duration: 0.22), value: session.isRunning)
        .animation(.easeInOut(duration: 0.22), value: session.activeAction?.id)
        .sheet(isPresented: $showingResumeSheet) {
            ResumeSheet(
                project: project,
                currentSessionId: session.sessionId,
                onPick: { info in
                    showingResumeSheet = false
                    session.resume(sessionId: info.id)
                    store.markOpened(project, sessionId: info.id)
                },
                onCancel: { showingResumeSheet = false }
            )
        }
        .onAppear {
            store.markOpened(project, sessionId: session.sessionId)
        }
        .onReceive(session.$sessionId) { sid in
            if let sid { store.markOpened(project, sessionId: sid) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .claudetteNewChat)) { _ in
            session.reset()
        }
        .onReceive(NotificationCenter.default.publisher(for: .claudetteFillDraft)) { note in
            if let text = note.userInfo?["text"] as? String {
                draft = draft.isEmpty ? text : draft + " " + text
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .claudetteShowResumeSheet)) { _ in
            showingResumeSheet = true
        }
        // Mirror the live mic transcript directly into the draft — each new mic session
        // starts fresh (SpeechInput clears partialTranscript on start), so we can just
        // overwrite. This avoids delta-across-sessions bugs that concatenated utterances.
        .onReceive(speechInput.$partialTranscript) { transcript in
            guard speechInput.isListening else { return }
            draft = transcript
        }
        .onChange(of: speechInput.isListening) { _, listening in
            // When the mic stops (silence detected), clear the draft so the next session
            // doesn't visually append onto stale text.
            if !listening { draft = "" }
        }
        // Speak Claude's own prose as it streams in, sentence chunk by sentence chunk.
        // These are the "intermediate conversational blocks" — the running commentary
        // Claude writes between tool calls.
        .onReceive(session.$streamingChunk) { chunk in
            guard let chunk, !chunk.isEmpty else { return }
            speechOutput.speakIfNew(chunk)
        }
        // Speak the interpreter's conversational narration when it arrives. This is
        // the wrap-up summary — always spoken, even if we already voiced streaming
        // chunks during the turn. Some redundancy is acceptable: the streaming version
        // is Claude's live running commentary, the interpretation is the polished
        // recap the user asked to always hear.
        .onReceive(session.$interpretation) { interp in
            guard let interp, !interp.narration.isEmpty else { return }
            speechOutput.speakIfNew(interp.narration)
        }
        // Speak short live beats as tool calls fire — "let me look at ChatView.swift",
        // "searching the codebase". They queue on top of each other in SpeechOutput
        // so the orb narrates what Claude is doing as it happens.
        .onReceive(session.$liveNarration) { beat in
            guard let beat, !beat.isEmpty else { return }
            speechOutput.speakIfNew(beat)
        }
        // Surface ElevenLabs errors so a bad key doesn't silently fail.
        .onReceive(speechOutput.$lastError) { err in
            guard let err, !err.isEmpty else { return }
            session.appendVoiceError(err)
        }
        // Auto-submit when the user finishes an utterance (silence detected). Only
        // meaningful in timeline mode — in orb mode, push-to-talk drives the mic
        // explicitly and the orb collects the transcript on release.
        .onReceive(speechInput.utterances) { text in
            handleUtterance(text)
        }
        .onDisappear { stopConversation() }
    }

    /// Conversation-mode button — a single toggle that owns the whole hands-free loop:
    /// mic listens → silence auto-sends → Claude works → TTS speaks summary → mic reopens.
    @ViewBuilder
    private var conversationToggle: some View {
        Button {
            if conversationMode {
                stopConversation()
            } else if !voiceConfig.isConfigured {
                NotificationCenter.default.post(name: .claudetteShowSettings, object: nil)
            } else {
                startConversation()
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: conversationMode ? "waveform.circle.fill" : "waveform")
                    .font(.system(size: 12, weight: .semibold))
                Text(conversationMode ? "Conversing" : "Talk")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(conversationMode ? .white : Theme.Palette.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(conversationMode ? Theme.Palette.accent : Theme.Palette.bgSecondary)
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(conversationMode ? Theme.Palette.accent : Theme.Palette.border, lineWidth: 0.75)
                    )
            )
        }
        .buttonStyle(.plain)
        .help(voiceConfig.isConfigured
              ? (conversationMode ? "Stop conversation" : "Hands-free conversation")
              : "Add an ElevenLabs key in Settings (⌘,) to start a conversation")
    }

    private func startConversation() {
        conversationMode = true
        voiceConfig.ttsEnabled = true
        speechOutput.resetMemo()
        // In orb mode we drive the mic manually via press-and-hold, so any auto-listen
        // that used to run in timeline mode has been removed entirely — the source of
        // the "listens while talking" feedback loop.
    }

    private func stopConversation() {
        conversationMode = false
        speechInput.stop()
        speechOutput.stop()
    }

    /// Handle a finalized utterance from the mic. Only relevant to timeline mode, where
    /// the InputBar's mic button gives us silence-detected utterances. In orb mode, the
    /// orb reads `speechInput.partialTranscript` directly on button release and this
    /// path is skipped (utterances are still emitted, but we don't send from here).
    private func handleUtterance(_ text: String) {
        guard !conversationMode else { return }
        // Route it into the draft so the user sees the transcript before send.
        draft = draft.isEmpty ? text : draft + " " + text
    }

    /// Speaker button in the header — toggles TTS on/off. Long-press-style menu opens Settings.
    @ViewBuilder
    private var ttsToggle: some View {
        Button {
            if voiceConfig.isConfigured {
                voiceConfig.ttsEnabled.toggle()
                if !voiceConfig.ttsEnabled { speechOutput.stop() }
            } else {
                NotificationCenter.default.post(name: .claudetteShowSettings, object: nil)
            }
        } label: {
            Image(systemName: iconForTTS)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tintForTTS)
                .frame(width: 30, height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(bgForTTS))
        }
        .buttonStyle(.plain)
        .help(helpForTTS)
    }

    private var iconForTTS: String {
        if !voiceConfig.isConfigured { return "speaker.slash" }
        if speechOutput.isSpeaking { return "waveform" }
        return voiceConfig.ttsEnabled ? "speaker.wave.2.fill" : "speaker.wave.2"
    }

    private var tintForTTS: Color {
        if !voiceConfig.isConfigured { return Theme.Palette.textTertiary }
        if voiceConfig.ttsEnabled { return Theme.Palette.accent }
        return Theme.Palette.textSecondary
    }

    private var bgForTTS: Color {
        if voiceConfig.ttsEnabled { return Theme.Palette.accent.opacity(0.12) }
        return Theme.Palette.bgSecondary
    }

    private var helpForTTS: String {
        if !voiceConfig.isConfigured { return "Add an ElevenLabs key in Settings (⌘,) to hear replies" }
        return voiceConfig.ttsEnabled ? "Mute assistant voice" : "Read assistant replies aloud"
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(Theme.Font.title)
                    .foregroundStyle(Theme.Palette.textPrimary)
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.Palette.textTertiary)
                    Text(session.cwdDisplay)
                        .font(Theme.Font.monoSmall)
                        .foregroundStyle(Theme.Palette.textTertiary)
                    if let sid = session.sessionId {
                        Text("·")
                            .foregroundStyle(Theme.Palette.textTertiary)
                        Text(String(sid.prefix(8)))
                            .font(Theme.Font.monoSmall)
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
                }
            }
            Spacer()
            PermissionModeMenu(mode: session.permissionMode) { newMode in
                session.setPermissionMode(newMode)
                store.setPermissionMode(newMode, for: project)
            }
            conversationToggle
            ttsToggle
            Button {
                session.reset()
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .frame(width: 30, height: 26)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.Palette.bgSecondary))
            }
            .buttonStyle(.plain)
            .help("New chat (⌘T)")
        }
        .padding(.horizontal, Theme.Metric.contentPadding)
        .padding(.vertical, 18)
    }

    // MARK: - Timeline

    private var messageStream: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if session.timeline.isEmpty {
                        placeholderPrompt
                    }
                    ForEach(session.timeline) { item in
                        TimelineItemView(item: item)
                            .id(item.id)
                            .frame(maxWidth: Theme.Metric.messageMaxWidth, alignment: .leading)
                            .transition(itemTransition(for: item))
                    }
                    Color.clear.frame(height: 96).id("bottom")
                }
                .padding(.horizontal, Theme.Metric.contentPadding)
                .padding(.top, 24)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: session.timeline.count) { _, _ in
                withAnimation(.easeOut(duration: 0.24)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onChange(of: session.timeline.last?.id) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    private func itemTransition(for item: TimelineItem) -> AnyTransition {
        switch item.kind {
        case .action:
            return .asymmetric(
                insertion: .scale(scale: 0.92).combined(with: .opacity),
                removal: .opacity
            )
        case .userText:
            return .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .opacity
            )
        default:
            return .opacity
        }
    }

    // MARK: - Empty prompt

    private var placeholderPrompt: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ready when you are.")
                .font(Theme.Font.display)
                .foregroundStyle(Theme.Palette.textPrimary)
            Text("Ask Claude to explore, plan, edit, or ship. Every action is shown as a beat — a card you can skim, expand, or replay.")
                .font(Theme.Font.bodySerif)
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineSpacing(5)
                .frame(maxWidth: 560, alignment: .leading)
            VStack(alignment: .leading, spacing: 8) {
                suggestionChip("Give me a tour of this codebase")
                suggestionChip("What could I ship next?")
                suggestionChip("Draft a README for this project")
            }
            .padding(.top, 6)
        }
        .padding(.top, 40)
        .frame(maxWidth: Theme.Metric.messageMaxWidth, alignment: .leading)
    }

    private func suggestionChip(_ text: String) -> some View {
        Button {
            draft = text
        } label: {
            HStack {
                Text(text)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Spacer()
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.Palette.bgSecondary)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Theme.Palette.border, lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 440, alignment: .leading)
    }

    private func send() {
        let text = draft
        draft = ""
        session.send(text)
    }
}

// MARK: - Streaming indicator (moved here from MessageBubble)

struct StreamingDots: View {
    @State private var phase: Double = 0

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Theme.Palette.accent)
                    .frame(width: 4, height: 4)
                    .opacity(dotOpacity(index: i))
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever()) {
                phase = 1
            }
        }
    }

    private func dotOpacity(index: Int) -> Double {
        let offset = Double(index) * 0.25
        return 0.35 + 0.5 * abs(sin((phase + offset) * .pi))
    }
}
