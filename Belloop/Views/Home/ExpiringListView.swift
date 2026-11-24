import SwiftUI
import SwiftData

// MARK: - "See all" from Home
// the full list of products expiring soon. Home only shows the first 3
struct ExpiringListView: View {
    @Query(sort: \FoodItem.expirationDate) private var items: [FoodItem]
    @AppStorage(AppSettings.Key.reminderDays) private var reminderDays = AppSettings.defaultReminderDays

    private var expiring: [FoodItem] { items.filter { $0.expires(within: reminderDays) } }

    var body: some View {
        // tapping a product uses the Route destination that Home already has
        List(expiring) { item in
            NavigationLink(value: Route.item(item.persistentModelID)) { ItemRow(item: item, dateOnly: true) }
        }
        .navigationTitle("Expiring soon")
        // if you remove the last one from here, don't leave an empty list
        .overlay {
            if expiring.isEmpty {
                ContentUnavailableView("All fresh!", systemImage: ExpiryStatus.fresh.symbol)
            }
        }
    }
}
