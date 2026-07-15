import SwiftUI

/// Root dispatcher — routes a timeline item to the right rendered view.
struct TimelineItemView: View {
    let item: TimelineItem

    var body: some View {
        switch item.kind {
        case .userText(let text, let images):
            UserMessageView(text: text, images: images)
        case .assistantText(let text, let isStreaming):
            AssistantTextView(text: text, isStreaming: isStreaming)
        case .thinking(let text):
            ThinkingView(text: text)
        case .action(let event):
            ActionEventView(event: event)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .system(let text):
            SystemNoticeView(text: text)
        case .pendingPermission(let permission):
            PendingPermissionView(permission: permission)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Bubbles

struct UserMessageView: View {
    let text: String
    let images: [UserImage]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: 8) {
                if !images.isEmpty {
                    // Horizontally-wrapping row of thumbnails above the text.
                    // Trailing-aligned so multiple attachments stack neatly
                    // against the right edge of the bubble.
                    FlowLayout(alignment: .trailing, spacing: 6) {
                        ForEach(images) { img in
                            AttachmentThumbnail(image: img, size: 72)
                        }
                    }
                    .frame(maxWidth: 520, alignment: .trailing)
                }
                if !text.isEmpty {
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
    }
}

/// Small rounded thumbnail. Uses NSImage on macOS via a NSViewRepresentable so
/// arbitrary image data (PNG, JPEG, HEIC, GIF first frame) renders without a
/// per-format branch.
struct AttachmentThumbnail: View {
    let image: UserImage
    var size: CGFloat = 72

    var body: some View {
        Group {
            if let nsImage = NSImage(data: image.data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Theme.Palette.border, lineWidth: 0.5)
        )
    }
}

/// Minimal flow-layout that wraps children onto multiple lines, aligning each
/// line to a given horizontal edge. Used for the attachment thumbnail row so
/// several images stack against the trailing edge of the user bubble.
struct FlowLayout: Layout {
    var alignment: HorizontalAlignment = .leading
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        var rows: [(width: CGFloat, height: CGFloat)] = [(0, 0)]
        for s in sizes {
            var row = rows[rows.count - 1]
            let width = row.width + (row.width == 0 ? 0 : spacing) + s.width
            if width > maxWidth && row.width > 0 {
                rows.append((s.width, s.height))
            } else {
                row.width = width
                row.height = max(row.height, s.height)
                rows[rows.count - 1] = row
            }
        }
        let totalHeight = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        let totalWidth = rows.map(\.width).max() ?? 0
        return CGSize(width: totalWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        var rows: [[Int]] = [[]]
        var rowWidths: [CGFloat] = [0]
        for (i, s) in sizes.enumerated() {
            var w = rowWidths[rowWidths.count - 1]
            let candidate = w + (w == 0 ? 0 : spacing) + s.width
            if candidate > bounds.width && w > 0 {
                rows.append([i])
                rowWidths.append(s.width)
            } else {
                rows[rows.count - 1].append(i)
                rowWidths[rowWidths.count - 1] = candidate
                w = candidate
            }
        }
        var y = bounds.minY
        for (r, row) in rows.enumerated() {
            let rowW = rowWidths[r]
            let rowH = row.map { sizes[$0].height }.max() ?? 0
            var x: CGFloat
            switch alignment {
            case .trailing: x = bounds.maxX - rowW
            case .center:   x = bounds.midX - rowW / 2
            default:        x = bounds.minX
            }
            for i in row {
                let s = sizes[i]
                subviews[i].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(s))
                x += s.width + spacing
            }
            y += rowH + spacing
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

/// Card shown when Claude Code fires a control_request and Claudette turns it
/// into a conversational ask. Distinct from action cards — the icon, hue, and
/// hint line all make it obvious the user is being asked, not just informed.
/// The user answers with their next message; on resolution the card updates
/// in place with the allow/deny status and (if denied) the guidance they gave.
struct PendingPermissionView: View {
    let permission: PendingPermission

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            iconWell
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(permission.toolName.uppercased())
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(1.6)
                        .foregroundStyle(hue.opacity(0.85))
                    statusPill
                    Spacer(minLength: 0)
                }
                Text(permission.prompt)
                    .font(Theme.Font.bodySerif)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                // The prompt above already reads "May I run `foo`?", so it
                // repeats the summary. What's useful in the mono block is the
                // raw input payload — for a Write tool the JSON reveals
                // `file_path` + `content`, for a WebFetch the request body,
                // etc. Hide the block entirely when the payload is trivial
                // (empty object, or Bash where the command IS the summary).
                if let payload = inputPayloadForDisplay {
                    Text(payload)
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineSpacing(2)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.white.opacity(0.03))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(Theme.Palette.border, lineWidth: 0.5)
                                )
                        )
                        .textSelection(.enabled)
                }
                Group {
                    switch permission.status {
                    case .pending:
                        Text("Say “yes” to run it, or tell me what to do differently.")
                            .foregroundStyle(Theme.Palette.textTertiary)
                    case .allowed:
                        Text("Approved.")
                            .foregroundStyle(Color(hex: 0x4E8A7A))
                    case .denied:
                        if let reason = permission.reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty {
                            Text("Skipped — “\(reason)”")
                                .foregroundStyle(Theme.Palette.textTertiary)
                        } else {
                            Text("Skipped.")
                                .foregroundStyle(Theme.Palette.textTertiary)
                        }
                    }
                }
                .font(.system(size: 12, weight: .medium))
            }
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(hue.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(hue.opacity(0.35), lineWidth: 0.8)
                )
        )
    }

    private var hue: Color {
        // Amber-ish while pending, green when allowed, muted grey when denied
        // — the status colour reaches the whole card, not just the pill,
        // so a scan of the timeline immediately shows resolved vs open asks.
        switch permission.status {
        case .pending: return Color(hex: 0xC96442)   // Claudette accent orange
        case .allowed: return Color(hex: 0x4E8A7A)   // teal
        case .denied:  return Color(hex: 0x8A8580)   // graphite
        }
    }

    /// The raw input JSON to render in the mono block below the prompt, or
    /// nil to hide the block entirely. Skipped when the prompt already carries
    /// the full payload (Bash's command lives verbatim in "May I run `X`?")
    /// or when the payload is empty — both cases would show noise.
    private var inputPayloadForDisplay: String? {
        let json = permission.inputJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        if json.isEmpty || json == "{}" { return nil }
        if permission.toolName.lowercased() == "bash" { return nil }
        return json
    }

    private var iconWell: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hue.opacity(0.15))
                .frame(width: 32, height: 32)
            Image(systemName: iconName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(hue)
        }
    }

    private var iconName: String {
        switch permission.status {
        case .pending: return "hand.raised.fill"
        case .allowed: return "checkmark.circle.fill"
        case .denied:  return "hand.thumbsdown.fill"
        }
    }

    private var statusPill: some View {
        Text(statusLabel)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .tracking(1.2)
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous).fill(hue.opacity(0.85))
            )
    }

    private var statusLabel: String {
        switch permission.status {
        case .pending: return "ASKING"
        case .allowed: return "ALLOWED"
        case .denied:  return "SKIPPED"
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
