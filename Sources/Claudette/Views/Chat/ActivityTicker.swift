import SwiftUI

/// A live "narrator" strip that appears whenever Claude is doing something. It
/// mirrors the current active action so the user always sees what's happening —
/// like the caption under a music player.
struct ActivityTicker: View {
    let event: ActionEvent?
    let isThinking: Bool

    var body: some View {
        HStack(spacing: 10) {
            marker
            Text(label)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .id(label) // triggers a fresh transition on text swap
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            Spacer(minLength: 6)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Capsule(style: .continuous)
                .fill(Theme.Palette.bgElevated)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Theme.Palette.accent.opacity(0.35), lineWidth: 0.75)
        )
        .shadow(color: Theme.Palette.accent.opacity(0.1), radius: 5, x: 0, y: 1)
        .animation(.easeInOut(duration: 0.22), value: label)
        .frame(maxWidth: 420, alignment: .leading)
    }

    @ViewBuilder
    private var marker: some View {
        if let event {
            Image(systemName: event.category.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(hex: event.category.tintHex))
                .frame(width: 16, height: 16)
        } else {
            RunningDot()
        }
    }

    private var label: String {
        if let event {
            return event.humanTitle
        }
        return isThinking ? "Thinking…" : "Working…"
    }
}
