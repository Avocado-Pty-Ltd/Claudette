import SwiftUI
import AppKit

/// The LinkedIn prospecting surface: type a goal, watch the browser agent work,
/// review what it drafted.
///
/// Claudette drafts; the user sends. There is no "send all" button here and
/// there isn't going to be one — LinkedIn's User Agreement forbids automated
/// connecting and posting, and a note nobody read isn't worth sending.
struct ProspectPanel: View {
    @EnvironmentObject var config: ProspectConfig
    @ObservedObject var runner: ProspectRunner
    @Environment(\.dismiss) private var dismiss

    /// Editable copy of the runner's report. Cards bind straight into this, so
    /// a tweak to a draft survives scrolling and "Copy all".
    @State private var working = ProspectReport()
    @State private var hasResult = false
    @State private var goal: String = ""
    @State private var showingLog = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.Palette.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if hasResult {
                        resultsSection
                    } else {
                        setupSection
                    }
                    if runner.state.isBusy || !runner.steps.isEmpty {
                        traceSection
                    }
                    if let error = runner.lastError, !error.isEmpty {
                        errorBanner(error)
                    }
                    if !runner.log.isEmpty {
                        logSection
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            footer
        }
        .frame(width: 720, height: 680)
        .background(Theme.Palette.bgPrimary)
        .onAppear {
            if goal.isEmpty { goal = runner.goal }
            if runner.environment == .unknown { runner.refreshEnvironment(config: config) }
            adoptReport(runner.report)
        }
        .onReceive(runner.$report) { adoptReport($0) }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.2.badge.plus")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.Palette.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("LinkedIn prospecting")
                    .font(Theme.Font.heading)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text(subtitle)
                    .font(Theme.Font.micro)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .lineLimit(1)
            }
            Spacer()
            if runner.state.isBusy {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            }
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.Palette.bgSecondary))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var subtitle: String {
        if !runner.statusLine.isEmpty { return runner.statusLine }
        if hasResult {
            let people = working.prospects.count
            let comments = working.allComments.count
            return "\(people) contact\(people == 1 ? "" : "s") · \(comments) comment draft\(comments == 1 ? "" : "s")"
        }
        return "Reads LinkedIn in your browser and drafts. You send."
    }

    // MARK: - Setup

    private var setupSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            readinessBanner

            VStack(alignment: .leading, spacing: 6) {
                Text("WHAT ARE YOU TRYING TO DO?")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.Palette.textSecondary)
                TextEditor(text: $goal)
                    .font(Theme.Font.bodySerif)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(height: 96)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.Palette.bgElevated))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.Palette.border, lineWidth: 0.75))
                Text("Plain English. The more specific the goal, the less the agent wanders.")
                    .font(Theme.Font.micro)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }

            if goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Self.examples, id: \.self) { example in
                        Button { goal = example } label: {
                            Text(example)
                                .font(Theme.Font.caption)
                                .foregroundStyle(Theme.Palette.textSecondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.Palette.bgSecondary))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Picker("", selection: $config.mode) {
                ForEach(ProspectMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            HStack(spacing: 22) {
                stepper("Contacts", value: $config.maxContacts, range: 1...25)
                if config.mode != .contacts {
                    stepper("Comments", value: $config.maxComments, range: 1...15)
                }
                Spacer()
                Toggle("Headless", isOn: $config.headless)
                    .toggleStyle(.switch)
                    .font(Theme.Font.caption)
                    .help("Off means you can watch the browser work — worth leaving off until you trust it.")
            }

            Text("Claudette opens Chrome with your own LinkedIn session, reads, and comes back with drafts. It never clicks Connect and never posts a comment — those stay yours, and doing them automatically would breach LinkedIn's User Agreement.")
                .font(Theme.Font.micro)
                .foregroundStyle(Theme.Palette.textTertiary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static let examples = [
        "Find Sydney-based founders of seed-stage AI infra startups I could learn from, and posts of theirs worth replying to.",
        "I'm hiring a senior iOS engineer — find people who've shipped SwiftUI apps and are open to work.",
        "Find heads of data at Australian insurers talking publicly about LLM adoption."
    ]

    private func stepper(_ label: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(Theme.Font.micro)
                .foregroundStyle(Theme.Palette.textSecondary)
            Stepper(value: value, in: range) {
                Text("\(value.wrappedValue)")
                    .font(Theme.Font.mono)
                    .foregroundStyle(Theme.Palette.textPrimary)
            }
            .fixedSize()
        }
    }

    // MARK: - Readiness

    @ViewBuilder
    private var readinessBanner: some View {
        switch runner.environment {
        case .ready(let interpreter, let version):
            HStack(spacing: 8) {
                Circle().fill(DiffLine.addedGreen).frame(width: 6, height: 6)
                Text("browser-use \(version) · \((interpreter as NSString).abbreviatingWithTildeInPath)")
                    .font(Theme.Font.micro)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        case .unknown:
            EmptyView()
        case .missingPackage, .missingPython:
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(hex: 0x8A7B4E))
                    Text(runner.environment.advice)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button {
                        runner.installBrowserUse(config: config)
                    } label: {
                        Label(runner.isInstalling ? "Installing…" : "Install browser-use", systemImage: "arrow.down.circle")
                            .font(Theme.Font.micro)
                    }
                    .disabled(runner.isInstalling)
                    Button("Re-check") { runner.refreshEnvironment(config: config) }
                        .font(Theme.Font.micro)
                        .disabled(runner.isInstalling)
                }
                if !runner.installLog.isEmpty {
                    ScrollView {
                        Text(runner.installLog)
                            .font(Theme.Font.monoSmall)
                            .foregroundStyle(Theme.Palette.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(height: 110)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.Palette.codeBg))
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: Theme.Metric.cornerMd).fill(Theme.Palette.bgSecondary))
        }
    }

    // MARK: - Live trace

    private var traceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("BROWSING")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.Palette.textSecondary)
            // Newest first: during a long run the interesting line is the last one,
            // and this keeps it at the top without fighting the scroll position.
            ForEach(Array(runner.steps.suffix(12).reversed())) { step in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(step.number)")
                        .font(Theme.Font.monoSmall)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .frame(width: 20, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.goal.isEmpty ? step.title : step.goal)
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        if !step.shortURL.isEmpty {
                            Text(step.shortURL)
                                .font(Theme.Font.monoSmall)
                                .foregroundStyle(Theme.Palette.textTertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Metric.cornerMd).fill(Theme.Palette.bgSecondary))
    }

    // MARK: - Results

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !working.summary.isEmpty {
                Text(working.summary)
                    .font(Theme.Font.bodySerif)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !working.blockedReason.isEmpty {
                errorBanner("The run stopped early: \(working.blockedReason)")
            }

            ForEach($working.prospects) { $prospect in
                ProspectCard(prospect: $prospect)
            }

            if !working.standaloneComments.isEmpty {
                Text("OTHER POSTS WORTH A COMMENT")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.Palette.textSecondary)
                ForEach($working.standaloneComments) { $comment in
                    CommentDraftView(comment: $comment)
                }
            }

            if working.isEmpty {
                Text("The agent came back with nothing. Try a narrower goal, or check the log below.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(DiffLine.removedRed)
            Text(message)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Metric.cornerMd).fill(Color(hex: 0xE5484D, alpha: 0.08)))
    }

    private var logSection: some View {
        DisclosureGroup(isExpanded: $showingLog) {
            ScrollView {
                Text(runner.log)
                    .font(Theme.Font.monoSmall)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 160)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.Palette.codeBg))
        } label: {
            Text("Agent log")
                .font(Theme.Font.micro)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if hasResult {
                Button("New search") {
                    hasResult = false
                    runner.clear()
                }
                Button {
                    copyAll()
                } label: { Text("Copy all") }
                Button {
                    NotificationCenter.default.post(
                        name: .claudetteFillDraft,
                        object: nil,
                        userInfo: ["text": working.markdown()]
                    )
                    dismiss()
                } label: { Label("Send to chat", systemImage: "arrow.turn.down.left") }
                .help("Drop the report into the chat box so Claude can rework the drafts with you.")
            }
            Spacer()
            if runner.state.isBusy {
                Button("Stop") { runner.cancel() }
                    .keyboardShortcut(".", modifiers: [.command])
            } else {
                Button {
                    runner.run(goal: goal, config: config)
                } label: {
                    Label("Search LinkedIn", systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || runner.isInstalling)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Theme.Palette.bgSecondary)
        .overlay(Divider().overlay(Theme.Palette.border), alignment: .top)
    }

    // MARK: - Plumbing

    /// Take a fresh report from the runner without clobbering edits the user has
    /// already made to the one on screen.
    private func adoptReport(_ incoming: ProspectReport?) {
        guard let incoming else { return }
        guard !hasResult || incoming != working else { return }
        working = incoming
        hasResult = true
    }

    private func copyAll() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(working.markdown(), forType: .string)
    }
}
