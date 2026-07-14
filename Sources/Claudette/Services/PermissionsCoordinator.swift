import Foundation
import AVFoundation
import Speech
import SwiftUI

/// Central authority for the two runtime permissions Claudette itself needs:
/// microphone (for the voice input mic) and speech recognition (for the on-device
/// transcription). Both are queried up-front from an onboarding sheet so the user
/// isn't hit with a permission dialog in the middle of a "Talk" flow.
///
/// What Claudette does NOT ask for:
/// - Photos / Contacts / Calendar / Reminders / Location — no code path touches
///   these frameworks.
/// - Files & Folders (Downloads, Desktop, Documents, etc) — Claudette itself
///   doesn't read TCC-protected user folders. If macOS surfaces one of those
///   prompts, it's the spawned Claude Code subprocess reaching into a
///   protected path, and the prompt is attributed to Claudette because the CLI
///   inherits its parent's TCC identity. There's nothing we can do from this
///   side to pre-approve those on behalf of the CLI.
@MainActor
final class PermissionsCoordinator: ObservableObject {
    /// Microphone TCC state. Kept in sync via `refresh()`.
    @Published private(set) var microphone: Status = .undetermined
    /// Speech-recognition TCC state.
    @Published private(set) var speech: Status = .undetermined
    /// True once the user has been through the onboarding sheet at least once,
    /// regardless of whether they granted or denied. Prevents re-prompting on
    /// every launch — if they denied, they can flip it in System Settings.
    @Published var hasCompletedOnboarding: Bool

    private static let onboardingKey = "permissions.hasCompletedOnboarding"

    enum Status {
        case undetermined   // never asked
        case granted
        case denied
        case restricted     // parental controls / MDM

        var isBlocking: Bool { self == .denied || self == .restricted }
        var isGranted: Bool { self == .granted }
    }

    init() {
        self.hasCompletedOnboarding = UserDefaults.standard.bool(forKey: Self.onboardingKey)
        refresh()
    }

    /// Re-query the system for the current TCC state without prompting. Called
    /// on init and whenever we suspect the user may have flipped a setting.
    func refresh() {
        let rawMic = AVCaptureDevice.authorizationStatus(for: .audio)
        let rawSpeech = SFSpeechRecognizer.authorizationStatus()
        microphone = Self.mapMicStatus(rawMic)
        speech = Self.mapSpeechStatus(rawSpeech)
        NSLog("Claudette perms: bundleId=%@ rawMic=%d rawSpeech=%d → mic=%@ speech=%@",
              Bundle.main.bundleIdentifier ?? "?",
              rawMic.rawValue, rawSpeech.rawValue,
              String(describing: microphone), String(describing: speech))
    }

    /// Ask for microphone if the state is `.undetermined`. Returns the final state.
    /// If already decided, returns immediately without prompting.
    ///
    /// After the request completes, we re-query `authorizationStatus` rather than
    /// mapping the boolean `granted` — the boolean collapses `.denied` and
    /// `.restricted` into the same value, but MDM / parental-controls setups can
    /// leave the mic in `.restricted`, and the UI should reflect that distinction.
    @discardableResult
    func requestMicrophone() async -> Status {
        if microphone != .undetermined { return microphone }
        _ = await Self.requestMic()
        microphone = Self.mapMicStatus(AVCaptureDevice.authorizationStatus(for: .audio))
        return microphone
    }

    /// Same shape for speech recognition.
    @discardableResult
    func requestSpeech() async -> Status {
        if speech != .undetermined { return speech }
        _ = await Self.requestSpeechAuthorization()
        speech = Self.mapSpeechStatus(SFSpeechRecognizer.authorizationStatus())
        return speech
    }

    /// Force both requests unconditionally and re-query afterwards. Used from
    /// the auth-error banner tap: if the user has already granted permission
    /// in System Settings but the process's cached TCC binding is stale
    /// (common for ad-hoc-signed apps where the code-signature changes on
    /// every rebuild), calling `requestAuthorization` reconciles it — the
    /// OS returns `.authorized` immediately without a prompt.
    func forceReconcile() async {
        _ = await Self.requestSpeechAuthorization()
        _ = await Self.requestMic()
        refresh()
    }

    /// Runs both requests sequentially. Called by the onboarding sheet's
    /// primary button — the user sees mic prompt → speech prompt back-to-back,
    /// once, and the sheet dismisses.
    func requestAllUpfront() async {
        await requestMicrophone()
        await requestSpeech()
        markOnboardingComplete()
    }

    /// Flag the onboarding sheet as seen. Persisted so it doesn't reappear on
    /// subsequent launches unless the user manually resets state.
    func markOnboardingComplete() {
        hasCompletedOnboarding = true
        UserDefaults.standard.set(true, forKey: Self.onboardingKey)
    }

    /// Whether the onboarding sheet should be shown at launch. The gate is a
    /// single flag: has the user been through onboarding at least once? If they
    /// clicked "Skip for now" without granting, we deliberately do NOT re-prompt
    /// on subsequent launches — they can flip permissions in System Settings
    /// (or via a "Reset onboarding" affordance we haven't shipped yet). This
    /// matches the "don't re-nag every launch" behaviour promised by
    /// `hasCompletedOnboarding`.
    var shouldPresentOnboarding: Bool {
        !hasCompletedOnboarding
    }

    // MARK: - Mapping helpers

    private static func mapMicStatus(_ raw: AVAuthorizationStatus) -> Status {
        switch raw {
        case .notDetermined: return .undetermined
        case .authorized:    return .granted
        case .denied:        return .denied
        case .restricted:    return .restricted
        @unknown default:    return .undetermined
        }
    }

    private static func mapSpeechStatus(_ raw: SFSpeechRecognizerAuthorizationStatus) -> Status {
        switch raw {
        case .notDetermined: return .undetermined
        case .authorized:    return .granted
        case .denied:        return .denied
        case .restricted:    return .restricted
        @unknown default:    return .undetermined
        }
    }

    // MARK: - Nonisolated request helpers
    //
    // Both `AVCaptureDevice.requestAccess` and `SFSpeechRecognizer.requestAuthorization`
    // deliver their completion on background queues. If the enclosing method
    // were `@MainActor` isolated, Swift 6's executor check would trap when the
    // continuation resumes off-main. Marking these `nonisolated` sidesteps that.

    nonisolated private static func requestMic() async -> Bool {
        await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                cont.resume(returning: granted)
            }
        }
    }

    nonisolated private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
    }
}
