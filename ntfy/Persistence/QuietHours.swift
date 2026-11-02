import Foundation

/// One atomic preferences value shared with the NSE. No database, timer or shared file lock.
struct QuietHours: Equatable {
    static let key = "quietHours.v1"
    static var defaults: UserDefaults { UserDefaults(suiteName: Config.appGroupId)! }
    var enabled = false
    var start = 22 * 60
    var end = 7 * 60
    var days = Array(1...7)
    var allowUrgent = true
    var exceptions: [String] = []

    static func load(from defaults: UserDefaults = QuietHours.defaults) -> QuietHours {
        defaults.synchronize()
        guard let value = defaults.dictionary(forKey: key) else { return QuietHours() }
        var result = QuietHours()
        result.enabled = value["enabled"] as? Bool ?? false
        result.start = value["start"] as? Int ?? result.start
        result.end = value["end"] as? Int ?? result.end
        result.days = value["days"] as? [Int] ?? result.days
        result.allowUrgent = value["allowUrgent"] as? Bool ?? true
        result.exceptions = value["exceptions"] as? [String] ?? []
        return result
    }
    func save(to defaults: UserDefaults = QuietHours.defaults) {
        defaults.set(["enabled": enabled, "start": start, "end": end, "days": days,
                      "allowUrgent": allowUrgent, "exceptions": exceptions], forKey: Self.key)
        defaults.synchronize()
    }
    func contains(_ now: Date, calendar: Calendar = .autoupdatingCurrent) -> Bool {
        guard enabled, (0..<1440).contains(start), (0..<1440).contains(end) else { return false }
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: now)
        let minute = parts.hour! * 60 + parts.minute!
        let weekday = parts.weekday!
        if start == end { return days.contains(weekday) }
        if start < end { return days.contains(weekday) && minute >= start && minute < end }
        // Days name the evening the window starts, including across a DST change or week end.
        let startDay = minute < end ? (weekday + 5) % 7 + 1 : weekday
        return days.contains(startDay) && (minute >= start || minute < end)
    }
    func isQuiet(baseUrl: String, topic: String, priority: Int?, now: Date = Date()) -> Bool {
        contains(now) && !(allowUrgent && priority == 5)
            && !exceptions.contains(topicUrl(baseUrl: normalizeBaseUrl(baseUrl), topic: topic))
    }
    func isQuiet(userInfo: [AnyHashable: Any], now: Date = Date()) -> Bool {
        let priority = (userInfo["priority"] as? Int) ?? Int(userInfo["priority"] as? String ?? "")
        return isQuiet(baseUrl: userInfo["base_url"] as? String ?? Config.appBaseUrl,
                       topic: userInfo["topic"] as? String ?? "", priority: priority, now: now)
    }
}
