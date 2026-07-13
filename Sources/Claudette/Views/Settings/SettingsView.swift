import SwiftUI
import AppKit
import AVFoundation

@MainActor private var testPlayer: AVAudioPlayer?

private extension String {
    func ifBlank(_ fallback: String) -> String {
        trimmingCharacters(in: .whitespaces).isEmpty ? fallback : self
    }
}

/// Voices grouped by their `AVSpeechSynthesisVoiceQuality` tier, used by the
/// Settings picker to render section headers ("Premium", "Enhanced", "Default").
struct AppleVoiceGroup: Identifiable {
    let quality: AVSpeechSynthesisVoiceQuality
    let voices: [AVSpeechSynthesisVoice]
    var id: Int { quality.rawValue }
}

extension AVSpeechSynthesisVoiceQuality {
    /// Human-readable label for a quality tier — the section header in the picker.
    var displayName: String {
        switch self {
        case .default: return "Default"
        case .enhanced: return "Enhanced"
        case .premium: return "Premium (Neural)"
        @unknown default: return "Other"
        }
    }
    /// Sort order for the picker: premium first (best quality), then enhanced,
    /// then default. Users almost always want the best voice available.
    var tierSortOrder: Int {
        switch self {
        case .premium: return 0
        case .enhanced: return 1
        case .default: return 2
        @unknown default: return 3
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var voice: VoiceConfig
    @State private var draftKey: String = ""
    @State private var draftVoiceId: String = ""
    @State private var draftModelId: String = ""
    @State private var revealKey: Bool = false
    @State private var testState: TestState = .idle
    /// Local synthesiser used purely to preview an Apple voice from the picker.
    /// Kept separate from the app-wide SpeechOutput so a preview doesn't disturb
    /// an in-flight orb narration.
    @State private var previewSynth = AVSpeechSynthesizer()
    @Environment(\.dismiss) private var dismiss

    enum TestState: Equatable {
        case idle
        case running
        case ok
        case failed(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.Palette.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    voiceSection
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            footer
        }
        .frame(width: 600, height: 560)
        .background(Theme.Palette.bgPrimary)
        .onAppear {
            draftKey = voice.apiKey
            draftVoiceId = voice.voiceId
            draftModelId = voice.modelId
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "gearshape")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.Palette.accent)
            Text("Claudette Settings")
                .font(Theme.Font.heading)
                .foregroundStyle(Theme.Palette.textPrimary)
            Spacer()
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.Palette.bgSecondary))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var voiceSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeading(
                "Voice",
                subtitle: "Speech input uses on-device Apple recognition (no key needed). For assistant replies, pick a provider below — Apple's built-in voice works offline, ElevenLabs sounds better but needs an API key."
            )

