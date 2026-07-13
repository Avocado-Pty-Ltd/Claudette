import SwiftUI

/// One-time onboarding sheet shown on first launch. Explains what Claudette needs,
/// what it doesn't, and requests mic + speech in a single flow so the user isn't
/// hit with a prompt mid-conversation.
///
/// The sheet is presented from ContentView based on
/// `PermissionsCoordinator.shouldPresentOnboarding`.
struct PermissionsOnboardingView: View {
    @EnvironmentObject var permissions: PermissionsCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var requestInFlight: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header
            requestList
            fineprint
            Spacer(minLength: 0)
            footer
        }
        .padding(28)
        .frame(width: 520)
        .background(Theme.Palette.bgPrimary)
        .onAppear { permissions.refresh() }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("One-time setup")
                .font(.system(size: 11, weight: .bold))
                .tracking(2.0)
                .foregroundStyle(Theme.Palette.accent)
                .textCase(.uppercase)
            Text("Just two permissions.")
                .font(Theme.Font.display)
                .foregroundStyle(Theme.Palette.textPrimary)
            Text("Claudette asks up-front so nothing pops up mid-conversation. You can change these later in System Settings → Privacy & Security.")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var requestList: some View {
        VStack(spacing: 12) {
            row(
                icon: "mic",
                title: "Microphone",
                explanation: "So you can dictate messages and talk to Claude hands-free in orb mode.",
                status: permissions.microphone
            )
            row(
                icon: "waveform",
                title: "Speech recognition",
                explanation: "On-device — nothing leaves your Mac. Turns what you say into text.",
                status: permissions.speech
            )
        }
    }

    /// Small print explaining WHY the user might see additional prompts (Photos,
    /// Downloads, etc.) even though we don't ask for them here.
    private var fineprint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text("Why might macOS ask for other permissions later?")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textSecondary)
            } icon: {
                Image(systemName: "info.circle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            Text("Claudette runs the real `claude` CLI as a subprocess. If Claude reads a folder that macOS protects — Photos Library, Downloads, Desktop — the OS attributes that request to Claudette. We don't touch those APIs ourselves.")
                .font(Theme.Font.micro)
                .foregroundStyle(Theme.Palette.textTertiary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.Palette.bgSecondary)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Theme.Palette.border, lineWidth: 0.5)
                )
        )
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            Button("Skip for now") {
                permissions.markOnboardingComplete()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(requestInFlight)

            Button(action: grantAll) {
                HStack(spacing: 6) {
                    if requestInFlight {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                    }
                    Text(allGranted ? "Continue" : "Grant permissions")
                        .fontWeight(.semibold)
                }
                .frame(minWidth: 140)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(requestInFlight)
        }
    }

    private var allGranted: Bool {
        permissions.microphone.isGranted && permissions.speech.isGranted
    }

    // MARK: - Row

    private func row(icon: String, title: String, explanation: String, status: PermissionsCoordinator.Status) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.Palette.accent)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.Palette.accent.opacity(0.12))
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text(explanation)
                    .font(Theme.Font.micro)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            statusPill(status)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.Palette.bgElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Theme.Palette.border, lineWidth: 0.5)
                )
        )
    }

    @ViewBuilder
    private func statusPill(_ status: PermissionsCoordinator.Status) -> some View {
        switch status {
        case .granted:
            pill(text: "Granted", color: DiffLine.addedGreen, icon: "checkmark")
        case .denied:
            pill(text: "Denied", color: DiffLine.removedRed, icon: "xmark")
        case .restricted:
            pill(text: "Restricted", color: DiffLine.removedRed, icon: "lock")
        case .undetermined:
            pill(text: "Pending", color: Theme.Palette.textTertiary, icon: "hourglass")
        }
    }

    private func pill(text: String, color: Color, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
            Text(text)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.5)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule(style: .continuous)
                .fill(color.opacity(0.12))
        )
    }

    // MARK: - Actions

    private func grantAll() {
        if allGranted {
            permissions.markOnboardingComplete()
            dismiss()
            return
        }
        requestInFlight = true
        Task {
            await permissions.requestAllUpfront()
            requestInFlight = false
            // Dismiss automatically once we've gone through the flow — even if
            // one or both were denied, we don't want to keep the user trapped
            // on the sheet. The status pills will show the outcome briefly
            // before dismissal so they know what happened.
            try? await Task.sleep(nanoseconds: 350_000_000)
            dismiss()
        }
    }
}
