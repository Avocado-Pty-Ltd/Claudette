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
        case .pendingQuestion(let question):
            PendingQuestionView(question: question)
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
                    case .cancelled:
                        Text("No longer waiting — Claude moved on or the session ended.")
                            .foregroundStyle(Theme.Palette.textTertiary)
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
        case .denied, .cancelled: return Color(hex: 0x8A8580)   // graphite
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
        case .cancelled: return "xmark.circle"
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
        case .cancelled: return "EXPIRED"
        }
    }
}

/// AskUserQuestion, rendered from the control_request that actually wants
/// an answer (not from the assistant's tool_use block, which can't know when
/// it's been answered). One card per request; each question inside shows
/// its own state — answered ones collapse to the chosen label, the current
/// one gets live buttons, later ones wait dimmed. Single-select buttons
/// answer on tap; multi-select uses checkboxes plus a Submit. Typing or
/// speaking a reply is the "Other" route and lands on the current question.
struct PendingQuestionView: View {
    let question: PendingQuestion
    @EnvironmentObject private var session: ClaudeChatSession
    /// Multi-select picks that haven't been submitted yet, keyed by question
    /// text. View-local: nothing on the wire until Submit.
    @State private var picks: [String: Set<String>] = [:]

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            iconWell
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Text("QUESTION")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(1.6)
                        .foregroundStyle(hue.opacity(0.85))
                    if question.questions.count > 1 {
                        Text("\(question.answers.count)/\(question.questions.count)")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
                    statusPill
                    Spacer(minLength: 0)
                }
                ForEach(Array(question.questions.enumerated()), id: \.offset) { idx, q in
                    questionBlock(q, index: idx)
                }
                footer
            }
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(hue.opacity(0.06))
        )
    }

    // MARK: - Per-question

    private enum Phase { case answered(String), current, upcoming }

    private func phase(of q: InteractiveQuestion) -> Phase {
        if let a = question.answers[q.question] { return .answered(a) }
        if question.status == .asking, question.currentQuestion?.question == q.question { return .current }
        return .upcoming
    }

    @ViewBuilder
    private func questionBlock(_ q: InteractiveQuestion, index: Int) -> some View {
        let phase = phase(of: q)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if question.questions.count > 1 {
                    Text("\(index + 1)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(isActive(phase) ? hue : Theme.Palette.textTertiary.opacity(0.5)))
                }
                if let header = q.header, !header.isEmpty {
                    Text(header.uppercased())
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            }
            Text(q.question)
                .font(Theme.Font.cinemaBody)
                .foregroundStyle(isActive(phase) ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                .lineSpacing(5)
                .textSelection(.enabled)

            switch phase {
            case .answered(let answer):
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color(hex: 0x4E8A7A))
                    Text(answer)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textPrimary)
                }
                .font(.system(size: 12))
            case .current:
                if q.multiSelect { multiSelectOptions(q) } else { singleSelectOptions(q) }
            case .upcoming:
                if question.status == .asking {
                    Text("\(q.options.count) options — after the one above.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                } else {
                    Text(q.options.map(\.label).joined(separator: " / "))
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            }
        }
        .opacity(isActive(phase) ? 1 : 0.75)
    }

    private func isActive(_ phase: Phase) -> Bool {
        if case .current = phase { return true }
        return false
    }

    private func singleSelectOptions(_ q: InteractiveQuestion) -> some View {
        VStack(spacing: 8) {
            ForEach(Array(q.options.enumerated()), id: \.offset) { _, option in
                AskOptionButton(option: option) {
                    session.answerQuestion(requestId: question.requestId,
                                           questionText: q.question,
                                           answer: option.label)
                }
            }
        }
    }

    private func multiSelectOptions(_ q: InteractiveQuestion) -> some View {
        let selected = picks[q.question] ?? []
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(q.options.enumerated()), id: \.offset) { _, option in
                MultiSelectOptionRow(option: option, isOn: selected.contains(option.label)) {
                    var set = picks[q.question] ?? []
                    if set.contains(option.label) { set.remove(option.label) } else { set.insert(option.label) }
                    picks[q.question] = set
                }
            }
            Button {
                // Preserve the CLI's option order rather than Set order.
                let ordered = q.options.map(\.label).filter { selected.contains($0) }
                session.answerQuestion(requestId: question.requestId,
                                       questionText: q.question,
                                       answer: ordered.joined(separator: ", "))
            } label: {
                Text(selected.isEmpty ? "Choose one or more" : "Submit \(selected.count) selected")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule(style: .continuous).fill(selected.isEmpty ? Theme.Palette.textTertiary : hue))
            }
            .buttonStyle(.plain)
            .disabled(selected.isEmpty)
            .padding(.top, 2)
        }
    }

    // MARK: - Chrome

    private var footer: some View {
        Group {
            switch question.status {
            case .asking:
                Text("Pick an option, or type or say something else.")
                    .foregroundStyle(Theme.Palette.textTertiary)
            case .answered:
                Text("Answered.")
                    .foregroundStyle(Color(hex: 0x4E8A7A))
            case .cancelled:
                Text("No longer waiting — Claude moved on or the session ended.")
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
        .font(.system(size: 12, weight: .medium))
    }

    private var hue: Color {
        switch question.status {
        case .asking: return Color(hex: 0xC96442)
        case .answered: return Color(hex: 0x4E8A7A)
        case .cancelled: return Color(hex: 0x8A8580)
        }
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
        switch question.status {
        case .asking: return "questionmark.bubble.fill"
        case .answered: return "checkmark.circle.fill"
        case .cancelled: return "xmark.circle"
        }
    }

    private var statusPill: some View {
        Text(statusLabel)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .tracking(1.2)
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule(style: .continuous).fill(hue.opacity(0.85)))
    }

    private var statusLabel: String {
        switch question.status {
        case .asking: return "ASKING"
        case .answered: return "ANSWERED"
        case .cancelled: return "EXPIRED"
        }
    }
}

/// Checkbox row for multi-select questions — same silhouette as
/// `AskOptionButton` so the two kinds of question read as siblings.
struct MultiSelectOptionRow: View {
    let option: InteractiveOption
    let isOn: Bool
    let onToggle: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: onToggle) {
            HStack(alignment: .top, spacing: 14) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(isOn ? Theme.Palette.accent : Theme.Palette.borderStrong, lineWidth: 1.2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(isOn ? Theme.Palette.accent : Color.clear)
                    )
                    .overlay(
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .opacity(isOn ? 1 : 0)
                    )
                    .frame(width: 16, height: 16)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 4) {
                    Text(option.label)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textPrimary)
                    if let desc = option.description, !desc.isEmpty {
                        Text(desc)
                            .font(Theme.Font.bodySerif)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 6)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(hovered || isOn ? Theme.Palette.bgSecondary : Theme.Palette.bgPrimary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isOn ? Theme.Palette.accent.opacity(0.6)
                            : hovered ? Theme.Palette.accent.opacity(0.4) : Theme.Palette.border,
                            lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
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
