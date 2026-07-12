import Foundation
import AVFoundation
import SwiftUI

/// Speaks assistant replies aloud. Uses ElevenLabs when configured, falls back to
/// Apple's native `AVSpeechSynthesizer` so the conversation loop still speaks
/// something even without a paid TTS provider.
///
/// A `spokenHashes` memo prevents re-speaking the same text (e.g. when a streaming
/// message ticks over its "final" flag repeatedly).
@MainActor
final class SpeechOutput: NSObject, ObservableObject {
    @Published private(set) var isSpeaking: Bool = false
    @Published private(set) var lastError: String?

    private let config: VoiceConfig
    private var elevenPlayer: AVAudioPlayer?
    private var elevenDelegate: PlayerDelegate?
    private let nativeSynth = AVSpeechSynthesizer()
    private var nativeDelegate: NativeSynthDelegate!
    private var spokenHashes: Set<Int> = []
    private var currentTask: Task<Void, Never>?

    /// Beats waiting to be spoken. New requests append here and the next one starts
    /// when the current TTS finishes — that way "let me look at Foo. editing Foo.
    /// running tests." stack up naturally instead of interrupting each other.
    private var queue: [String] = []
    /// Cap so a run-away turn (10 tool calls in 4 seconds) doesn't leave the orb
    /// narrating events from 30 seconds ago. Newer beats displace older ones.
    /// Bumped from 3 → 6 so streaming prose chunks + tool phrases can coexist in
    /// the pipeline without silently dropping either.
    private let maxQueueDepth: Int = 6

    init(config: VoiceConfig) {
        self.config = config
        super.init()
        self.nativeDelegate = NativeSynthDelegate(onFinish: { [weak self] in
            Task { @MainActor in
                self?.isSpeaking = false
                self?.pumpQueue()
            }
        })
        nativeSynth.delegate = nativeDelegate
    }

    /// Speak `text` if TTS is enabled and we haven't already spoken this exact text.
    /// Enqueues the beat; the next one starts automatically when the current one
    /// finishes. Picks provider based on config: ElevenLabs if the key + voice are
    /// set, otherwise falls back to native macOS TTS.
    func speakIfNew(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard config.ttsEnabled, !trimmed.isEmpty else { return }
        let hash = trimmed.hashValue
        guard !spokenHashes.contains(hash) else { return }
        spokenHashes.insert(hash)

        queue.append(trimmed)
        // Trim from the head — keep the most recent beats so the narration doesn't
        // fall further and further behind whatever is actually happening on screen.
        if queue.count > maxQueueDepth {
            queue.removeFirst(queue.count - maxQueueDepth)
        }
        pumpQueue()
    }

    /// If nothing is currently speaking, pull the next queued beat and start it.
    /// Called from speakIfNew and from the finish delegates of both TTS providers.
    /// Provider priority:
    ///   1. Apple native — if the user explicitly opted in via Settings.
    ///   2. ElevenLabs   — if credentials are configured.
    ///   3. Apple native — graceful fallback so we never silently drop a beat.
    private func pumpQueue() {
        guard !isSpeaking else { return }
        guard !queue.isEmpty else { return }
        let next = queue.removeFirst()
        if config.useAppleVoice {
            speakViaNative(next)
        } else if config.hasElevenLabsCredentials {
            speakViaElevenLabs(next)
        } else {
            speakViaNative(next)
        }
    }

    func stop() {
        queue.removeAll()
        interruptCurrent()
    }

