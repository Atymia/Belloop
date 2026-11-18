import SwiftData
import UserNotifications

// Few notifications: at most one per type per day, at 9am.
// - "expiring": everything whose reminder falls on that day (N days before, N from settings)
// - "expired": everything that passed its date the day before
// With one product the notification names it (and "expired" has Used / Threw away buttons),
// with more it stays generic and opens the app.
enum NotificationManager {
    enum Action {
        static let used = "EXPIRY_USED"
        static let thrownAway = "EXPIRY_THROWN_AWAY"
        static let keep = "EXPIRY_KEEP"
    }
    static let expiredCategory = "EXPIRED_CHECK"

    // buttons when you long press the notification (only for a single product)
    static func registerCategories() {
        let used = UNNotificationAction(identifier: Action.used, title: String(localized: "Used it"), options: [])
        let thrown = UNNotificationAction(identifier: Action.thrownAway, title: String(localized: "Threw it away"), options: [.destructive])
        let keep = UNNotificationAction(identifier: Action.keep, title: String(localized: "Still have it"), options: [])
        let category = UNNotificationCategory(identifier: expiredCategory, actions: [used, thrown, keep], intentIdentifiers: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    // The notifications depend on the whole pantry, so every change rebuilds all of them.
    // These three stay so the rest of the app doesn't need to change.
    static func schedule(for item: FoodItem) { refresh() }
    static func rescheduleAll(_ items: [FoodItem]) { refresh() }
    static func cancel(_ item: FoodItem) { refresh() }

    // waits a moment so several changes in a row (or a delete that isn't saved yet) count once
    static func refresh() {
        Task { @MainActor in
            pending?.cancel()
            pending = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                let items = (try? AppModel.container.mainContext.fetch(FetchDescriptor<FoodItem>())) ?? []
                let products = items.filter { !$0.isDeleted }.map {
                    Product(id: $0.uid.uuidString, name: $0.name, expiration: $0.expirationDate, reviewed: $0.expiryReviewed)
                }
                let settings = Settings(reminderDays: AppSettings.reminderDays,
                                        notificationsOn: AppSettings.notificationsOn,
                                        askAfterExpiry: AppSettings.askAfterExpiry)
                await rebuild(products, settings)
            }
        }
    }

    // MARK: - Private
    @MainActor private static var pending: Task<Void, Never>?

    // plain copies of the data, Swift 6 doesn't like passing the models into async code
    private struct Product: Sendable {
        let id: String
        let name: String
        let expiration: Date
        let reviewed: Bool
    }

    private struct Settings: Sendable {
        let reminderDays: Int
        let notificationsOn: Bool
        let askAfterExpiry: Bool
    }

    // iOS keeps max 64 waiting notifications per app, stay below it
    private static let maxPending = 60

    private static func rebuild(_ products: [Product], _ settings: Settings) async {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()   // the app only has these, so start from zero
        guard settings.notificationsOn else { return }

        // group the products by the day their notification goes out
        let cal = Calendar.current
        var expiring: [Date: [Product]] = [:]
        var expired: [Date: [Product]] = [:]
        for product in products {
            let day = cal.startOfDay(for: product.expiration)
            if let reminderDay = cal.date(byAdding: .day, value: -settings.reminderDays, to: day) {
                expiring[reminderDay, default: []].append(product)
            }
            if settings.askAfterExpiry, !product.reviewed, let dayAfter = cal.date(byAdding: .day, value: 1, to: day) {
                expired[dayAfter, default: []].append(product)
            }
        }

        var requests: [(Date, UNNotificationRequest)] = []
        for (day, list) in expiring {
            if let request = request(id: "expiring-\(key(day))", content: expiringContent(list, days: settings.reminderDays), on: day) {
                requests.append((day, request))
            }
        }
        for (day, list) in expired {
            if let request = request(id: "expired-\(key(day))", content: expiredContent(list), on: day) {
                requests.append((day, request))
            }
        }

        // ask for permission only when there's really something to send
        guard !requests.isEmpty, await isAuthorized(center) else { return }

        // the closest ones first, in case there are more than iOS allows
        for (_, request) in requests.sorted(by: { $0.0 < $1.0 }).prefix(maxPending) {
            try? await center.add(request)
        }
    }

    // MARK: Texts
    private static func expiringContent(_ list: [Product], days: Int) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        if list.count == 1, let product = list.first {
            content.title = days == 1
                ? String(localized: "\(product.name) expires tomorrow")
                : String(localized: "\(product.name) expires in \(days) days")
            content.body = String(localized: "There's still time to cook something with it.")
            content.userInfo = ["itemID": product.id]
        } else {
            content.title = String(localized: "A few things expire soon")
            content.body = String(localized: "Have a look before they go to waste.")
        }
        content.sound = .default
        return content
    }

    private static func expiredContent(_ list: [Product]) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        if list.count == 1, let product = list.first {
            content.title = String(localized: "Did you finish \(product.name)?")
            content.body = String(localized: "It passed its date yesterday.")
            content.userInfo = ["itemID": product.id]
            content.categoryIdentifier = expiredCategory   // Used it / Threw it away / Still have it
        } else {
            // a notification can't have buttons for each product: a tap opens Home ("Did you use these?")
            content.title = String(localized: "Some products passed their date")
            content.body = String(localized: "Did you use them, or did they end up in the bin?")
        }
        content.sound = .default
        return content
    }

    // MARK: Helpers
    // 9am on that day, nil if it's already past
    private static func request(id: String, content: UNMutableNotificationContent, on day: Date) -> UNNotificationRequest? {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: day)
        comps.hour = 9
        guard let fire = cal.date(from: comps), fire > Date() else { return nil }
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        return UNNotificationRequest(identifier: id, content: content, trigger: trigger)
    }

    private static func key(_ day: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: day)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
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
