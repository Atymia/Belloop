import UserNotifications

// 2 notifications per product, at 9am:
// - N days before (N from settings)
// - the day after it expires, asking "Did you use it?"
enum NotificationManager {
    enum Action {
        static let used = "EXPIRY_USED"
        static let thrownAway = "EXPIRY_THROWN_AWAY"
        static let keep = "EXPIRY_KEEP"
    }
    static let expiredCategory = "EXPIRED_CHECK"

    // buttons when you long press the notification
    static func registerCategories() {
        let used = UNNotificationAction(identifier: Action.used, title: String(localized: "Yes, I used it"), options: [])
        let thrown = UNNotificationAction(identifier: Action.thrownAway, title: String(localized: "No, I threw it away"), options: [.destructive])
        let keep = UNNotificationAction(identifier: Action.keep, title: String(localized: "I still have it"), options: [])
        let category = UNNotificationCategory(identifier: expiredCategory, actions: [used, thrown, keep], intentIdentifiers: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    // copy the values first, Swift 6 doesn't like passing the model into the Task
    static func schedule(for item: FoodItem) {
        let request = Snapshot(
            id: item.uid.uuidString,
            name: item.name,
            expiration: item.expirationDate,
            reviewed: item.expiryReviewed,
            reminderDays: AppSettings.reminderDays,
            notificationsOn: AppSettings.notificationsOn,
            askAfterExpiry: AppSettings.askAfterExpiry
        )
        Task { await schedule(request) }
    }

    // when the settings change
    static func rescheduleAll(_ items: [FoodItem]) {
        items.forEach(schedule(for:))
    }

    static func cancel(_ item: FoodItem) {
        let id = item.uid.uuidString
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [id, expiredID(id)])
    }

    // MARK: - Private
    private struct Snapshot: Sendable {
        let id: String
        let name: String
        let expiration: Date
        let reviewed: Bool
        let reminderDays: Int
        let notificationsOn: Bool
        let askAfterExpiry: Bool
    }

    private static func expiredID(_ id: String) -> String { id + ".expired" }

    private static func schedule(_ s: Snapshot) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [s.id, expiredID(s.id)])
        guard s.notificationsOn, await isAuthorized(center) else { return }

        // reminder
        let reminder = UNMutableNotificationContent()
        reminder.title = String(localized: "About to expire ⏰")
        reminder.body = s.reminderDays == 1
            ? String(localized: "\(s.name) expires tomorrow. Want a zero-waste recipe?")
            : String(localized: "\(s.name) expires in \(s.reminderDays) days. Want a zero-waste recipe?")
        reminder.sound = .default
        reminder.userInfo = ["itemID": s.id]
        await add(reminder, id: s.id, on: s.expiration, offsetDays: -s.reminderDays, center: center)

        // day after: did you use it?
        guard s.askAfterExpiry, !s.reviewed else { return }
        let check = UNMutableNotificationContent()
        check.title = String(localized: "Did you use \(s.name)?")
        check.body = String(localized: "It expired yesterday. Let us know, so your pantry stays up to date.")
        check.sound = .default
        check.userInfo = ["itemID": s.id]
        check.categoryIdentifier = expiredCategory
        await add(check, id: expiredID(s.id), on: s.expiration, offsetDays: 1, center: center)
    }

    // schedule at 9am on date + offsetDays, skip if it's already past
    private static func add(_ content: UNMutableNotificationContent, id: String, on date: Date,
                            offsetDays: Int, center: UNUserNotificationCenter) async {
        let cal = Calendar.current
        guard let day = cal.date(byAdding: .day, value: offsetDays, to: date) else { return }
        var comps = cal.dateComponents([.year, .month, .day], from: day)
        comps.hour = 9
        guard let fire = cal.date(from: comps), fire > Date() else { return }
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    // ask permission only the first time we need it
    private static func isAuthorized(_ center: UNUserNotificationCenter) async -> Bool {
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        case .authorized, .provisional, .ephemeral:
            return true
        default:
            return false
        }
    }
}
