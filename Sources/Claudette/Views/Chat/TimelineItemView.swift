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
