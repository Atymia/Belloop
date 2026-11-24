import SwiftUI
import SwiftData

// MARK: - Sorting
enum SortOption: CaseIterable, Identifiable {
    case expirationAsc, expirationDesc, nameAsc, nameDesc, addedNewest

    var id: Self { self }

    // translated in Localizable.xcstrings
    var title: LocalizedStringKey {
        switch self {
        case .expirationAsc:  "Expiration (soonest)"
        case .expirationDesc: "Expiration (latest)"
        case .nameAsc:        "Name (A–Z)"
        case .nameDesc:       "Name (Z–A)"
        case .addedNewest:    "Recently added"
        }
    }

    // used directly by @Query
    var descriptors: [SortDescriptor<FoodItem>] {
        switch self {
        case .expirationAsc:  [SortDescriptor(\.expirationDate)]
        case .expirationDesc: [SortDescriptor(\.expirationDate, order: .reverse)]
        case .nameAsc:        [SortDescriptor(\.name)]
        case .nameDesc:       [SortDescriptor(\.name, order: .reverse)]
        case .addedNewest:    [SortDescriptor(\.addedDate, order: .reverse)]
        }
    }
}

// MARK: - Status
enum ExpiryStatus {
    case urgent, soon, fresh

    // colors are in Assets (light/dark/high contrast).
    // I picked a palette that works for color blind people too
    var tint: Color {
        switch self {
        case .urgent: Color("StatusUrgent")
        case .soon:   Color("StatusSoon")
        case .fresh:  Color("StatusFresh")
        }
    }

    // each status has a different icon too, not only a color
    var symbol: String {
        switch self {
        case .urgent: "exclamationmark.triangle.fill"
        case .soon:   "clock.fill"
        case .fresh:  "checkmark.circle"
        }
    }
}

// MARK: - SwiftData model
// everything has a default and nothing is unique so we can add iCloud sync later
@Model
final class FoodItem {
    var uid: UUID = UUID()
    var name: String = ""
    var barcode: String?
    var expirationDate: Date = Date()
    var addedDate: Date = Date()
    // english keyword for recipes (calculated when needed)
    var recipeKeyword: String?
    // OFF categories, general to specific
    var categoryTags: [String] = []
    // which version made the keyword, if old it gets recalculated
    var recipeKeywordVersion: Int = 0
    // true if the user said "I still have it", so we stop asking
    var expiryReviewed: Bool = false
    @Attribute(.externalStorage) var imageData: Data?

    init(name: String, expirationDate: Date, barcode: String? = nil, imageData: Data? = nil) {
        self.name = name
        self.expirationDate = expirationDate
        self.barcode = barcode
        self.imageData = imageData
        self.addedDate = Date()
    }

    // days from settings (1-7)
    static var warningDays: Int { AppSettings.reminderDays }

    var daysLeft: Int {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let exp = cal.startOfDay(for: expirationDate)
        return cal.dateComponents([.day], from: today, to: exp).day ?? 0
    }

    // expired (from the day after)
    var isExpired: Bool { daysLeft < 0 }

    // from today to `days` days from now, expired ones not included
    // (Home's "Expiring soon" and its "See all" list)
    func expires(within days: Int) -> Bool { daysLeft >= 0 && daysLeft <= days }

    // what the recipes pick on their own: expiring soon, or expired yesterday at most.
    // people often still use something the day after, but after that we don't suggest it.
    // (you can still tick an older one by hand in "Choose products", e.g. dry pasta)
    func goodForRecipes(within days: Int) -> Bool {
        daysLeft >= -1 && daysLeft <= days
    }

    var status: ExpiryStatus {
        // if/else because 2...warningDays crashes when the setting is 1
        if daysLeft <= 1 { return .urgent }
        if daysLeft <= Self.warningDays { return .soon }
        return .fresh
    }

    var statusText: String {
        switch daysLeft {
        case ..<0:
            daysLeft == -1 ? String(localized: "Expired yesterday")
                           : String(localized: "Expired \(-daysLeft) days ago")
        case 0: String(localized: "Expires today!")
        case 1: String(localized: "Expires tomorrow")
        default: String(localized: "Expires in \(daysLeft) days")
        }
    }
}

extension ModelContext {
    // delete item + its notifications
    func remove(_ item: FoodItem) {
        NotificationManager.cancel(item)
        delete(item)
    }
}

// MARK: - "Did you use it?"
// same logic for Home and for the notification
@MainActor
enum ExpiryReview {
    enum Outcome { case used, thrownAway, kept }

    static func apply(_ outcome: Outcome, to item: FoodItem, in context: ModelContext) {
        switch outcome {
        case .used:
            increment(AppSettings.Key.usedCount)
            context.remove(item)
        case .thrownAway:
            increment(AppSettings.Key.thrownCount)
            context.remove(item)
        case .kept:
            item.expiryReviewed = true   // keep it and don't ask again
            NotificationManager.schedule(for: item)
        }
        try? context.save()
    }

    // from the notification buttons (app might be in background)
    static func handle(action: String, itemID: String) {
        let outcome: Outcome
        switch action {
        case NotificationManager.Action.used: outcome = .used
        case NotificationManager.Action.thrownAway: outcome = .thrownAway
        case NotificationManager.Action.keep: outcome = .kept
        default: return   // normal tap just opens the app on Home
        }
        guard let uid = UUID(uuidString: itemID) else { return }
        let context = AppModel.container.mainContext
        let descriptor = FetchDescriptor<FoodItem>(predicate: #Predicate { $0.uid == uid })
        guard let item = try? context.fetch(descriptor).first else { return }
        apply(outcome, to: item, in: context)
    }

    private static func increment(_ key: String) {
        UserDefaults.standard.set(UserDefaults.standard.integer(forKey: key) + 1, forKey: key)
    }
}
