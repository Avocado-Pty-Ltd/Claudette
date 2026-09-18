import Foundation
import Combine
import AppKit
import UserNotifications

/// Runs recipes at the times their own files ask for.
///
/// Claudette is a desktop app, not a daemon: a schedule fires while Claudette is
/// running. A recipe that sets `catchUpIfMissed` gets its run as soon as the app
/// next opens; otherwise a missed slot is simply missed. The UI says so rather
/// than implying a cron job.
@MainActor
final class TaskScheduler: ObservableObject {
    /// Master switch. Off means no recipe runs by itself, whatever its file says.
    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled { tick() }
        }
    }
    /// Recipe id currently running (or queued behind a manual run), for the UI.
    @Published private(set) var activeRecipeId: String?
    /// Short log of what fired and when, newest first. In-memory: the durable
    /// record is the Markdown written to disk for each run.
    @Published private(set) var history: [Entry] = []

    struct Entry: Identifiable, Equatable {
        let id = UUID()
        var recipeName: String
        var firedAt: Date
        var outcome: String
        var fileURL: URL?
    }

    private static let enabledKey = "browserAgent.schedulingEnabled"
    private static let lastRunKey = "browserAgent.lastScheduledRuns"
    /// How late a run may start and still count. Beyond this, a slot is missed
    /// unless the recipe opted into catch-up.
    private static let graceWindow: TimeInterval = 30 * 60
    private static let tickInterval: TimeInterval = 30

    private let recipes: RecipeStore
    private let runner: BrowserTaskRunner
    private let config: BrowserAgentConfig

    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()
    /// Slots that came due while something else was running, drained when idle.
    private var pending: [(recipeId: String, occurrence: Date)] = []
    /// The slot the in-flight run belongs to, so we can file the result.
    private var inFlight: (recipeId: String, occurrence: Date)?

    /// recipe id → the occurrence we last ran for it.
    private var lastRuns: [String: Date] {
        didSet {
            let encoded = lastRuns.mapValues { $0.timeIntervalSince1970 }
            UserDefaults.standard.set(encoded, forKey: Self.lastRunKey)
        }
    }

    init(recipes: RecipeStore, runner: BrowserTaskRunner, config: BrowserAgentConfig) {
        self.recipes = recipes
        self.runner = runner
        self.config = config
        self.isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        let stored = UserDefaults.standard.dictionary(forKey: Self.lastRunKey) as? [String: Double] ?? [:]
        self.lastRuns = stored.mapValues { Date(timeIntervalSince1970: $0) }
    }

    /// Start ticking. Safe to call more than once.
    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // .common so the timer keeps firing while a menu or a sheet has the runloop.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        // File each scheduled run's result the moment it lands.
        runner.$report
            .compactMap { $0 }
            .sink { [weak self] report in self?.finishRun(with: report) }
            .store(in: &cancellables)
        runner.$state
            .sink { [weak self] state in self?.stateChanged(state) }
            .store(in: &cancellables)

        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Next scheduled fire across all recipes, for the Settings summary.
    func nextRun() -> (recipe: BrowserRecipe, date: Date)? {
        let now = Date()
        return recipes.recipes
            .filter(\.isSchedulable)
            .compactMap { recipe in
                recipe.schedule?.nextOccurrence(after: now).map { (recipe, $0) }
            }
            .min { $0.1 < $1.1 }
    }

    func nextRun(for recipe: BrowserRecipe) -> Date? {
        guard recipe.isSchedulable else { return nil }
        return recipe.schedule?.nextOccurrence(after: Date())
    }

    // MARK: - The loop

    private func tick() {
        guard isEnabled else { return }
        let now = Date()

        for recipe in recipes.recipes where recipe.isSchedulable {
            guard let schedule = recipe.schedule,
                  let occurrence = schedule.mostRecentOccurrence(onOrBefore: now)
            else { continue }

            // A recipe Claudette has never seen starts from its *next* slot.
            // Without this, adding a recipe on Wednesday that's scheduled for
            // Tuesdays would fire immediately — catch-up is for slots missed
            // while the app was closed, not for history.
            guard let last = lastRuns[recipe.id] else {
                lastRuns[recipe.id] = occurrence
                continue
            }
            // Already ran this slot?
            if last >= occurrence { continue }
            // Too late, and the recipe didn't ask to catch up.
            if !schedule.catchUpIfMissed && now.timeIntervalSince(occurrence) > Self.graceWindow {
                // Mark it consumed so it doesn't re-evaluate every 30 seconds for
                // the rest of the week.
                lastRuns[recipe.id] = occurrence
                continue
            }
            if pending.contains(where: { $0.recipeId == recipe.id }) { continue }
            if inFlight?.recipeId == recipe.id { continue }
            pending.append((recipe.id, occurrence))
        }

        drain()
    }

    /// Start the next queued run if the browser is free. One agent, one browser —
    /// two runs at once would fight over the same profile.
    private func drain() {
        guard !runner.state.isBusy, inFlight == nil, !pending.isEmpty else { return }
        let slot = pending.removeFirst()
        guard let recipe = recipes.recipe(id: slot.recipeId), recipe.isSchedulable else { return }
        guard config.hasCredentials else {
            record(recipe: recipe, outcome: "Skipped — no API key for \(config.provider.label).", file: nil)
            lastRuns[recipe.id] = slot.occurrence
            return
        }

        inFlight = slot
        activeRecipeId = recipe.id
        lastRuns[recipe.id] = slot.occurrence
        runner.run(spec: recipe.taskSpec(goal: recipe.goal), config: config)
    }

    private func stateChanged(_ state: BrowserRunState) {
        guard inFlight != nil else {
            // A manual run just finished — a queued schedule can go now.
            if !state.isBusy { drain() }
            return
        }
        switch state {
        case .failed, .cancelled:
            let name = inFlight.map { recipes.recipe(id: $0.recipeId)?.name ?? $0.recipeId } ?? "Task"
            record(
                recipe: nil,
                name: name,
                outcome: state == .cancelled ? "Cancelled." : (runner.lastError ?? "Failed."),
                file: nil
            )
            inFlight = nil
            activeRecipeId = nil
            drain()
        case .idle, .running, .finished:
            // `.finished` is handled in finishRun, which also has the report.
            break
        }
    }

    private func finishRun(with report: TaskReport) {
        guard let slot = inFlight else { return }
        let recipe = recipes.recipe(id: slot.recipeId)
        let name = recipe?.name ?? slot.recipeId
        let url = writeTranscript(name: name, report: report, firedAt: slot.occurrence)

        let count = report.findings.count
        record(
            recipe: recipe,
            name: name,
            outcome: count == 0 ? "Ran, found nothing." : "\(count) result\(count == 1 ? "" : "s").",
            file: url
        )
        notify(title: "\(name) finished", body: count == 0
            ? "No results this time."
            : "\(count) result\(count == 1 ? "" : "s") ready to review.")

        inFlight = nil
        activeRecipeId = nil
        drain()
    }

    // MARK: - Output

    /// `~/Library/Application Support/Claudette/browser-runs`
    nonisolated static var transcriptDirectory: URL {
        BrowserAgentConfig.supportDir.appendingPathComponent("browser-runs", isDirectory: true)
    }

    /// A scheduled run happens while nobody's watching, so its result goes to
    /// disk as Markdown — the panel only holds the most recent one in memory.
    private func writeTranscript(name: String, report: TaskReport, firedAt: Date) -> URL? {
        let fm = FileManager.default
        let dir = Self.transcriptDirectory
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd-HHmm"
        let slug = name
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let url = dir.appendingPathComponent("\(slug.isEmpty ? "run" : slug)-\(stamp.string(from: firedAt)).md")

        let header = "_Scheduled run · \(DateFormatter.localizedString(from: firedAt, dateStyle: .full, timeStyle: .short))_\n\n"
        do {
            try (header + report.markdown()).write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    private func record(recipe: BrowserRecipe?, name: String? = nil, outcome: String, file: URL?) {
        let entry = Entry(
            recipeName: name ?? recipe?.name ?? "Task",
            firedAt: Date(),
            outcome: outcome,
            fileURL: file
        )
        history.insert(entry, at: 0)
        if history.count > 20 { history.removeLast(history.count - 20) }
    }

    /// Best-effort local notification. A run that finished at 09:00 is no use if
    /// nobody knows it happened — but a denied permission is not an error worth
    /// bothering anyone about.
    private func notify(title: String, body: String) {
        // UNUserNotificationCenter traps in a process with no bundle identifier,
        // which is exactly what `swift run` against the source tree gives you.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            center.add(request, withCompletionHandler: nil)
        }
    }
}

extension BrowserRecipe {
    /// Turn this recipe plus a goal into the spec the sidecar runs.
    func taskSpec(goal: String) -> BrowserTaskSpec {
        BrowserTaskSpec(
            goal: goal,
            instructions: instructions,
            startURL: startURL,
            allowedDomains: allowedDomains,
            maxFindings: maxFindings,
            readOnly: readOnly,
            drafts: drafts.map {
                BrowserTaskSpec.Slot(label: $0.label, limit: $0.limit, guidance: $0.guidance)
            }
        )
    }
}
