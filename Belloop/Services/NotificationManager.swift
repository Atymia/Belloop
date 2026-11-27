import SwiftData
import UserNotifications

// One notification a day at most, at 9am, however many products there are:
// - "soon": every morning from N days before the date (N from settings) to the day itself
// - "past": every morning after the date, until you answer (used it, threw it away,
//   still have it) or delete the product
// With one product the notification names it ("past" has the Used / Threw away / Still have it
// buttons), with more it stays generic and opens the app on Home.
// iOS keeps at most 64 waiting notifications, so we plan the next 30 days and rebuild them
// every time the pantry changes or the app opens.
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
    // how far ahead we plan. opening the app plans again, so this is plenty
    private static let daysAhead = 30

    private static func rebuild(_ products: [Product], _ settings: Settings) async {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()   // the app only has these, so start from zero
        guard settings.notificationsOn else { return }

        let cal = Calendar.current
        let now = Date()
        let today = cal.startOfDay(for: now)
        // the first 9am still to come: today, or tomorrow if it's already past 9
        let first = cal.component(.hour, from: now) < 9 ? 0 : 1

        var requests: [UNNotificationRequest] = []
        for offset in first..<(first + daysAhead) {
            guard let day = cal.date(byAdding: .day, value: offset, to: today) else { continue }
            var soon: [(Product, Int)] = []   // expires within the reminder days, with days left
            var past: [(Product, Int)] = []   // past its date and not answered yet, with days since
            for product in products {
                let expiry = cal.startOfDay(for: product.expiration)
                guard let left = cal.dateComponents([.day], from: day, to: expiry).day else { continue }
                if (0...settings.reminderDays).contains(left) {
                    soon.append((product, left))
                } else if left < 0, settings.askAfterExpiry, !product.reviewed {
                    past.append((product, -left))
                }
            }
            if let content = content(soon: soon, past: past),
               let request = request(id: "day-\(key(day))", content: content, on: day) {
                requests.append(request)
            }
        }

        // ask for permission only when there's really something to send
        guard !requests.isEmpty, await isAuthorized(center) else { return }

        // already in date order, the closest first in case there are more than iOS allows
        for request in requests.prefix(maxPending) {
            try? await center.add(request)
        }
    }

    // MARK: Texts
    // the one notification of the day, written for what's in it
    private static func content(soon: [(Product, Int)], past: [(Product, Int)]) -> UNMutableNotificationContent? {
        let content = UNMutableNotificationContent()
        switch (soon.count, past.count) {
        case (0, 0):
            return nil
        case (1, 0):
            let (product, days) = soon[0]
            switch days {
            case 0: content.title = String(localized: "\(product.name) expires today")
            case 1: content.title = String(localized: "\(product.name) expires tomorrow")
            default: content.title = String(localized: "\(product.name) expires in \(days) days")
            }
            content.body = String(localized: "There's still time to cook something with it.")
            content.userInfo = ["itemID": product.id]
        case (0, 1):
            let (product, days) = past[0]
            let date = product.expiration.formatted(.dateTime.day().month())
            content.title = String(localized: "Did you finish \(product.name)?")
            content.body = days == 1
                ? String(localized: "It passed its date yesterday.")
                : String(localized: "Its date was \(date).")
            content.userInfo = ["itemID": product.id]
            content.categoryIdentifier = expiredCategory   // Used it / Threw it away / Still have it
        case (_, 0):
            content.title = String(localized: "A few things expire soon")
            content.body = String(localized: "Have a look before they go to waste.")
        case (0, _):
            // a notification can't have buttons for each product: a tap opens Home ("Past their date")
            content.title = String(localized: "Some products passed their date")
            content.body = String(localized: "Did you use them, or did they end up in the bin?")
        default:
            content.title = String(localized: "Your pantry needs a look")
            content.body = String(localized: "Some things expire soon, and some are already past their date.")
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
