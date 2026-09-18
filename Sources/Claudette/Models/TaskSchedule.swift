import Foundation

/// A time of day, in the user's local timezone.
struct TimeOfDay: Codable, Hashable, Comparable {
    var hour: Int
    var minute: Int

    static func < (a: TimeOfDay, b: TimeOfDay) -> Bool {
        (a.hour, a.minute) < (b.hour, b.minute)
    }

    var label: String { String(format: "%02d:%02d", hour, minute) }

    /// Named times, so a recipe can say "morning" the way a person would.
    /// These are conventions, not guesses about the user's day — they're
    /// documented, and anyone who wants 07:15 can just write 07:15.
    private static let named: [String: TimeOfDay] = [
        "morning": TimeOfDay(hour: 9, minute: 0),
        "midday": TimeOfDay(hour: 12, minute: 0),
        "noon": TimeOfDay(hour: 12, minute: 0),
        "afternoon": TimeOfDay(hour: 14, minute: 0),
        "evening": TimeOfDay(hour: 18, minute: 0),
        "night": TimeOfDay(hour: 21, minute: 0)
    ]

    /// Parse "08:30", "8:30", "8:30am", "8am", "0830", or a named time.
    /// Returns nil for anything it can't read, so a typo in a recipe is reported
    /// rather than silently scheduling something at midnight.
    static func parse(_ raw: String) -> TimeOfDay? {
        let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return nil }
        if let named = named[text] { return named }

        var body = text
        var meridiem: String?
        for suffix in ["am", "pm", "a.m.", "p.m."] where body.hasSuffix(suffix) {
            meridiem = suffix.hasPrefix("a") ? "am" : "pm"
            body = String(body.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            break
        }

        var hour: Int
        var minute = 0
        if body.contains(":") {
            let parts = body.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
            hour = h
            minute = m
        } else if body.count == 4, let value = Int(body) {
            hour = value / 100
            minute = value % 100
        } else if let value = Int(body) {
            hour = value
        } else {
            return nil
        }

        if let meridiem {
            guard (1...12).contains(hour) else { return nil }
            if meridiem == "pm" && hour != 12 { hour += 12 }
            if meridiem == "am" && hour == 12 { hour = 0 }
        }
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return TimeOfDay(hour: hour, minute: minute)
    }
}

/// When a recipe should run by itself.
///
/// Like everything else about a recipe, this is the user's to write — Claudette
/// ships no schedules and has no opinion about when anyone's work happens.
///
/// ```json
/// "schedule": { "days": ["tuesday", "thursday"], "at": "morning" }
/// ```
struct TaskSchedule: Codable, Hashable {
    var enabled: Bool = true
    /// `Calendar` weekday numbers (1 = Sunday). Empty means every day.
    var weekdays: Set<Int> = []
    var times: [TimeOfDay] = []
    /// When Claudette wasn't running at the scheduled moment, run as soon as it
    /// next starts. Off by default: waking up to yesterday's run firing at
    /// breakfast is rarely what anyone wants.
    var catchUpIfMissed: Bool = false

    enum CodingKeys: String, CodingKey {
        case enabled, days, at, catchUpIfMissed
    }

    /// Problems found while decoding, surfaced in the UI rather than thrown —
    /// one unreadable time shouldn't cost the user the whole recipe.
    var warnings: [String] = []

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        catchUpIfMissed = try c.decodeIfPresent(Bool.self, forKey: .catchUpIfMissed) ?? false

        let dayTokens = try Self.stringList(c, .days)
        var days = Set<Int>()
        for token in dayTokens {
            if let group = Self.dayGroups[token] {
                days.formUnion(group)
            } else if let day = Self.dayNames[token] {
                days.insert(day)
            } else {
                warnings.append("Didn't understand the day \"\(token)\".")
            }
        }
        weekdays = days

