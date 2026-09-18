import SwiftUI
import AppKit

/// The browser-task surface: pick a recipe (or don't), type a goal, watch the
/// agent work, review what it found.
///
/// Claudette drafts; the user acts. Read-only runs can't submit, post or send —
/// which is also why a recipe can safely run on a schedule while nobody's
/// watching.
struct BrowserTaskPanel: View {
    @EnvironmentObject var config: BrowserAgentConfig
    @EnvironmentObject var recipes: RecipeStore
    @EnvironmentObject var scheduler: TaskScheduler
    @ObservedObject var runner: BrowserTaskRunner
    @Environment(\.dismiss) private var dismiss

    /// Editable copy of the runner's report. Cards bind straight into this, so a
    /// tweak to a draft survives scrolling and "Copy all".
    @State private var working = TaskReport()
    @State private var hasResult = false
    @State private var goal: String = ""
    @State private var recipeId: String = ""
    @State private var startURL: String = ""
    @State private var allowedDomains: String = ""
    @State private var readOnly: Bool = true
    @State private var maxFindings: Int = 8
    @State private var showingLog = false
    @State private var showingOptions = false

    private var recipe: BrowserRecipe? { recipes.recipe(id: recipeId) }

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
                        banner(error, tint: DiffLine.removedRed)
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
        .frame(width: 740, height: 700)
        .background(Theme.Palette.bgPrimary)
        .onAppear {
            recipes.reload()
            if goal.isEmpty { goal = runner.goal }
            if recipeId.isEmpty { applyRecipe(id: config.lastRecipeId) }
            if runner.environment == .unknown { runner.refreshEnvironment(config: config) }
            adoptReport(runner.report)
        }
        .onReceive(runner.$report) { adoptReport($0) }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: recipe?.symbolName ?? "globe")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.Palette.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(recipe?.name ?? "Browser task")
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
            let results = working.findings.count
            let drafts = working.draftCount
            var text = "\(results) result\(results == 1 ? "" : "s")"
            if drafts > 0 { text += " · \(drafts) draft\(drafts == 1 ? "" : "s")" }
            return text
        }
        return "Browses in your browser and reports back. You decide what to do."
    }

    // MARK: - Setup

    private var setupSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            readinessBanner
            recipeRow

            VStack(alignment: .leading, spacing: 6) {
                Text("WHAT SHOULD IT DO?")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.Palette.textSecondary)
                TextEditor(text: $goal)
                    .font(Theme.Font.bodySerif)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(height: 92)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.Palette.bgElevated))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.Palette.border, lineWidth: 0.75))
                Text(recipe?.goalPlaceholder.isEmpty == false
                     ? recipe!.goalPlaceholder
                     : "Plain English. The more specific the goal, the less the agent wanders.")
                    .font(Theme.Font.micro)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }

            DisclosureGroup(isExpanded: $showingOptions) {
                VStack(alignment: .leading, spacing: 12) {
                    labelledField("Start at", placeholder: "https://example.com", text: $startURL)
                    labelledField("Stay on", placeholder: "*.example.com, example.org", text: $allowedDomains)
                    Text(allowedDomains.trimmingCharacters(in: .whitespaces).isEmpty
                         ? "No domain fence: the agent may follow links anywhere. Fine for open research, worth narrowing for anything else."
                         : "The agent can't navigate outside these.")
                        .font(Theme.Font.micro)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 22) {
                        HStack(spacing: 6) {
                            Text("Results")
                                .font(Theme.Font.micro)
                                .foregroundStyle(Theme.Palette.textSecondary)
                            Stepper(value: $maxFindings, in: 1...25) {
                                Text("\(maxFindings)")
                                    .font(Theme.Font.mono)
                                    .foregroundStyle(Theme.Palette.textPrimary)
                            }
                            .fixedSize()
                        }
                        Toggle("Headless", isOn: $config.headless)
                            .toggleStyle(.switch)
                            .font(Theme.Font.caption)
                            .help("Off means you can watch the browser work — worth leaving off until you trust it.")
                        Spacer()
                    }

                    Toggle(isOn: $readOnly) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Read and draft only")
                                .font(Theme.Font.body)
                            Text("The agent can search, filter and read, but can't submit a form, post, send, or buy. Turn this off only for a task that genuinely needs to click through something.")
                                .font(Theme.Font.micro)
                                .foregroundStyle(Theme.Palette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.switch)
                }
                .padding(.top, 10)
            } label: {
                Text(showingOptions ? "Options" : "Options — \(optionsSummary)")
                    .font(Theme.Font.micro)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        }
    }

    private var optionsSummary: String {
        var parts: [String] = []
        let domains = allowedDomains.trimmingCharacters(in: .whitespaces)
        parts.append(domains.isEmpty ? "anywhere" : domains)
        parts.append(readOnly ? "read-only" : "can interact")
        parts.append("\(maxFindings) results")
        return parts.joined(separator: ", ")
    }

    private func labelledField(_ label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.Palette.textTertiary)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(Theme.Font.monoSmall)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.Palette.bgElevated))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.Palette.border, lineWidth: 0.75))
        }
    }

    // MARK: - Recipes

    private var recipeRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Picker("", selection: $recipeId) {
                    Text("No recipe — free-form").tag("")
                    ForEach(recipes.recipes) { r in
                        Text(r.name).tag(r.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 260)
                .onChange(of: recipeId) { _, newValue in applyRecipe(id: newValue) }

                Menu {
                    Button("New recipe…") { recipes.createTemplate(named: "New recipe") }
                    Button("Open recipes folder") { recipes.revealDirectory() }
                    Button("Reload") { recipes.reload() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 12, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Recipes are your own files — Claudette ships none")

                Spacer()
            }

            if let schedule = recipe?.schedule, schedule.isActive {
                scheduleLine(schedule)
            }
            ForEach(recipe?.scheduleProblems ?? [], id: \.self) { problem in
                Text(problem)
                    .font(Theme.Font.micro)
                    .foregroundStyle(Color(hex: 0x8A7B4E))
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(recipes.loadErrors, id: \.self) { error in
                Text("Couldn't read \(error)")
                    .font(Theme.Font.micro)
                    .foregroundStyle(DiffLine.removedRed)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func scheduleLine(_ schedule: TaskSchedule) -> some View {
        HStack(spacing: 6) {
            Image(systemName: scheduler.isEnabled ? "clock" : "clock.badge.xmark")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.Palette.textTertiary)
            Text(schedule.summary)
                .font(Theme.Font.micro)
                .foregroundStyle(Theme.Palette.textTertiary)
            if !scheduler.isEnabled {
                Text("· scheduling off")
                    .font(Theme.Font.micro)
                    .foregroundStyle(Color(hex: 0x8A7B4E))
                Button("Turn on") { scheduler.isEnabled = true }
                    .font(Theme.Font.micro)
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.Palette.accent)
            } else if let next = recipe.flatMap({ scheduler.nextRun(for: $0) }) {
                Text("· next \(Self.relative.localizedString(for: next, relativeTo: Date()))")
                    .font(Theme.Font.micro)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    /// Pull a recipe's defaults into the editable fields. The user can still
    /// override any of them for this one run without touching their file.
    private func applyRecipe(id: String) {
        recipeId = id
        config.lastRecipeId = id
        guard let r = recipes.recipe(id: id) else {
            startURL = ""
            allowedDomains = ""
            readOnly = true
            maxFindings = 8
            return
        }
        startURL = r.startURL
        allowedDomains = r.allowedDomains.joined(separator: ", ")
        readOnly = r.readOnly
        maxFindings = r.maxFindings
        if goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { goal = r.goal }
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
                    Button(runner.isInstalling ? "Installing…" : "Install browser-use") {
                        runner.installBrowserUse(config: config)
                    }
                    .font(Theme.Font.micro)
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
            // Newest first: during a long run the interesting line is the last
            // one, and this keeps it on top without fighting the scroll position.
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
                banner("The run stopped early: \(working.blockedReason)", tint: Color(hex: 0x8A7B4E))
            }

            ForEach($working.findings) { $finding in
                FindingCard(finding: $finding, draftLimits: runner.draftLimits)
            }

            if working.isEmpty {
                Text("The agent came back with nothing. Try a narrower goal, or check the log below.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        }
    }

    private func banner(_ message: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(tint)
            Text(message)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Metric.cornerMd).fill(tint.opacity(0.08)))
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
                Button("New task") {
                    hasResult = false
                    runner.clear()
                }
                Button("Copy all") { copyAll() }
                Button {
                    NotificationCenter.default.post(
                        name: .claudetteFillDraft,
                        object: nil,
                        userInfo: ["text": working.markdown()]
                    )
                    dismiss()
                } label: {
                    Label("Send to chat", systemImage: "arrow.turn.down.left")
                }
                .help("Drop the results into the chat box so Claude can work with them.")
            }
            Spacer()
            if runner.state.isBusy {
                Button("Stop") { runner.cancel() }
                    .keyboardShortcut(".", modifiers: [.command])
            } else {
                Button {
                    runner.run(spec: buildSpec(), config: config)
                } label: {
                    Label("Run", systemImage: "play.fill")
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

    private func buildSpec() -> BrowserTaskSpec {
        let domains = allowedDomains
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return BrowserTaskSpec(
            goal: goal,
            instructions: recipe?.instructions ?? "",
            startURL: startURL.trimmingCharacters(in: .whitespaces),
            allowedDomains: domains,
            maxFindings: maxFindings,
            readOnly: readOnly,
            drafts: (recipe?.drafts ?? []).map {
                BrowserTaskSpec.Slot(label: $0.label, limit: $0.limit, guidance: $0.guidance)
            }
        )
    }

    /// Take a fresh report from the runner without clobbering edits the user has
    /// already made to the one on screen.
    private func adoptReport(_ incoming: TaskReport?) {
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
