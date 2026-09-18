import Foundation

/// A saved browser-task template: where to start, which domains to stay on, what
/// the user's rules are for this kind of task, and what to draft.
///
/// **Recipes are user data, not app content.** Claudette ships none, and none
/// belong in this repository — a recipe is where one person's workflow rules for
/// one website live, and those are nobody else's business. They're read from
/// `~/Library/Application Support/Claudette/browser-recipes/*.json` at runtime,
/// so a user can keep theirs in a private repo, a dotfiles checkout, or a synced
/// folder without any of it touching Claudette.
struct BrowserRecipe: Identifiable, Codable, Hashable {
    /// Derived from the filename, so two recipes can share a display name.
    var id: String = ""
    var name: String = ""
    /// SF Symbol shown in the picker. Falls back to a generic globe.
    var icon: String = ""
    /// Placeholder text for the goal field — a nudge about what to type.
    var goalPlaceholder: String = ""
    /// Prefilled goal, for a task the user runs verbatim every time.
    var goal: String = ""
    var startURL: String = ""
    /// Glob patterns the agent is fenced to, e.g. `["*.example.com"]`. Empty
    /// means no fence, which is worth warning about in the UI.
    var allowedDomains: [String] = []
    /// The user's own rules, injected into the agent's brief verbatim. Anything
    /// site-specific goes here.
    var instructions: String = ""
    var drafts: [DraftSlot] = []
    /// Read-only runs can't submit, post, send or buy. Default on.
    var readOnly: Bool = true
    var maxFindings: Int = 8
    /// When this recipe should run by itself. Nil means "only when I ask".
    var schedule: TaskSchedule?

    struct DraftSlot: Identifiable, Codable, Hashable {
        var id = UUID()
        var label: String = ""
        /// Character cap for this draft, when the destination has one.
        var limit: Int?
        var guidance: String = ""

        enum CodingKeys: String, CodingKey {
            case label, limit, guidance
        }
    }

    enum CodingKeys: String, CodingKey {
        case name, icon, goalPlaceholder, goal, startURL, allowedDomains
        case instructions, drafts, readOnly, maxFindings, schedule
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? ""
        goalPlaceholder = try c.decodeIfPresent(String.self, forKey: .goalPlaceholder) ?? ""
        goal = try c.decodeIfPresent(String.self, forKey: .goal) ?? ""
        startURL = try c.decodeIfPresent(String.self, forKey: .startURL) ?? ""
        allowedDomains = try c.decodeIfPresent([String].self, forKey: .allowedDomains) ?? []
        instructions = try c.decodeIfPresent(String.self, forKey: .instructions) ?? ""
        drafts = try c.decodeIfPresent([DraftSlot].self, forKey: .drafts) ?? []
        readOnly = try c.decodeIfPresent(Bool.self, forKey: .readOnly) ?? true
        maxFindings = try c.decodeIfPresent(Int.self, forKey: .maxFindings) ?? 8
        schedule = try c.decodeIfPresent(TaskSchedule.self, forKey: .schedule)
    }

    /// A scheduled recipe needs a goal it can run without anyone typing one.
    /// Surfaced as a warning rather than dropped, so the user can see why their
    /// Tuesday run never happened.
    var scheduleProblems: [String] {
        guard let schedule else { return [] }
        var problems = schedule.warnings
        if schedule.isActive && goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            problems.append("Scheduled recipes need a \"goal\" in the file — there's nobody at the keyboard to type one.")
        }
        return problems
    }

    /// Runnable unattended: has a valid schedule and a goal baked in.
    var isSchedulable: Bool {
        guard let schedule, schedule.isActive else { return false }
        return !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(id: String = "", name: String = "") {
        self.id = id
        self.name = name
    }

    var symbolName: String { icon.isEmpty ? "globe" : icon }

    /// Character cap the UI should count against for a draft carrying `label`.
    func limit(forDraftLabel label: String) -> Int? {
        drafts.first { $0.label.caseInsensitiveCompare(label) == .orderedSame }?.limit
    }

    /// The commented template written by "New recipe…", so the first thing a user
    /// sees is the shape of the format rather than a blank file. Intentionally
    /// generic — a starting point, not somebody's workflow.
    static func templateJSON(name: String) -> String {
        """
        {
          "name": "\(name)",
          "icon": "globe",
          "goalPlaceholder": "What are you looking for?",
          "startURL": "https://example.com",
          "allowedDomains": ["*.example.com"],
          "readOnly": true,
          "maxFindings": 8,
          "goal": "",
          "schedule": {
            "enabled": false,
            "days": ["tuesday", "thursday"],
            "at": "morning",
            "catchUpIfMissed": false
          },
          "instructions": "Your rules for this kind of task, in plain English. Which pages are worth opening, what counts as a good result, what to ignore. This text is handed to the agent verbatim.",
          "_comment": "Set schedule.enabled to true and fill in \"goal\" to have Claudette run this by itself. Times are local; \"morning\" is 09:00.",
          "drafts": [
            {
              "label": "Reply",
              "limit": 500,
              "guidance": "What this draft should do and how it should read."
            }
          ]
        }
        """
    }
}
