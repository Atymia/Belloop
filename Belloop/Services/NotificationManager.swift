import SwiftData
import UserNotifications

// Two kinds of notification, each at 9am, separate so each says one thing:
// - "soon": every morning from N days before the date (N from settings) to the day itself.
//   one product: its name; more: "A few things expire soon". A tap opens the product, or the list.
// - "past": ONCE, the morning after the date. one product: "Did you finish …?" with
//   Used it / Threw it away / Still have it on the notification itself; more: a generic one
//   that opens the review. Apple's HIG says not to repeat a notification for the same thing
//   when people haven't answered, so after that the app icon badge keeps the count
//   (like Reminders with overdue ones) and the product stays under "Past their date".
//   "Still have it" sets it aside for the day: it's back under "Past their date" tomorrow.
// iOS keeps at most 64 waiting notifications, so we plan the next 30 days and rebuild them
// every time the pantry changes or the app opens.
enum NotificationManager {
    enum Action {
        static let used = "EXPIRY_USED"
        static let thrownAway = "EXPIRY_THROWN_AWAY"
        static let keep = "EXPIRY_KEEP"
    }
    static let expiredCategory = "EXPIRED_CHECK"

    // which notification it is, so a tap opens the right screen
    enum Kind {
        static let soon = "soon"
        static let past = "past"
    }

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
                let (products, settings) = snapshot()
                await rebuild(products, settings)
            }
        }
    }

    // the same, right away: a button on the notification was tapped with the app closed,
    // and iOS gives us only a moment before it goes back to sleep
    @MainActor static func refreshNow() async {
        pending?.cancel()
        let (products, settings) = snapshot()
        await rebuild(products, settings)
    }

    // MARK: - Private
    @MainActor private static var pending: Task<Void, Never>?

    @MainActor private static func snapshot() -> ([Product], Settings) {
        let items = (try? AppModel.container.mainContext.fetch(FetchDescriptor<FoodItem>())) ?? []
        let products = items.filter { !$0.isDeleted }.map {
            Product(id: $0.uid.uuidString, name: $0.name, expiration: $0.expirationDate, keptOn: $0.keptOn)
        }
        let settings = Settings(reminderDays: AppSettings.reminderDays,
                                notificationsOn: AppSettings.notificationsOn,
                                askAfterExpiry: AppSettings.askAfterExpiry)
        return (products, settings)
    }

    // plain copies of the data, Swift 6 doesn't like passing the models into async code
    private struct Product: Sendable {
        let id: String
        let name: String
        let expiration: Date
        let keptOn: Date?
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
        guard settings.notificationsOn else {
            try? await center.setBadgeCount(0)
            return
        }

        let cal = Calendar.current
        let now = Date()
        let today = cal.startOfDay(for: now)
        // the first 9am still to come: today, or tomorrow if it's already past 9
        let first = cal.component(.hour, from: now) < 9 ? 0 : 1

        // the number on the app icon = what's under "Past their date" on Home
        let badgeNow = settings.askAfterExpiry ? waiting(products, on: today, cal) : 0
        var badge = badgeNow

        var requests: [UNNotificationRequest] = []
        for offset in first..<(first + daysAhead) {
            guard let day = cal.date(byAdding: .day, value: offset, to: today) else { continue }
            var soon: [(Product, Int)] = []        // expires within the reminder days, with days left
            var expiredYesterday: [Product] = []   // asked about once, this morning
            for product in products {
                let expiry = cal.startOfDay(for: product.expiration)
                guard let left = cal.dateComponents([.day], from: day, to: expiry).day else { continue }
                if (0...settings.reminderDays).contains(left) {
                    soon.append((product, left))
                } else if left == -1, !answered(product, cal) {
                    expiredYesterday.append(product)
                }
            }
            let id = key(day)

            if let content = soonContent(soon),
               let request = request(id: "soon-\(id)", content: content, on: day) {
                requests.append(request)
            }

            guard settings.askAfterExpiry else { continue }
            let count = waiting(products, on: day, cal)
            if let content = pastContent(expiredYesterday) {
                content.badge = NSNumber(value: count)
                if let request = request(id: "past-\(id)", content: content, on: day) { requests.append(request) }
            } else if count != badge {
                // nothing to say, only the number on the icon changes ("Still have it" is back)
                let content = UNMutableNotificationContent()
                content.badge = NSNumber(value: count)
                if let request = request(id: "badge-\(id)", content: content, on: day) { requests.append(request) }
            }
            badge = count
        }

        // ask for permission only when there's really something to send or count
        guard !requests.isEmpty || badgeNow > 0 else {
            try? await center.setBadgeCount(0)
            return
        }
        guard await isAuthorized(center) else { return }
        try? await center.setBadgeCount(badgeNow)

        // already in date order, the closest first in case there are more than iOS allows
        for request in requests.prefix(maxPending) {
            try? await center.add(request)
        }
    }

    // how many products are under "Past their date" on that day
    // (expired, and not set aside that same day with "Still have it")
    private static func waiting(_ products: [Product], on day: Date, _ cal: Calendar) -> Int {
        products.filter { product in
            guard cal.startOfDay(for: product.expiration) < day else { return false }
            guard let keptOn = product.keptOn else { return true }
            return !cal.isDate(keptOn, inSameDayAs: day)
        }.count
    }

    // already answered with "Still have it" after its date (opened the app before 9, say)
    private static func answered(_ product: Product, _ cal: Calendar) -> Bool {
        guard let keptOn = product.keptOn else { return false }
        return cal.startOfDay(for: keptOn) > cal.startOfDay(for: product.expiration)
    }

    // MARK: Texts
    // expiring soon: the product's name if there's only one
    private static func soonContent(_ soon: [(Product, Int)]) -> UNMutableNotificationContent? {
        guard !soon.isEmpty else { return nil }
        let content = UNMutableNotificationContent()
        if soon.count == 1 {
            let (product, days) = soon[0]
            switch days {
            case 0: content.title = String(localized: "\(product.name) expires today")
            case 1: content.title = String(localized: "\(product.name) expires tomorrow")
            default: content.title = String(localized: "\(product.name) expires in \(days) days")
            }
            content.body = String(localized: "There's still time to cook something with it.")
            content.userInfo = ["kind": Kind.soon, "itemID": product.id]
        } else {
            content.title = String(localized: "A few things expire soon")
            content.body = String(localized: "Have a look before they go to waste.")
            content.userInfo = ["kind": Kind.soon]
        }
        content.threadIdentifier = Kind.soon
        content.sound = .default
        return content
    }

    // past their date, asked once: with one product you can answer on the notification
    private static func pastContent(_ expired: [Product]) -> UNMutableNotificationContent? {
        guard !expired.isEmpty else { return nil }
        let content = UNMutableNotificationContent()
        if expired.count == 1 {
            let product = expired[0]
            content.title = String(localized: "Did you finish \(product.name)?")
            content.body = String(localized: "It passed its date yesterday.")
            content.userInfo = ["kind": Kind.past, "itemID": product.id]
            content.categoryIdentifier = expiredCategory   // Used it / Threw it away / Still have it
        } else {
            // a notification can't have buttons for each product: a tap opens the review
            content.title = String(localized: "Some products passed their date")
            content.body = String(localized: "Did you use them, or did they end up in the bin?")
            content.userInfo = ["kind": Kind.past]
        }
        content.threadIdentifier = Kind.past
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