        let timeTokens = try Self.stringList(c, .at)
        var parsed: [TimeOfDay] = []
        for token in timeTokens {
            if let time = TimeOfDay.parse(token) {
                parsed.append(time)
            } else {
                warnings.append("Didn't understand the time \"\(token)\".")
            }
        }
        times = parsed.sorted()
        if times.isEmpty {
            warnings.append("No usable time — add \"at\": \"09:00\" to schedule this recipe.")
        }
    }

    init(enabled: Bool = true, weekdays: Set<Int> = [], times: [TimeOfDay] = [], catchUpIfMissed: Bool = false) {
        self.enabled = enabled
        self.weekdays = weekdays
        self.times = times
        self.catchUpIfMissed = catchUpIfMissed
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(weekdays.sorted().compactMap { Self.dayLabels[$0] }, forKey: .days)
        try c.encode(times.map(\.label), forKey: .at)
        try c.encode(catchUpIfMissed, forKey: .catchUpIfMissed)
    }

    /// Accepts either `"at": "09:00"` or `"at": ["09:00", "17:00"]`.
    private static func stringList(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) throws -> [String] {
        if let list = try? container.decodeIfPresent([String].self, forKey: key) {
            return list.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        }
        if let single = try? container.decodeIfPresent(String.self, forKey: key) {
            let trimmed = single.trimmingCharacters(in: .whitespaces).lowercased()
            return trimmed.isEmpty ? [] : [trimmed]
        }
        return []
    }

    private static let dayNames: [String: Int] = [
        "sunday": 1, "sun": 1,
        "monday": 2, "mon": 2,
        "tuesday": 3, "tue": 3, "tues": 3,
        "wednesday": 4, "wed": 4, "weds": 4,
        "thursday": 5, "thu": 5, "thur": 5, "thurs": 5,
        "friday": 6, "fri": 6,
        "saturday": 7, "sat": 7
    ]

    private static let dayGroups: [String: Set<Int>] = [
        "daily": [1, 2, 3, 4, 5, 6, 7],
        "every day": [1, 2, 3, 4, 5, 6, 7],
        "everyday": [1, 2, 3, 4, 5, 6, 7],
        "weekdays": [2, 3, 4, 5, 6],
        "weekends": [1, 7]
    ]

    private static let dayLabels: [Int: String] = [
        1: "sunday", 2: "monday", 3: "tuesday", 4: "wednesday",
        5: "thursday", 6: "friday", 7: "saturday"
    ]

    private static let shortLabels: [Int: String] = [
        1: "Sun", 2: "Mon", 3: "Tue", 4: "Wed", 5: "Thu", 6: "Fri", 7: "Sat"
    ]

    /// Runnable at all — enabled, with at least one time the parser understood.
    var isActive: Bool { enabled && !times.isEmpty }

    /// Which weekdays this actually fires on. An empty `weekdays` means daily.
    var effectiveWeekdays: Set<Int> {
        weekdays.isEmpty ? [1, 2, 3, 4, 5, 6, 7] : weekdays
    }

    /// "Tue, Thu at 09:00" — the line shown in the panel and in Settings.
    var summary: String {
        guard !times.isEmpty else { return "No valid time set" }
        let timeText = times.map(\.label).joined(separator: ", ")
        let days = effectiveWeekdays
        let dayText: String
        if days.count == 7 {
            dayText = "Every day"
        } else if days == [2, 3, 4, 5, 6] {
            dayText = "Weekdays"
        } else if days == [1, 7] {
            dayText = "Weekends"
        } else {
            dayText = days.sorted().compactMap { Self.shortLabels[$0] }.joined(separator: ", ")
        }
        return "\(dayText) at \(timeText)"
    }

    /// The most recent moment this schedule should have fired at or before
    /// `date`, or nil if it has no valid times. Used to decide whether a run is
    /// owed: if the last run predates this, one is.
    func mostRecentOccurrence(onOrBefore date: Date, calendar: Calendar = .current) -> Date? {
        guard isActive else { return nil }
        // Walk back at most a week — beyond that there's nothing to catch up on.
        for dayOffset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: -dayOffset, to: date) else { continue }
            let weekday = calendar.component(.weekday, from: day)
            guard effectiveWeekdays.contains(weekday) else { continue }
            let startOfDay = calendar.startOfDay(for: day)
            // Latest time on this day that isn't in the future.
            for time in times.sorted().reversed() {
                guard let candidate = calendar.date(
                    bySettingHour: time.hour, minute: time.minute, second: 0, of: startOfDay
                ) else { continue }
                if candidate <= date { return candidate }
            }
        }
        return nil
    }

    /// The next moment this schedule fires after `date`, for the "next run" line.
    func nextOccurrence(after date: Date, calendar: Calendar = .current) -> Date? {
        guard isActive else { return nil }
        for dayOffset in 0...8 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: date) else { continue }
            let weekday = calendar.component(.weekday, from: day)
            guard effectiveWeekdays.contains(weekday) else { continue }
            let startOfDay = calendar.startOfDay(for: day)
            for time in times.sorted() {
                guard let candidate = calendar.date(
                    bySettingHour: time.hour, minute: time.minute, second: 0, of: startOfDay
                ) else { continue }
                if candidate > date { return candidate }
            }
        }
        return nil
    }
}
