import SwiftUI

/// A skimmable "video-frame" style card for a single tool action. It reads as a
/// discrete beat: what Claude did, on what, and how it turned out.
struct ActionEventView: View {
    let event: ActionEvent
    @State private var expanded: Bool = false
    @State private var appeared: Bool = false
    @State private var focusZoom: Bool = false
    @State private var glowPulse: Bool = false
    @State private var manualOverride: Bool? = nil  // user's chevron toggle wins until it goes off-screen
    @State private var hasBeenSeen: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if shouldShowBody {
                bodyView
                    .padding(.top, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: Theme.Metric.cornerLg, style: .continuous)
                .fill(cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metric.cornerLg, style: .continuous)
                .stroke(cardBorder, lineWidth: 0.75)
        )
        .overlay(
            // Camera-pull glow — bright the moment the result lands, fades out.
            RoundedRectangle(cornerRadius: Theme.Metric.cornerLg, style: .continuous)
                .stroke(Color(hex: event.category.tintHex).opacity(glowPulse ? 0.55 : 0.0), lineWidth: 2)
                .blur(radius: 3)
                .allowsHitTesting(false)
        )
        .shadow(color: shadowColor, radius: focusZoom ? 18 : (appeared ? 6 : 0), x: 0, y: focusZoom ? 6 : (appeared ? 2 : 0))
        .scaleEffect(scaleForState)
        .opacity(appeared ? 1.0 : 0.0)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.78).delay(0.02)) {
                appeared = true
            }
        }
        .onScrollVisibilityChange(threshold: 0.3) { visible in
            handleVisibilityChange(visible)
        }
        .onChange(of: event.status) { _, newStatus in
            if newStatus == .success && expanded {
                playFocusZoom()
            } else if newStatus == .error {
                // Small settle on error too so the eye tracks the change.
                withAnimation(.spring(response: 0.35, dampingFraction: 0.65)) {
                    focusZoom = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) {
                        focusZoom = false
                    }
                }
            }
        }
    }

    /// The core "cinema" behaviour: card plays *once* — expands the first time it enters the
    /// viewport, then collapses when it leaves and stays collapsed if you scroll back up.
    /// The chevron override always wins for as long as the card is on-screen.
    private func handleVisibilityChange(_ visible: Bool) {
        if visible {
            if hasBeenSeen {
                // Re-entry after having played — stay collapsed unless the user opens it.
                // Nothing to do; leave `expanded` in whatever state it was in.
                return
            }
            hasBeenSeen = true
            let wantExpanded = manualOverride ?? true
            if expanded != wantExpanded {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) {
                    expanded = wantExpanded
                }
            }
        } else {
            // Only auto-collapse *after* the user has seen it at least once — avoids
            // collapsing a still-below-the-fold card on first render.
            guard hasBeenSeen else { return }
            // Reset the user's manual toggle so re-opening from the chevron works cleanly.
            manualOverride = nil
            if expanded {
                withAnimation(.easeInOut(duration: 0.35)) {
                    expanded = false
                }
            }
        }
    }

    private func toggleManual() {
        let target = !expanded
        manualOverride = target
        withAnimation(.easeInOut(duration: 0.22)) { expanded = target }
    }

    /// The "camera-pull" — overshoot up to 1.06 then settle to 1.0, with a matching glow.
    private func playFocusZoom() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.55)) {
            focusZoom = true
            glowPulse = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.75)) {
                focusZoom = false
            }
            withAnimation(.easeOut(duration: 0.9)) {
                glowPulse = false
            }
        }
    }

    private var scaleForState: CGFloat {
        if !appeared { return 0.86 }
        if focusZoom { return 1.045 }
        return 1.0
    }

    private var shouldShowBody: Bool {
        expanded && hasBody
    }

    private var hasBody: Bool {
        switch event.category {
        case .edit, .multiEdit:
            return (event.oldString != nil && event.newString != nil) || (event.edits?.isEmpty == false)
        case .write:
            return (event.newString ?? event.content) != nil
        case .bash:
            return !event.result.isEmpty || event.command != nil
        case .read, .search, .glob, .web:
            return !event.result.isEmpty
        case .todo:
            return (event.todos?.isEmpty == false)
        case .ask:
            return (event.questions?.isEmpty == false)
        case .task, .other:
            return !event.result.isEmpty || !event.inputJSON.isEmpty
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            iconBadge
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(event.humanTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    diffCountsChip
                    if let chip = event.summaryChip, !isEditLike {
                        chipView(chip)
                    }
                }
                if let subtitle = subtitleText {
                    Text(subtitle)
                        .font(Theme.Font.monoSmall)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 6)
            statusPill
            if hasBody {
                Button(action: toggleManual) {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var subtitleText: String? {
        switch event.category {
        case .edit, .multiEdit, .write, .read:
            if let path = event.filePath { return path }
            return nil
        case .bash:
            return event.description
        case .web:
            return event.url
        case .search, .glob:
            if let path = event.filePath { return path }
            return nil
        case .task:
            return event.description
        case .ask:
            return event.questions?.first?.header
        case .todo, .other:
            return nil
        }
    }

    private var iconBadge: some View {
        let tint = Color(hex: event.category.tintHex)
        return ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(tint.opacity(0.14))
                .frame(width: 34, height: 34)
            Image(systemName: event.category.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
        }
    }

    private func chipView(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(Theme.Palette.textSecondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(Theme.Palette.bgSecondary)
            )
    }

    /// Two-tone counts chip — `+adds` in green, `−dels` in red — for edit/write actions.
    @ViewBuilder
    private var diffCountsChip: some View {
        if isEditLike {
            let stats = event.diffStats
            if stats.additions > 0 || stats.deletions > 0 {
                HStack(spacing: 5) {
                    if stats.additions > 0 {
                        Text("+\(stats.additions)")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(DiffLine.addedGreen)
                    }
                    if stats.deletions > 0 {
                        Text("−\(stats.deletions)")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(DiffLine.removedRed)
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(
                    Capsule(style: .continuous)
                        .fill(Theme.Palette.bgSecondary)
                )
            }
        }
    }

    private var isEditLike: Bool {
        switch event.category {
        case .edit, .multiEdit, .write: return true
        default: return false
        }
    }

    private var statusPill: some View {
        Group {
            switch event.status {
            case .running:
                HStack(spacing: 5) {
                    RunningDot()
                    Text("Working")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Theme.Palette.bgSecondary))
            case .success:
                HStack(spacing: 4) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                    Text("Done")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(DiffLine.addedGreen)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(DiffLine.addedGreen.opacity(0.14)))
            case .error:
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 9, weight: .bold))
                    Text(errorPillLabel)
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(DiffLine.removedRed)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(DiffLine.removedRed.opacity(0.14)))
            }
        }
    }

    private var errorPillLabel: String {
        // For an ask that errored, "Awaiting" reads better than "Error".
        event.category == .ask ? "Awaiting" : "Error"
    }

    // MARK: - Body

    @ViewBuilder
    private var bodyView: some View {
        switch event.category {
        case .edit, .multiEdit:
            editBody
        case .write:
            writeBody
        case .bash:
            bashBody
        case .read:
            readBody
        case .search, .glob:
            searchBody
        case .web:
            webBody
        case .todo:
            todoBody
        case .ask:
            askBody
        case .task, .other:
            genericBody
        }
    }

    private var editBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let edits = event.edits, !edits.isEmpty {
                ForEach(Array(edits.enumerated()), id: \.offset) { i, pair in
                    if i > 0 {
                        Rectangle().fill(Theme.Palette.border).frame(height: 0.5).padding(.vertical, 2)
                    }
                    DiffView(old: pair.old, new: pair.new, animateIn: event.status == .success)
                }
            } else if let old = event.oldString, let new = event.newString {
                DiffView(old: old, new: new, animateIn: event.status == .success)
            }
            if event.isError, !event.result.isEmpty {
                errorNotice
            }
        }
    }

    private var writeBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let new = event.newString ?? event.content, !new.isEmpty {
                DiffView(old: "", new: new, animateIn: event.status == .success)
            }
            if event.isError, !event.result.isEmpty {
                errorNotice
            }
        }
    }

    private var bashBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let cmd = event.command, !cmd.isEmpty {
                TerminalCard(command: cmd, output: event.result, isError: event.isError, isRunning: event.status == .running)
            } else if !event.result.isEmpty {
                Text(event.result)
                    .font(Theme.Font.monoSmall)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Theme.Palette.codeBg)
                    )
            }
        }
    }

    private var readBody: some View {
        preformattedOutput(truncateLines: 24)
    }

    private var searchBody: some View {
        preformattedOutput(truncateLines: 32)
    }

    private var webBody: some View {
        preformattedOutput(truncateLines: 30)
    }

    private var todoBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let todos = event.todos {
                ForEach(Array(todos.enumerated()), id: \.offset) { _, todo in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: iconForTodo(todo.status))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(colorForTodo(todo.status))
                            .frame(width: 16, alignment: .center)
                            .padding(.top, 1)
                        Text(todo.content)
                            .font(Theme.Font.body)
                            .foregroundStyle(todo.status == "completed" ? Theme.Palette.textTertiary : Theme.Palette.textPrimary)
                            .strikethrough(todo.status == "completed", color: Theme.Palette.textTertiary)
                    }
                }
            }
        }
    }

    private var askBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let questions = event.questions {
                ForEach(Array(questions.enumerated()), id: \.offset) { qIdx, q in
                    VStack(alignment: .leading, spacing: 10) {
                        if questions.count > 1 {
                            Text("Question \(qIdx + 1) of \(questions.count)")
                                .font(.system(size: 10, weight: .semibold))
                                .tracking(1.2)
                                .foregroundStyle(Theme.Palette.textTertiary)
                        }
                        Text(q.question)
                            .font(Theme.Font.cinemaBody)
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .lineSpacing(5)
                        VStack(spacing: 8) {
                            ForEach(Array(q.options.enumerated()), id: \.offset) { _, option in
                                AskOptionButton(option: option) {
                                    fillDraft(with: option.label)
                                }
                            }
                        }
                    }
                }
                Text("Click an option to send it as your reply.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
    }

    private func fillDraft(with text: String) {
        NotificationCenter.default.post(name: .claudetteFillDraft, object: nil, userInfo: ["text": text])
    }

    private var genericBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !event.inputJSON.isEmpty {
                sectionLabel("Input")
                jsonBlock(event.inputJSON)
            }
            if !event.result.isEmpty {
                sectionLabel(event.isError ? "Error" : "Result")
                jsonBlock(event.result)
            }
        }
    }

    // MARK: - Helpers

    private var errorNotice: some View {
        Text(event.result)
            .font(Theme.Font.monoSmall)
            .foregroundStyle(Color(hex: 0xC7515C))
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(hex: 0xC7515C).opacity(0.08))
            )
    }

    private func preformattedOutput(truncateLines: Int) -> some View {
        let text: String = {
            let lines = event.result.split(separator: "\n", omittingEmptySubsequences: false)
            if lines.count > truncateLines {
                return lines.prefix(truncateLines).joined(separator: "\n") + "\n…"
            }
            return event.result
        }()
        return ScrollView(.horizontal, showsIndicators: false) {
            Text(text)
                .font(Theme.Font.cinemaMono)
                .foregroundStyle(Theme.Palette.textPrimary)
                .textSelection(.enabled)
                .padding(14)
                .frame(minWidth: 0, alignment: .leading)
        }
        .frame(maxHeight: 340)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.Palette.codeBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Theme.Palette.codeBorder, lineWidth: 0.5)
        )
    }

    private func jsonBlock(_ text: String) -> some View {
        Text(text)
            .font(Theme.Font.monoSmall)
            .foregroundStyle(Theme.Palette.textPrimary)
            .textSelection(.enabled)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.Palette.codeBg)
            )
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .tracking(1.3)
            .foregroundStyle(Theme.Palette.textTertiary)
    }

    private func iconForTodo(_ status: String) -> String {
        switch status {
        case "completed": return "checkmark.circle.fill"
        case "in_progress": return "circle.dotted"
        default: return "circle"
        }
    }

    private func colorForTodo(_ status: String) -> Color {
        switch status {
        case "completed": return Color(hex: 0x4A9C6E)
        case "in_progress": return Theme.Palette.accent
        default: return Theme.Palette.textTertiary
        }
    }

    private var cardBackground: Color {
        switch event.status {
        case .running: return Theme.Palette.bgElevated
        case .success: return Theme.Palette.bgElevated
        case .error:
            return event.category == .ask ? Theme.Palette.bgElevated : Color(hex: 0xC7515C).opacity(0.05)
        }
    }

    private var cardBorder: Color {
        switch event.status {
        case .running: return Theme.Palette.accent.opacity(0.35)
        case .success: return Theme.Palette.border
        case .error:
            return event.category == .ask
                ? Color(hex: event.category.tintHex).opacity(0.4)
                : Color(hex: 0xC7515C).opacity(0.35)
        }
    }

    private var shadowColor: Color {
        switch event.status {
        case .running: return Theme.Palette.accent.opacity(0.12)
        case .success: return Color(hex: event.category.tintHex).opacity(focusZoom ? 0.35 : 0.06)
        case .error: return Color.black.opacity(0.06)
        }
    }
}

