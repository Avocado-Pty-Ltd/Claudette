import SwiftUI
import AppKit

/// One prospect: who they are, why the agent picked them, and the connection
/// note it drafted. The note is editable in place — the whole point of the card
/// is that a human reads and adjusts it before sending, so make that the easy path.
struct ProspectCard: View {
    @Binding var prospect: Prospect
    @State private var expanded: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow

            if expanded {
                if !prospect.why.isEmpty {
                    Text(prospect.why)
                        .font(Theme.Font.bodySerif)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !prospect.connectionNote.isEmpty || prospect.url != nil {
                    DraftEditor(
                        label: "Connection note",
                        text: $prospect.connectionNote,
                        limit: Prospect.noteLimit,
                        openLabel: "Open profile",
                        openURL: prospect.url
                    )
                }

                ForEach($prospect.comments) { $comment in
                    CommentDraftView(comment: $comment)
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: Theme.Metric.cornerLg).fill(Theme.Palette.bgElevated))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metric.cornerLg)
                .stroke(Theme.Palette.border, lineWidth: 0.75)
        )
    }

    private var headerRow: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(prospect.name.isEmpty ? "Unnamed profile" : prospect.name)
                        .font(Theme.Font.heading)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    confidencePill
                }
                if !prospect.headline.isEmpty {
                    Text(prospect.headline)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !facts.isEmpty {
                    Text(facts.joined(separator: "  ·  "))
                        .font(Theme.Font.micro)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            }
            Spacer(minLength: 8)
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .frame(width: 24, height: 22)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.Palette.bgSecondary))
            }
            .buttonStyle(.plain)
        }
    }

    private var facts: [String] {
        [prospect.company, prospect.location, prospect.mutualConnections]
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private var confidencePill: some View {
        Text(prospect.confidence.label)
            .font(Theme.Font.micro)
            .foregroundStyle(Color(hex: prospect.confidence.tintHex))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(Color(hex: prospect.confidence.tintHex, alpha: 0.12))
            )
    }
}

/// A drafted comment, attached to a prospect or standing alone.
struct CommentDraftView: View {
    @Binding var comment: DraftComment

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !contextLine.isEmpty {
                Text(contextLine)
                    .font(Theme.Font.micro)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            if !comment.postSummary.isEmpty {
                Text(comment.postSummary)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            DraftEditor(
                label: "Comment",
                text: $comment.draft,
                limit: nil,
                openLabel: "Open post",
                openURL: comment.url
            )
            if !comment.rationale.isEmpty {
                Text(comment.rationale)
                    .font(Theme.Font.micro)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.Metric.cornerMd).fill(Theme.Palette.bgSecondary))
    }

    private var contextLine: String {
        var parts: [String] = []
        if !comment.author.isEmpty { parts.append("On \(comment.author)'s post") }
        if !comment.postedAt.isEmpty { parts.append(comment.postedAt) }
        return parts.joined(separator: "  ·  ")
    }
}

/// An editable draft with a character counter, a copy button, and a link out to
/// the page where the user will actually paste it. Claudette never sends —
/// copy-and-open is the whole interaction.
struct DraftEditor: View {
    let label: String
    @Binding var text: String
    /// Character cap to warn about, if the destination field has one.
    let limit: Int?
    let openLabel: String
    let openURL: URL?

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(label.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.Palette.textTertiary)
                Spacer()
                if let limit {
                    Text("\(text.count)/\(limit)")
                        .font(Theme.Font.micro)
                        .foregroundStyle(text.count > limit ? DiffLine.removedRed : Theme.Palette.textTertiary)
                }
            }

            TextEditor(text: $text)
                .font(Theme.Font.bodySerif)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 64)
                .fixedSize(horizontal: false, vertical: true)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.Palette.bgPrimary))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.Palette.border, lineWidth: 0.75))

            HStack(spacing: 8) {
                Button {
                    copy()
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(Theme.Font.micro)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.Palette.bgSecondary))
                .foregroundStyle(Theme.Palette.textSecondary)

                if let openURL {
                    Button {
                        NSWorkspace.shared.open(openURL)
                    } label: {
                        Label(openLabel, systemImage: "arrow.up.right.square")
                            .font(Theme.Font.micro)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.Palette.bgSecondary))
                    .foregroundStyle(Theme.Palette.textSecondary)
                }
                Spacer()
            }
        }
    }

    private func copy() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        copied = true
        // Revert the label so the button doesn't read "Copied" forever.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            copied = false
        }
    }
}
