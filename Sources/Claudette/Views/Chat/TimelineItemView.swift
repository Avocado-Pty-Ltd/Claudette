import SwiftUI

/// Root dispatcher — routes a timeline item to the right rendered view.
struct TimelineItemView: View {
    let item: TimelineItem

    var body: some View {
        switch item.kind {
        case .userText(let text):
            UserMessageView(text: text)
        case .assistantText(let text, let isStreaming):
            AssistantTextView(text: text, isStreaming: isStreaming)
        case .thinking(let text):
            ThinkingView(text: text)
        case .action(let event):
            ActionEventView(event: event)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .system(let text):
            SystemNoticeView(text: text)
        }
    }
}

// MARK: - Bubbles

struct UserMessageView: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Spacer(minLength: 40)
            Text(text)
                .font(Theme.Font.bodySerif)
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineSpacing(4)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Theme.Palette.userBubble)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Theme.Palette.border, lineWidth: 0.5)
                )
                .frame(maxWidth: 520, alignment: .trailing)
                .textSelection(.enabled)
        }
    }
}

struct AssistantTextView: View {
    let text: String
    let isStreaming: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            avatar
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("Claudette")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textPrimary)
                    if isStreaming { StreamingDots() }
                }
                MarkdownText(text)
            }
        }
    }

    private var avatar: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.Palette.accent)
                .frame(width: 30, height: 30)
            Text("C")
                .font(.system(size: 15, weight: .semibold, design: .serif))
                .foregroundStyle(.white)
        }
        .padding(.top, 2)
    }
}

struct ThinkingView: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Image(systemName: "brain")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Thinking")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.3)
                }
                .foregroundStyle(Theme.Palette.textTertiary)
            }
            .buttonStyle(.plain)
            if expanded {
                Text(text)
                    .font(Theme.Font.bodySerif.italic())
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineSpacing(3)
                    .padding(.leading, 4)
                    .transition(.opacity)
            }
        }
    }
}

struct SystemNoticeView: View {
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.Palette.textTertiary)
            Text(text)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textSecondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.Palette.bgSecondary)
        )
    }
}