            Toggle(isOn: $voice.useAppleVoice) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use Apple's built-in voice")
                        .font(Theme.Font.body)
                    Text("No API key required. Uses the built-in macOS speech synthesiser. Faster and offline, but less expressive than ElevenLabs.")
                        .font(Theme.Font.micro)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            }
            .toggleStyle(.switch)

            // Voice picker — only shown when Apple voice is active. The
            // difference between the drab default and an Enhanced / Premium
            // voice is enormous, and both tiers are already installed (or a
            // one-click download away in System Settings → Accessibility →
            // Spoken Content → Manage Voices).
            if voice.useAppleVoice {
                appleVoicePicker
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // ElevenLabs credentials — disabled and dimmed when the user picks
            // Apple's built-in voice, since they're only meaningful for the
            // ElevenLabs provider.
            Group {
                fieldRow(label: "ElevenLabs API key", help: "elevenlabs.io → Profile → API keys.") {
                    HStack(spacing: 8) {
                        Group {
                            if revealKey {
                                TextField("sk_…", text: $draftKey)
                            } else {
                                SecureField("sk_…", text: $draftKey)
                            }
                        }
                        .textFieldStyle(.plain)
                        .font(Theme.Font.mono)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.Palette.bgElevated))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.Palette.border, lineWidth: 0.75))

                        Button {
                            revealKey.toggle()
                        } label: {
                            Image(systemName: revealKey ? "eye.slash" : "eye")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.Palette.textSecondary)
                                .frame(width: 30, height: 30)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.Palette.bgSecondary))
                        }
                        .buttonStyle(.plain)
                        .help("Show / hide")
                    }
                }

                fieldRow(label: "Voice", help: "Pick one of the stock voices or paste a custom voice ID from your ElevenLabs dashboard.") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("", selection: $draftVoiceId) {
                            ForEach(VoiceConfig.curatedVoices, id: \.id) { v in
                                Text("\(v.name) — \(v.description)")
                                    .tag(v.id)
                            }
                            if !VoiceConfig.curatedVoices.map(\.id).contains(draftVoiceId) {
                                Text("Custom: \(draftVoiceId)")
                                    .tag(draftVoiceId)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)

                        TextField("Or paste a custom voice ID", text: $draftVoiceId)
                            .textFieldStyle(.plain)
                            .font(Theme.Font.mono)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.Palette.bgElevated))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.Palette.border, lineWidth: 0.75))
                    }
                }

                fieldRow(label: "Model", help: "eleven_multilingual_v2 works on every plan. eleven_turbo_v2_5 and eleven_flash_v2_5 are faster but tier-gated.") {
                    TextField("eleven_multilingual_v2", text: $draftModelId)
                        .textFieldStyle(.plain)
                        .font(Theme.Font.mono)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.Palette.bgElevated))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.Palette.border, lineWidth: 0.75))
                }
            }
            .disabled(voice.useAppleVoice)
            .opacity(voice.useAppleVoice ? 0.35 : 1.0)
            .animation(.easeInOut(duration: 0.18), value: voice.useAppleVoice)

            Toggle(isOn: $voice.ttsEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Read assistant replies aloud")
                        .font(Theme.Font.body)
                    Text("On by default when a call is live; off otherwise.")
                        .font(Theme.Font.micro)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            }
            .toggleStyle(.switch)

            fieldRow(label: "Speed", help: "1.5× feels natural. Under 1× drags; over 2× starts to slur.") {
                HStack(spacing: 14) {
                    Slider(value: $voice.speed, in: VoiceConfig.minSpeed...VoiceConfig.maxSpeed, step: 0.05)
                    Text(String(format: "%.2f×", voice.speed))
                        .font(Theme.Font.mono)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .frame(width: 56, alignment: .trailing)
                    Button("Reset") { voice.speed = VoiceConfig.defaultSpeed }
                        .disabled(abs(voice.speed - VoiceConfig.defaultSpeed) < 0.01)
                }
            }

            HStack(spacing: 10) {
                Circle()
                    .fill(voice.isConfigured ? DiffLine.addedGreen : Theme.Palette.textTertiary)
                    .frame(width: 6, height: 6)
                Text(statusText)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                Spacer()
                if !voice.useAppleVoice {
                    testVoiceButton
                }
            }
        }
    }

    /// Picker for the specific `AVSpeechSynthesisVoice` used when the Apple
    /// voice toggle is on. Voices are grouped by quality tier: Premium (neural
    /// voices from macOS 14+), Enhanced (2nd-gen downloadable), Default (basic).
    /// The user can also pick "System default" to let `AVSpeechSynthesisVoice`
    /// pick — useful if they don't care and just want whatever the OS picks.
    private var appleVoicePicker: some View {
        let groups = Self.installedAppleVoices()
        return fieldRow(
            label: "Voice",
            help: "Premium and Enhanced voices sound dramatically better than the default. Download more in System Settings → Accessibility → Spoken Content → System Voice."
        ) {
            HStack(spacing: 10) {
                Picker("", selection: $voice.appleVoiceIdentifier) {
                    Text("System default").tag("")
                    ForEach(groups) { group in
                        Section(group.quality.displayName) {
                            ForEach(group.voices, id: \.identifier) { v in
                                Text("\(v.name)  ·  \(v.language)")
                                    .tag(v.identifier)
                            }
                        }
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)

                Button {
                    previewAppleVoice()
                } label: {
                    Label("Preview", systemImage: "play.fill")
                        .labelStyle(.iconOnly)
                        .frame(width: 30, height: 26)
                }
                .buttonStyle(.plain)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.Palette.bgSecondary))
                .help("Speak a sample sentence with the selected voice")
            }
        }
    }

    /// Enumerate installed voices from `AVSpeechSynthesisVoice.speechVoices()`
    /// and group them by quality tier. English variants first, then everything
    /// else — the app itself is English-only so English voices are most useful,
    /// but users on other locales may still want to see their own languages.
    private static func installedAppleVoices() -> [AppleVoiceGroup] {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        // Sort: English > everything else, then by voice name within each locale.
        let sorted = voices.sorted { a, b in
            let ae = a.language.hasPrefix("en")
            let be = b.language.hasPrefix("en")
            if ae != be { return ae && !be }
            if a.language != b.language { return a.language < b.language }
            return a.name < b.name
        }
        // Group by quality — highest tier first so the picker's most eye-catching
        // section is the best voices.
        let byQuality = Dictionary(grouping: sorted, by: \.quality)
        return byQuality
            .map { AppleVoiceGroup(quality: $0.key, voices: $0.value) }
            .sorted { $0.quality.tierSortOrder < $1.quality.tierSortOrder }
    }

    /// Speak a short sample using whatever voice is currently selected in the
    /// picker (or the system default if none). Runs through a local
    /// AVSpeechSynthesizer instance so it doesn't interfere with the app-wide
    /// SpeechOutput queue that might be mid-narration.
    private func previewAppleVoice() {
        previewSynth.stopSpeaking(at: .immediate)
        let sample = "Hi — this is what I'll sound like in Claudette."
        let utterance = AVSpeechUtterance(string: sample)
        if !voice.appleVoiceIdentifier.isEmpty,
           let picked = AVSpeechSynthesisVoice(identifier: voice.appleVoiceIdentifier) {
            utterance.voice = picked
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        }
        let base = AVSpeechUtteranceDefaultSpeechRate
        utterance.rate = min(AVSpeechUtteranceMaximumSpeechRate,
                             max(AVSpeechUtteranceMinimumSpeechRate,
                                 base * Float(voice.speed)))
        previewSynth.speak(utterance)
    }

    /// One-liner shown next to the ready dot at the bottom of the voice section.
    /// Reflects the currently-selected provider, not just whether ANY TTS works.
    private var statusText: String {
        if voice.useAppleVoice {
            return "Using Apple's built-in voice. No key required."
        }
        if voice.hasElevenLabsCredentials {
            return "ElevenLabs ready. Mic works without any key — just tap it."
        }
        return "Voice output not configured yet. Speech input still works."
    }

    @ViewBuilder
    private var testVoiceButton: some View {
        HStack(spacing: 8) {
            switch testState {
            case .idle:
                EmptyView()
            case .running:
                ProgressView().controlSize(.small).scaleEffect(0.7)
            case .ok:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(DiffLine.addedGreen)
                    .font(.system(size: 12))
            case .failed(let msg):
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(DiffLine.removedRed)
                        .font(.system(size: 12))
                    Text(msg)
                        .font(Theme.Font.micro)
                        .foregroundStyle(DiffLine.removedRed)
                        .lineLimit(1)
                        .frame(maxWidth: 180)
                }
            }
            Button("Test voice") {
                Task { await runVoiceTest() }
            }
            .disabled(testState == .running || draftKey.trimmingCharacters(in: .whitespaces).isEmpty || draftVoiceId.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func runVoiceTest() async {
        testState = .running
        let key = draftKey.trimmingCharacters(in: .whitespaces)
        let vid = draftVoiceId.trimmingCharacters(in: .whitespaces)
        let mid = draftModelId.trimmingCharacters(in: .whitespaces).ifBlank("eleven_multilingual_v2")
        let client = ElevenLabsClient(apiKey: key)
        do {
            let audio = try await client.synthesize(
                text: "Hi. I'm Claudette. I'll narrate what your agent does.",
                voiceId: vid,
                modelId: mid
            )
            do {
                let player = try AVAudioPlayer(data: audio)
                player.enableRate = true
                player.rate = Float(min(max(voice.speed, VoiceConfig.minSpeed), VoiceConfig.maxSpeed))
                player.prepareToPlay()
                player.play()
                // Keep the player alive for the duration of playback.
                testPlayer = player
                testState = .ok
            } catch {
                testState = .failed(error.localizedDescription)
            }
        } catch {
            testState = .failed(error.localizedDescription)
        }
    }

    private var footer: some View {
        HStack {
            Text("Key stored in Keychain. Voice + model preference in UserDefaults.")
                .font(Theme.Font.micro)
                .foregroundStyle(Theme.Palette.textTertiary)
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(".", modifiers: [.command])
            Button("Save") {
                voice.apiKey = draftKey.trimmingCharacters(in: .whitespaces)
                voice.voiceId = draftVoiceId.trimmingCharacters(in: .whitespaces)
                let model = draftModelId.trimmingCharacters(in: .whitespaces)
                voice.modelId = model.isEmpty ? "eleven_multilingual_v2" : model
                dismiss()
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Theme.Palette.bgSecondary)
        .overlay(Divider().overlay(Theme.Palette.border), alignment: .top)
    }

    private func sectionHeading(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .tracking(0.3)
                .foregroundStyle(Theme.Palette.textPrimary)
            Text(subtitle)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineSpacing(2)
        }
    }

    private func fieldRow<Content: View>(label: String, help: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.Palette.textSecondary)
            content()
            Text(help)
                .font(Theme.Font.micro)
                .foregroundStyle(Theme.Palette.textTertiary)
        }
    }
}