    /// Cancels any in-flight playback but leaves the queue untouched — used when we
    /// need to switch backends mid-beat (e.g. ElevenLabs failed → native fallback)
    /// without discarding the pending narration.
    private func interruptCurrent() {
        currentTask?.cancel()
        currentTask = nil
        elevenPlayer?.stop()
        elevenPlayer = nil
        if nativeSynth.isSpeaking {
            nativeSynth.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
    }

    /// Clear the "already spoken" memo — call this when starting a fresh chat so a
    /// resumed conversation can be spoken again if desired.
    func resetMemo() {
        spokenHashes.removeAll()
    }

    // MARK: - Native fallback

    private func speakViaNative(_ text: String) {
        // Interrupt any in-flight playback but keep the queue — fallback callers
        // still want the remaining beats to play once this one finishes.
        interruptCurrent()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        // AVSpeechUtterance rate is in [Min, Max] with Default ≈ 0.5. Multiply by
        // the user's speed multiplier and clamp so we stay in valid range.
        let base = AVSpeechUtteranceDefaultSpeechRate
        let scaled = base * Float(config.speed)
        utterance.rate = min(AVSpeechUtteranceMaximumSpeechRate,
                             max(AVSpeechUtteranceMinimumSpeechRate, scaled))
        utterance.pitchMultiplier = 1.0
        isSpeaking = true
        nativeSynth.speak(utterance)
    }

    // MARK: - ElevenLabs

    private func speakViaElevenLabs(_ text: String) {
        currentTask?.cancel()
        let cfg = config
        let clean = Self.chunkForSpeech(text)
        // Optimistic: mark speaking immediately so the conversation loop knows to wait.
        isSpeaking = true

        currentTask = Task { [weak self] in
            do {
                let client = ElevenLabsClient(apiKey: cfg.apiKey)
                let audio = try await client.synthesize(
                    text: clean,
                    voiceId: cfg.voiceId,
                    modelId: cfg.modelId
                )
                if Task.isCancelled { return }
                try await MainActor.run { [weak self] in
                    try self?.playElevenAudio(audio)
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    // ElevenLabs failed — fall back to native so the user still hears
                    // *something* and the conversation loop can proceed.
                    self.lastError = error.localizedDescription
                    NSLog("Claudette: ElevenLabs failed (%@), falling back to native TTS", "\(error)")
                    self.speakViaNative(text)
                }
            }
        }
    }

    private func playElevenAudio(_ data: Data) throws {
        let p = try AVAudioPlayer(data: data)
        let d = PlayerDelegate { [weak self] in
            Task { @MainActor in
                self?.isSpeaking = false
                self?.pumpQueue()
            }
        }
        p.delegate = d
        // enableRate must be set BEFORE prepareToPlay — enables time-stretch playback
        // so 1.5x speed doesn't also pitch-shift the voice up.
        p.enableRate = true
        p.rate = Float(min(max(config.speed, 0.5), 2.0))
        p.prepareToPlay()
        p.play()
        elevenPlayer = p
        elevenDelegate = d
        isSpeaking = true
    }

    /// Strip Markdown noise so the voice doesn't literally read out `**`, backticks etc.
    /// Also caps very long messages so we don't burn credits on a huge dump.
    private static func chunkForSpeech(_ raw: String) -> String {
        var t = raw
        t = t.replacingOccurrences(of: "```[\\s\\S]*?```", with: " (code block) ", options: .regularExpression)
        t = t.replacingOccurrences(of: "`", with: "")
        t = t.replacingOccurrences(of: "**", with: "")
        t = t.replacingOccurrences(of: "__", with: "")
        t = t.replacingOccurrences(of: "^[-*+]\\s+", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "^#{1,6}\\s+", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^\\)]+\\)", with: "$1", options: .regularExpression)
        // ElevenLabs charges per character; 3000 keeps a paragraph-length reply
        // intact but stops the runaway case where an assistant reply is thousands
        // of characters and we'd otherwise burn credits reading the whole essay.
        let cap = 3000
        if t.count > cap { t = String(t.prefix(cap)) + "…" }
        return t
    }
}

private final class PlayerDelegate: NSObject, AVAudioPlayerDelegate {
    let onFinish: @Sendable () -> Void
    init(onFinish: @escaping @Sendable () -> Void) { self.onFinish = onFinish }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { onFinish() }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) { onFinish() }
}

// The ElevenLabs and native paths both use the callback pattern below on finish —
// SpeechOutput wires them into pumpQueue so the next enqueued beat plays.

private final class NativeSynthDelegate: NSObject, AVSpeechSynthesizerDelegate {
    let onFinish: @Sendable () -> Void
    init(onFinish: @escaping @Sendable () -> Void) { self.onFinish = onFinish }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { onFinish() }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { onFinish() }
}
