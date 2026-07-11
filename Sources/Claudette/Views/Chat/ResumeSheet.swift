import SwiftUI

struct ResumeSheet: View {
    let project: Project
    let currentSessionId: String?
    let onPick: (SessionInfo) -> Void
    let onCancel: () -> Void

    @State private var sessions: [SessionInfo] = []
    @State private var loading: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.Palette.border)
            if loading {
                Spacer()
                ProgressView()
                    .controlSize(.small)
                Spacer()
            } else if sessions.isEmpty {
                Spacer()
                Text("No prior sessions for this folder.")
                    .font(Theme.Font.bodySerif)
                    .foregroundStyle(Theme.Palette.textSecondary)
                Spacer()
            } else {
                sessionList
            }
        }
        .frame(width: 620, height: 440)
        .background(Theme.Palette.bgPrimary)
        .onAppear(perform: load)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.Palette.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Resume a session")
                    .font(Theme.Font.heading)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text(project.displayPath)
                    .font(Theme.Font.monoSmall)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .frame(width: 24, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6).fill(Theme.Palette.bgSecondary)
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var sessionList: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(sessions) { session in
                    SessionRow(
                        session: session,
                        isCurrent: session.id == currentSessionId
                    )
                    .onTapGesture(count: 1) { onPick(session) }
                    .contextMenu {
                        Button("Copy Session ID") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(session.id, forType: .string)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    private func load() {
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let list = SessionCatalog.sessions(for: project)
            DispatchQueue.main.async {
                self.sessions = list
                self.loading = false
            }
        }
    }
}

struct SessionRow: View {
    let session: SessionInfo
    let isCurrent: Bool
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(isCurrent ? Theme.Palette.accent : Theme.Palette.borderStrong.opacity(0.5))
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.title)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Text(relativeDate(session.modifiedAt))
                        .font(Theme.Font.micro)
                        .foregroundStyle(Theme.Palette.textTertiary)
                    Text("·")
                        .foregroundStyle(Theme.Palette.textTertiary)
                    Text("\(session.messageCount) msg\(session.messageCount == 1 ? "" : "s")")
                        .font(Theme.Font.micro)
                        .foregroundStyle(Theme.Palette.textTertiary)
                    Text("·")
                        .foregroundStyle(Theme.Palette.textTertiary)
                    Text(String(session.id.prefix(8)))
                        .font(Theme.Font.monoSmall)
                        .foregroundStyle(Theme.Palette.textTertiary)
                    if isCurrent {
                        Text("current")
                            .font(.system(size: 9, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(Theme.Palette.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Theme.Palette.accent.opacity(0.12)))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovered ? Theme.Palette.bgSecondary : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
