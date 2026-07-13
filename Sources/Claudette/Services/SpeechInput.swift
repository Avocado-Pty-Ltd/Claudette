import Foundation
import Speech
import AVFoundation
import SwiftUI
import Combine

/// Live speech-to-text via Apple's on-device SFSpeechRecognizer.
///
/// Publishes `partialTranscript` as the user speaks so a chat draft field can update live.
/// Nothing leaves the device — no API keys needed.
@MainActor
final class SpeechInput: ObservableObject {
    @Published private(set) var isListening: Bool = false
    @Published private(set) var partialTranscript: String = ""
    @Published private(set) var authError: String?

    /// Emits the finalized transcript when the user stops talking (silence detected).
    /// This is a Combine subject rather than a callback closure because View structs
    /// (which subscribe from ChatView) get re-created on every render — capturing self
    /// in a closure would leave the old struct's environment references stale.
    let utterances = PassthroughSubject<String, Never>()

    /// How long of a quiet gap counts as "you're done talking".
    var silenceInterval: TimeInterval = 0.9

    private let recognizer: SFSpeechRecognizer? = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceWorkItem: DispatchWorkItem?

    /// Kick off (or stop) live transcription.
    func toggle() async {
        if isListening { stop() } else { await start() }
    }

    func start() async {
        authError = nil
        partialTranscript = ""

        // Read the current TCC state WITHOUT calling `requestAuthorization`.
        // Prompting is exclusively owned by PermissionsOnboardingView so that
        // the user never sees an OS dialog mid-conversation. If either grant
        // is missing here, we fail cleanly and point at Settings — the user
        // already declined or skipped onboarding.
        let speechAuth = SFSpeechRecognizer.authorizationStatus()
        guard speechAuth == .authorized else {
            authError = "Speech recognition not authorized. Enable it in System Settings → Privacy & Security → Speech Recognition."
            return
        }
        let micAuth = AVCaptureDevice.authorizationStatus(for: .audio)
        guard micAuth == .authorized else {
            authError = "Microphone access denied. Enable it in System Settings → Privacy & Security → Microphone."
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            authError = "Speech recognizer unavailable."
            return
        }

        let newRequest = SFSpeechAudioBufferRecognitionRequest()
        newRequest.shouldReportPartialResults = true
        self.request = newRequest

        // Install the audio tap + recognition task via a nonisolated helper. The closures
        // are created inside a non-MainActor context, so AVAudioEngine's real-time audio
        // thread can call them without hitting Swift 6's executor isolation trap.
        do {
            try Self.installTapAndTask(
                on: audioEngine,
                recognizer: recognizer,
                request: newRequest,
                onPartial: { [weak self] text, isFinal in
                    Task { @MainActor in
                        guard let self else { return }
                        self.partialTranscript = text
                        if isFinal {
                            self.finalizeUtterance(text)
                        } else {
                            self.scheduleSilenceCheck(text: text)
                        }
                    }
                },
                onError: { [weak self] in
                    Task { @MainActor in self?.stop() }
                }
            )
            try audioEngine.start()
            isListening = true
        } catch {
            authError = error.localizedDescription
            stop()
        }
    }

    /// Called from the recognition callback on every partial update. If nothing else
    /// comes in for `silenceInterval` seconds, we finalize what we've heard so far.
    private func scheduleSilenceCheck(text: String) {
        silenceWorkItem?.cancel()
        let interval = silenceInterval
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.isListening else { return }
                let current = self.partialTranscript
                let candidate = current.isEmpty ? text : current
                if !candidate.isEmpty {
                    self.finalizeUtterance(candidate)
                }
            }
        }
        silenceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: work)
    }

    private func finalizeUtterance(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        stop()  // resets partialTranscript, cancels timer, etc.
        guard !trimmed.isEmpty else { return }
        utterances.send(trimmed)
    }

    func stop() {
        silenceWorkItem?.cancel()
        silenceWorkItem = nil
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        isListening = false
    }

    // MARK: - Nonisolated setup helpers
    //
    // These are `nonisolated` so the closures they install don't inherit MainActor
    // isolation. AVAudioEngine invokes the tap block on the real-time audio thread and
    // SFSpeechRecognizer invokes the task callback on an arbitrary queue — if either
    // closure were MainActor-isolated (as Swift 6 infers by default when captured inside
    // a @MainActor method), the runtime's `swift_task_isCurrentExecutorWithFlagsImpl`
    // would trap when they run off the main queue.

    nonisolated private static func installTapAndTask(
        on engine: AVAudioEngine,
        recognizer: SFSpeechRecognizer,
        request: SFSpeechAudioBufferRecognitionRequest,
        onPartial: @escaping @Sendable (String, Bool) -> Void,
        onError: @escaping @Sendable () -> Void
    ) throws {
        let input = engine.inputNode
        let recordingFormat = input.outputFormat(forBus: 0)

        input.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()

        _ = recognizer.recognitionTask(with: request) { result, error in
            if let result {
                onPartial(result.bestTranscription.formattedString, result.isFinal)
            }
            if error != nil {
                onError()
            }
        }
    }

    // The permission-request helpers that used to live here have moved to
    // PermissionsCoordinator, which owns all prompting up-front. SpeechInput
    // only READS the current TCC status via authorizationStatus, so it never
    // fires a system prompt from the middle of a hands-free flow.
}
