import SwiftUI

struct EmptyStateView: View {
    @EnvironmentObject var store: ProjectStore

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Theme.Palette.accent.opacity(0.12))
                    .frame(width: 96, height: 96)
                Text("C")
                    .font(.system(size: 44, weight: .semibold, design: .serif))
                    .foregroundStyle(Theme.Palette.accent)
            }
            VStack(spacing: 8) {
                Text("Welcome to Claudette")
                    .font(Theme.Font.display)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text("A calm, beautifully typeset front-end for Claude Code.\nOpen a folder and start building.")
                    .font(Theme.Font.bodySerif)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }
            Button {
                NotificationCenter.default.post(name: .claudetteNewProject, object: nil)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder.badge.plus")
                    Text("Choose a project folder")
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.Palette.accent)
                )
            }
            .buttonStyle(.plain)
            .keyboardShortcut("n", modifiers: [.command])
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Palette.bgPrimary)
    }
}
