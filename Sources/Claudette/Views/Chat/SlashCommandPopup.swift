import SwiftUI

struct SlashCommand: Identifiable, Equatable {
    let name: String
    let hint: String
    let acceptsArgs: Bool
    let iconName: String
    var id: String { name }

    static let all: [SlashCommand] = [
        .init(name: "resume", hint: "Pick a previous session for this folder", acceptsArgs: true, iconName: "clock.arrow.circlepath"),
        .init(name: "clear", hint: "Start a fresh chat", acceptsArgs: false, iconName: "sparkles"),
        .init(name: "new", hint: "Same as /clear", acceptsArgs: false, iconName: "square.and.pencil"),
        .init(name: "mode", hint: "Switch permission mode — auto, acceptEdits, plan…", acceptsArgs: true, iconName: "sparkles"),
        .init(name: "model", hint: "Switch model — sonnet, opus, haiku", acceptsArgs: true, iconName: "cpu"),
        .init(name: "reveal", hint: "Reveal the project folder in Finder", acceptsArgs: false, iconName: "folder"),
        .init(name: "session", hint: "Show the current session ID", acceptsArgs: false, iconName: "number"),
        .init(name: "help", hint: "List available commands", acceptsArgs: false, iconName: "questionmark.circle")
    ]
}

/// A slim autocomplete strip that appears above the input when the draft is a partial slash command.
struct SlashCommandPopup: View {
    let matches: [SlashCommand]
    let onPick: (SlashCommand) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(matches) { cmd in
                SlashCommandRow(command: cmd) {
                    onPick(cmd)
                }
                if cmd != matches.last {
                    Divider().overlay(Theme.Palette.border.opacity(0.5))
                }
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.Palette.bgElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Theme.Palette.border, lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.06), radius: 12, x: 0, y: -2)
        .padding(.horizontal, Theme.Metric.contentPadding)
        .padding(.bottom, 4)
    }
}

struct SlashCommandRow: View {
    let command: SlashCommand
    let onTap: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Theme.Palette.accent.opacity(0.12))
                        .frame(width: 26, height: 26)
                    Image(systemName: command.iconName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.Palette.accent)
                }
                Text("/" + command.name)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text(command.hint)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if command.acceptsArgs {
                    Text("takes arg")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Theme.Palette.bgSecondary))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovered ? Theme.Palette.bgSecondary : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}
