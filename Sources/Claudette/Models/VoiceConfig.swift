import Foundation
import SwiftUI

@MainActor
final class VoiceConfig: ObservableObject {
    private static let apiKeyName = "elevenlabs.apiKey"
    private static let voiceIdKey = "elevenlabs.voiceId"
    private static let modelIdKey = "elevenlabs.modelId"
    private static let ttsEnabledKey = "voice.ttsEnabled"
    private static let speedKey = "voice.speed"
    private static let useAppleVoiceKey = "voice.useAppleVoice"

    /// How fast the narration is played back. 1.0 = normal, 1.5 = 50% faster.
    /// Applied via `AVAudioPlayer.rate` (ElevenLabs) or `AVSpeechUtterance.rate`
    /// (native fallback). Clamped to [0.5, 2.0] — outside that the audio pitches
    /// too far or is unintelligible.
    static let defaultSpeed: Double = 1.5
    static let minSpeed: Double = 0.5
    static let maxSpeed: Double = 2.0

    /// ElevenLabs API key. Persisted in Keychain.
    @Published var apiKey: String {
        didSet { KeychainStore.set(Self.apiKeyName, value: apiKey) }
    }
    /// ElevenLabs voice ID (from the "Voices" section of their dashboard).
    @Published var voiceId: String {
        didSet { UserDefaults.standard.set(voiceId, forKey: Self.voiceIdKey) }
    }
    /// Which TTS model to use (default: eleven_turbo_v2_5 — good latency + quality).
    @Published var modelId: String {
        didSet { UserDefaults.standard.set(modelId, forKey: Self.modelIdKey) }
    }
    /// Whether Claudette should speak assistant replies aloud.
    @Published var ttsEnabled: Bool {
        didSet { UserDefaults.standard.set(ttsEnabled, forKey: Self.ttsEnabledKey) }
    }
    /// Playback rate multiplier. 1.5x by default — feels alive rather than plodding.
    @Published var speed: Double {
        didSet {
            let clamped = min(Self.maxSpeed, max(Self.minSpeed, speed))
            if clamped != speed { speed = clamped; return }
            UserDefaults.standard.set(speed, forKey: Self.speedKey)
        }
    }
    /// When true, TTS uses macOS's built-in `AVSpeechSynthesizer` and skips
    /// ElevenLabs entirely — no key needed, works offline. When false, TTS goes
    /// through ElevenLabs if credentials are present, falling back to native.
    @Published var useAppleVoice: Bool {
        didSet { UserDefaults.standard.set(useAppleVoice, forKey: Self.useAppleVoiceKey) }
    }

    init() {
        self.apiKey = KeychainStore.get(Self.apiKeyName) ?? ""
        self.voiceId = UserDefaults.standard.string(forKey: Self.voiceIdKey) ?? "21m00Tcm4TlvDq8ikWAM"
        self.modelId = UserDefaults.standard.string(forKey: Self.modelIdKey) ?? "eleven_multilingual_v2"
        self.ttsEnabled = UserDefaults.standard.bool(forKey: Self.ttsEnabledKey)
        let stored = UserDefaults.standard.double(forKey: Self.speedKey)
        // UserDefaults returns 0 for a missing double, so treat that as "use default".
        self.speed = stored > 0 ? stored : Self.defaultSpeed
        self.useAppleVoice = UserDefaults.standard.bool(forKey: Self.useAppleVoiceKey)
    }

    /// Whether a real ElevenLabs voice can be synthesised — API key + voice ID set.
    /// The picker/network path in SpeechOutput checks this before attempting the call.
    var hasElevenLabsCredentials: Bool {
        !apiKey.trimmingCharacters(in: .whitespaces).isEmpty &&
        !voiceId.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// True whenever ANY TTS backend is available — either the user has enabled
    /// Apple's built-in voice, or ElevenLabs is fully configured. Consumed by UI
    /// hints that just need to know "can we speak at all".
    var isConfigured: Bool {
        useAppleVoice || hasElevenLabsCredentials
    }

    /// A curated list of known ElevenLabs stock voices so the user can pick one without
    /// leaving the app. Custom voices from the dashboard also work — just paste their ID.
    static let curatedVoices: [(name: String, id: String, description: String)] = [
        ("Rachel", "21m00Tcm4TlvDq8ikWAM", "Calm, warm, American female. Great default."),
        ("Adam", "pNInz6obpgDQGcFmaJgB", "Deep, measured, American male."),
        ("Bella", "EXAVITQu4vr4xnSDxMaL", "Soft, expressive, American female."),
        ("Antoni", "ErXwobaYiN019PkySvjV", "Well-rounded, American male."),
        ("Domi", "AZnzlk1XvdvUeBnXmlld", "Strong, confident, American female."),
        ("Elli", "MF3mGyEYCl7XYWbV9V6O", "Emotional, young, American female."),
        ("Josh", "TxGEqnHWrfWFTfGW9XjX", "Young, natural, American male."),
        ("Sam", "yoZ06aMxZJJ28mfd3POQ", "Raspy, American male.")
    ]
}
