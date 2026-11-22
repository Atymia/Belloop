import SwiftUI
import SwiftData

// MARK: - Settings
struct SettingsView: View {
    @Query private var items: [FoodItem]

    @AppStorage(AppSettings.Key.notificationsOn) private var notificationsOn = true
    @AppStorage(AppSettings.Key.askAfterExpiry) private var askAfterExpiry = true
    @AppStorage(AppSettings.Key.reminderDays) private var reminderDays = AppSettings.defaultReminderDays

    private var reminderText: String {
        reminderDays == 1 ? String(localized: "1 day before") : String(localized: "\(reminderDays) days before")
    }

    // Slider needs a Double, the setting is an Int
    private var daysBinding: Binding<Double> {
        Binding(get: { Double(reminderDays) }, set: { reminderDays = Int($0.rounded()) })
    }

    var body: some View {
        Form {
            // no Theme and no Language here: the app follows the iPhone
            // (dark mode from Control Center, language from the iPhone Settings)
            Section {
                Toggle("Notifications", isOn: $notificationsOn)
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Expiry reminder", value: reminderText)
                    Slider(value: daysBinding, in: 1...7, step: 1) {
                        Text("Expiry reminder")
                    } minimumValueLabel: {
                        Text(verbatim: "1")
                    } maximumValueLabel: {
                        Text(verbatim: "7")
                    }
                    .accessibilityValue(reminderText)
                }
                Toggle("Ask after the date", isOn: $askAfterExpiry)
                    .disabled(!notificationsOn)
            } header: {
                Text("Notifications")
            } footer: {
                Text("You'll get one reminder at 9:00 for everything that's about to expire, and a question the day after something passes its date.")
            }

            Section("Help") {
                NavigationLink(value: ProfileRoute.howToUse) {
                    Label("How to Use", systemImage: "questionmark.circle")
                }
                PlaceholderRow("Help & FAQ", systemImage: "lifepreserver")
                PlaceholderRow("Contact Us", systemImage: "envelope")
                PlaceholderRow("Send Feedback", systemImage: "bubble.left")
            }

            Section("About") {
                PlaceholderRow("Privacy Policy", systemImage: "hand.raised")
                PlaceholderRow("Terms of Service", systemImage: "doc.text")
                NavigationLink(value: ProfileRoute.dataSources) {
                    Label("Data Sources", systemImage: "books.vertical")
                }
                PlaceholderRow("About", systemImage: "info.circle")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        // reschedule all notifications when something changes
        .onChange(of: reminderDays) { NotificationManager.rescheduleAll(items) }
        .onChange(of: notificationsOn) { NotificationManager.rescheduleAll(items) }
        .onChange(of: askAfterExpiry) { NotificationManager.rescheduleAll(items) }
    }
}

// MARK: - Not done yet
// shows "Soon", TODO: make these real NavigationLinks
struct PlaceholderRow: View {
    let title: LocalizedStringKey
    let systemImage: String

    init(_ title: LocalizedStringKey, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        LabeledContent {
            Text("Soon").foregroundStyle(.secondary)
        } label: {
            Label(title, systemImage: systemImage)
        }
    }
}

// MARK: - How to Use
struct HowToUseView: View {
    private struct Step: Identifiable {
        let id: Int
        let symbol: String
        let title: LocalizedStringKey
        let text: LocalizedStringKey
    }

    private let steps: [Step] = [
        Step(id: 1, symbol: "barcode.viewfinder", title: "1. Scan the barcode",
             text: "Name and photo are filled in from Open Food Facts. No barcode? Type the name."),
        Step(id: 2, symbol: "calendar.badge.clock", title: "2. Scan the expiration date",
             text: "Frame the date printed on the package, then check it and correct it if needed."),
        Step(id: 3, symbol: "refrigerator", title: "3. Save it",
             text: "The product goes into your Pantry, sorted by expiration date."),
        Step(id: 4, symbol: "bell.badge", title: "4. Get reminded",
             text: "Before the date you get a reminder, and the product shows up on Home under Expiring soon. The day after, you'll be asked if you used it."),
        Step(id: 5, symbol: "fork.knife", title: "5. Cook it",
             text: "Recipe ideas finds real recipes that use what's about to expire. Pull the list down for new ones, or pick products from your Pantry."),
    ]

    var body: some View {
        List {
            Section {
                ForEach(steps) { step in
                    HStack(alignment: .top, spacing: 16) {
                        Image(systemName: step.symbol)
                            .font(.title2)
                            .foregroundStyle(.tint)
                            .frame(width: 36)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(step.title).font(.headline)
                            Text(step.text).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("Five steps to waste less food.")
            }
        }
        .navigationTitle("How to Use")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Data sources (OFF license wants credits)
struct DataSourcesView: View {
    var body: some View {
        List {
            Section {
                Text("Product names and photos come from Open Food Facts, a free and collaborative food database. The data is available under the Open Database License; photos are under Creative Commons Attribution-ShareAlike.")
                Link(destination: URL(string: "https://world.openfoodfacts.org")!) {
                    Label("openfoodfacts.org", systemImage: "safari")
                }
            } header: {
                Text("Products")
            }

            Section {
                Text("Recipes come from TheMealDB and are translated on your iPhone.")
                Link(destination: URL(string: "https://www.themealdb.com")!) {
                    Label("themealdb.com", systemImage: "safari")
                }
            } header: {
                Text("Recipes")
            }
        }
        .navigationTitle("Data Sources")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Recipe type labels
extension RecipeType {
    // sweet and savory
    static let choices: [RecipeType] = [.savory, .sweet]

    var title: LocalizedStringKey {
        switch self {
        case .all: "All"
        case .savory: "Savory"
        case .sweet: "Sweet"
        }
    }

    var symbol: String {
        switch self {
        case .all: "fork.knife"
        case .savory: "frying.pan"
        case .sweet: "birthday.cake"
        }
    }
}