// MARK: - Ask option button

struct AskOptionButton: View {
    let option: InteractiveOption
    let onTap: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 14) {
                Circle()
                    .stroke(Theme.Palette.borderStrong, lineWidth: 1.2)
                    .background(Circle().fill(hovered ? Theme.Palette.accent : Color.clear))
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
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(hovered ? Theme.Palette.accent : Theme.Palette.textTertiary)
                    .padding(.top, 5)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(hovered ? Theme.Palette.bgSecondary : Theme.Palette.bgPrimary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(hovered ? Theme.Palette.accent.opacity(0.4) : Theme.Palette.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

// MARK: - Small helpers

struct RunningDot: View {
    @State private var pulse = false
    var body: some View {
        Circle()
            .fill(Theme.Palette.accent)
            .frame(width: 6, height: 6)
            .scaleEffect(pulse ? 1.35 : 1.0)
            .opacity(pulse ? 0.55 : 1.0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }
}

struct TerminalCard: View {
    let command: String
    let output: String
    let isError: Bool
    let isRunning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("$")
                    .font(Theme.Font.cinemaMonoBold)
                    .foregroundStyle(Theme.Palette.accent)
                Text(command)
                    .font(Theme.Font.cinemaMono)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .textSelection(.enabled)
                    .lineLimit(4)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if isRunning {
                    RunningDot()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.Palette.codeBg)
            .overlay(Divider().overlay(Theme.Palette.codeBorder), alignment: .bottom)

            if !output.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(output)
                        .font(Theme.Font.cinemaMono)
                        .foregroundStyle(isError ? Color(hex: 0xC7515C) : Theme.Palette.textPrimary)
                        .textSelection(.enabled)
                        .padding(14)
                        .frame(minWidth: 0, alignment: .leading)
                }
                .frame(maxHeight: 300)
                .background(Color.black.opacity(0.02))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.Palette.codeBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Theme.Palette.codeBorder, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
