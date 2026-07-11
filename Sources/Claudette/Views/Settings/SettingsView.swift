import SwiftUI
import AppKit
import AVFoundation

@MainActor private var testPlayer: AVAudioPlayer?

private extension String {
    func ifBlank(_ fallback: String) -> String {
        trimmingCharacters(in: .whitespaces).isEmpty ? fallback : self
    }
}

struct SettingsView: View {
    @EnvironmentObject var voice: VoiceConfig
    @State private var draftKey: String = ""
    @State private var draftVoiceId: String = ""
    @State private var draftModelId: String = ""
    @State private var revealKey: Bool = false
    @State private var testState: TestState = .idle
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
                subtitle: "Speech input uses on-device Apple recognition (no key needed). Assistant replies are read aloud by ElevenLabs — add your API key + voice below."
            )

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
                Text(voice.isConfigured ? "TTS ready. Mic works without any key — just tap it." : "Voice output not configured yet. Speech input still works.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                Spacer()
                testVoiceButton
            }
        }
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
