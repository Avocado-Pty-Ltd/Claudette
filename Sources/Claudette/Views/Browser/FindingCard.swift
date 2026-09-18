import SwiftUI
import AppKit

/// One result: what it is, why the agent picked it, and any text it drafted.
/// Drafts are editable in place — the point of the card is that a human reads
/// and adjusts before using them, so that's the easy path.
struct FindingCard: View {
    @Binding var finding: Finding
    /// Character caps by draft label, from the recipe that started the run.
    let draftLimits: [String: Int]
    @State private var expanded: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow

            if expanded {
                if !finding.why.isEmpty {
                    Text(finding.why)
                        .font(Theme.Font.bodySerif)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if finding.drafts.isEmpty, let link = finding.link {
                    // Nothing drafted — still give them the way out to the page.
                    LinkButton(label: "Open", url: link)
                }

                ForEach($finding.drafts) { $draft in
                    DraftEditor(
                        label: draft.label.isEmpty ? "Draft" : draft.label,
                        text: $draft.text,
                        limit: draftLimits[draft.label],
                        openURL: draft.url ?? finding.link
                    )
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
                    Text(finding.title.isEmpty ? "Untitled result" : finding.title)
                        .font(Theme.Font.heading)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    confidencePill
                }
                if !finding.subtitle.isEmpty {
                    Text(finding.subtitle)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !details.isEmpty {
                    Text(details.joined(separator: "  ·  "))
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

    private var details: [String] {
        finding.details.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private var confidencePill: some View {
        Text(finding.confidence.label)
            .font(Theme.Font.micro)
            .foregroundStyle(Color(hex: finding.confidence.tintHex))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color(hex: finding.confidence.tintHex, alpha: 0.12)))
    }
}

/// An editable draft with a character counter, a copy button, and a link out to
/// the page where it'll be used. Claudette never submits anything — copy and
/// open is the whole interaction.
struct DraftEditor: View {
    let label: String
    @Binding var text: String
    /// Character cap to warn about, when the destination has one.
    let limit: Int?
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
                    LinkButton(label: "Open", url: openURL)
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

/// Small pill that opens a URL in the user's browser.
struct LinkButton: View {
    let label: String
    let url: URL

    var body: some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            Label(label, systemImage: "arrow.up.right.square")
                .font(Theme.Font.micro)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.Palette.bgSecondary))
        .foregroundStyle(Theme.Palette.textSecondary)
        .help(url.absoluteString)
    }
}
