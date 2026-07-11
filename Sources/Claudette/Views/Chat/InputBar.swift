import SwiftUI
import AppKit

struct InputBar: View {
    @Binding var draft: String
    let isRunning: Bool
    let onSend: () -> Void
    let onStop: () -> Void
    @ObservedObject var speechInput: SpeechInput
    @State private var editorHeight: CGFloat = 24
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if showSlashPopup {
                SlashCommandPopup(matches: slashMatches) { command in
                    draft = "/" + command.name + (command.acceptsArgs ? " " : "")
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let err = speechInput.authError {
                voiceError(err)
                    .transition(.opacity)
            }
            Divider().overlay(Theme.Palette.border)
            HStack(alignment: .bottom, spacing: 10) {
                inputField
                micButton
                sendButton
            }
            .padding(.horizontal, Theme.Metric.contentPadding)
            .padding(.vertical, 18)
            .background(Theme.Palette.bgPrimary)
        }
        .animation(.easeInOut(duration: 0.18), value: showSlashPopup)
        .animation(.easeInOut(duration: 0.18), value: speechInput.authError)
    }

    private var micButton: some View {
        Button {
            Task { await speechInput.toggle() }
        } label: {
            ZStack {
                Circle()
                    .fill(speechInput.isListening ? Theme.Palette.accent : Theme.Palette.bgSecondary)
                    .overlay(
                        Circle().stroke(speechInput.isListening ? Theme.Palette.accent : Theme.Palette.border,
                                        lineWidth: 0.75)
                    )
                if speechInput.isListening {
                    Circle()
                        .stroke(Theme.Palette.accent, lineWidth: 1.5)
                        .scaleEffect(1.25)
                        .opacity(0.6)
                        .transition(.opacity)
                }
                Image(systemName: speechInput.isListening ? "waveform" : "mic.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(speechInput.isListening ? .white : Theme.Palette.textSecondary)
            }
            .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .help(speechInput.isListening ? "Stop dictating" : "Dictate a message")
    }

    private func voiceError(_ msg: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 10, weight: .semibold))
            Text(msg)
                .font(Theme.Font.caption)
                .lineLimit(2)
        }
        .foregroundStyle(DiffLine.removedRed)
        .padding(.horizontal, Theme.Metric.contentPadding)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DiffLine.removedRed.opacity(0.06))
    }

    private var showSlashPopup: Bool {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("/") && !trimmed.contains(" ") && !slashMatches.isEmpty
    }

    private var slashMatches: [SlashCommand] {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("/") else { return [] }
        let query = String(trimmed.dropFirst()).lowercased()
        return SlashCommand.all.filter {
            query.isEmpty || $0.name.hasPrefix(query)
        }
    }

    private var inputField: some View {
        AutoResizingTextEditor(text: $draft, height: $editorHeight, onSubmit: submitIfPossible)
            .frame(height: editorHeight)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.Palette.bgElevated)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Theme.Palette.border, lineWidth: 1)
                    )
            )
    }

    private var sendButton: some View {
        Group {
            if isRunning {
                Button(action: onStop) {
                    stopIcon
                }
                .buttonStyle(.plain)
                .help("Stop")
            } else {
                Button(action: submitIfPossible) {
                    sendIcon
                }
                .buttonStyle(.plain)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Send (⌘↩)")
                .keyboardShortcut(.return, modifiers: [.command])
            }
        }
    }

    private var sendIcon: some View {
        Image(systemName: "arrow.up")
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .background(
                Circle()
                    .fill(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          ? Theme.Palette.textTertiary
                          : Theme.Palette.accent)
            )
    }

    private var stopIcon: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(.white)
            .frame(width: 12, height: 12)
            .frame(width: 36, height: 36)
            .background(
                Circle().fill(Theme.Palette.textPrimary)
            )
    }

    private func submitIfPossible() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning else { return }
        onSend()
    }
}

/// A multi-line NSTextView wrapper that auto-sizes vertically and supports:
///  - Return: send (calls onSubmit)
///  - Shift+Return / Option+Return: newline
///  - Beautiful default typography
struct AutoResizingTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var onSubmit: () -> Void
    var minHeight: CGFloat = 24
    var maxHeight: CGFloat = 220

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.verticalScroller?.controlSize = .small
        scroll.hasHorizontalScroller = false
        scroll.autoresizingMask = [.width]
        scroll.borderType = .noBorder

        let textView = ClaudetteTextView()
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = NSColor(Theme.Palette.textPrimary)
        textView.insertionPointColor = NSColor(Theme.Palette.accent)
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = context.coordinator
        textView.onSubmit = { onSubmit() }
        textView.placeholderString = "Ask Claudette anything about this project…"

        scroll.documentView = textView
        context.coordinator.textView = textView

        // Defer focus until the view has actually been added to a window.
        // Calling becomeFirstResponder before that raises NSInternalInconsistencyException.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak textView] in
            guard let tv = textView, let window = tv.window else { return }
            window.makeFirstResponder(tv)
            self.recalcHeight(textView: tv)
        }
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tv = context.coordinator.textView else { return }
        if tv.string != text {
            tv.string = text
            tv.needsDisplay = true
        }
        recalcHeight(textView: tv)
    }

    private func recalcHeight(textView: NSTextView) {
        guard let container = textView.textContainer, let manager = textView.layoutManager else { return }
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container).size
        let target = min(max(used.height + textView.textContainerInset.height * 2, minHeight), maxHeight)
        if abs(target - height) > 0.5 {
            DispatchQueue.main.async {
                self.height = target
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text) { textView in
            recalcHeight(textView: textView)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var onChange: (NSTextView) -> Void
        weak var textView: NSTextView?

        init(text: Binding<String>, onChange: @escaping (NSTextView) -> Void) {
            self.text = text
            self.onChange = onChange
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            text.wrappedValue = tv.string
            tv.needsDisplay = true
            onChange(tv)
        }
    }
}

final class ClaudetteTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var placeholderString: String = ""

    override func keyDown(with event: NSEvent) {
        // Return sends; shift/option-return inserts a newline.
        if event.keyCode == 36 { // return
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if mods.contains(.shift) || mods.contains(.option) {
                super.keyDown(with: event)
                return
            }
            if mods.isEmpty || mods == [.command] {
                onSubmit?()
                return
            }
        }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholderString.isEmpty else { return }
        let font = self.font ?? NSFont.systemFont(ofSize: 14)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(Theme.Palette.textTertiary)
        ]
        let inset = textContainerInset
        let origin = NSPoint(x: inset.width + 5, y: inset.height + 4)
        (placeholderString as NSString).draw(at: origin, withAttributes: attrs)
    }
}
