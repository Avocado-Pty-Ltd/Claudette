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
        microphone = Self.mapMicStatus(AVCaptureDevice.authorizationStatus(for: .audio))
        speech = Self.mapSpeechStatus(SFSpeechRecognizer.authorizationStatus())
    }

    /// Ask for microphone if the state is `.undetermined`. Returns the final state.
    /// If already `.granted` / `.denied`, returns immediately without prompting.
    @discardableResult
    func requestMicrophone() async -> Status {
        if microphone != .undetermined { return microphone }
        let granted = await Self.requestMic()
        microphone = granted ? .granted : .denied
        return microphone
    }

    /// Same shape for speech recognition.
    @discardableResult
    func requestSpeech() async -> Status {
        if speech != .undetermined { return speech }
        let status = await Self.requestSpeechAuthorization()
        speech = Self.mapSpeechStatus(status)
        return speech
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

    /// Whether the onboarding sheet should be shown at launch — either the user
    /// has never been through it, or a required grant is still `.undetermined`.
    var shouldPresentOnboarding: Bool {
        !hasCompletedOnboarding
            || microphone == .undetermined
            || speech == .undetermined
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
