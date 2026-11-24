import SwiftUI
import SwiftData
import UIKit

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

            Section{
                NavigationLink(value: ProfileRoute.howToUse) {
                    Label("How to Use", systemImage: "questionmark.circle")
                }
                NavigationLink {
                    HelpFAQView()
                } label: {
                    Label("Help & FAQ", systemImage: "lifepreserver")
                }
                ExternalRow("Contact Us", systemImage: "envelope", url: AppLinks.contact)
                ExternalRow("Send Feedback", systemImage: "bubble.left", url: AppLinks.feedback)
            } header: {
                Text("Help")
            } footer: {
                Text("We read every message: \(AppLinks.email)")
                    .textSelection(.enabled)
            }

            Section("About") {
                ExternalRow("Privacy Policy", systemImage: "hand.raised", url: AppLinks.privacy)
                ExternalRow("Terms of Use", systemImage: "doc.text", url: AppLinks.terms)
                NavigationLink(value: ProfileRoute.dataSources) {
                    Label("Data Sources", systemImage: "books.vertical")
                }
                NavigationLink {
                    AboutView()
                } label: {
                    Label("About", systemImage: "info.circle")
                }
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

// MARK: - Links
// one place for every address the app opens, easy to change
enum AppLinks {
    // the same address we gave Apple as the TestFlight feedback email
    static let email = "alpha.cerbero@gmail.com"
    static let privacy = URL(string: "https://atymia.github.io/belloop-privacy/")!
    // no accounts and nothing to buy, so Apple's standard license is enough for now
    static let terms = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!

    static var contact: URL { mail(subject: "Belloop") }

    // the version and iOS go in the email, so we know which build they're talking about
    static var feedback: URL {
        let body = String(localized: "Tell us what happened, or what you'd change:")
            + "\n\n\n\n—\nBelloop \(appVersion) · iOS \(UIDevice.current.systemVersion)"
        return mail(subject: String(localized: "Belloop feedback"), body: body)
    }

    // "1.0 (2)" from the app's Info.plist
    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    private static func mail(subject: String, body: String? = nil) -> URL {
        var parts = URLComponents()
        parts.scheme = "mailto"
        parts.path = email
        parts.queryItems = [URLQueryItem(name: "subject", value: subject)]
        if let body { parts.queryItems?.append(URLQueryItem(name: "body", value: body)) }
        return parts.url ?? URL(string: "mailto:\(email)")!
    }
}

// a row that opens Mail or Safari, with the little arrow that says "this leaves the app"
struct ExternalRow: View {
    let title: LocalizedStringKey
    let systemImage: String
    let url: URL

    init(_ title: LocalizedStringKey, systemImage: String, url: URL) {
        self.title = title
        self.systemImage = systemImage
        self.url = url
    }

    var body: some View {
        Link(destination: url) {
            LabeledContent {
                Image(systemName: "arrow.up.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            } label: {
                // black text like the other rows, the icon keeps the app color
                Label {
                    Text(title).foregroundStyle(.primary)
                } icon: {
                    Image(systemName: systemImage)
                }
            }
        }
    }
}

// MARK: - Not done yet
// shows "Soon", still used for Sharing in the Profile (family sharing comes later)
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
             text: "Keep the camera on and turn the package: the date is read in the same scan. Check it and correct it if needed."),
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

// MARK: - Help & FAQ
struct HelpFAQView: View {
    private struct Question: Identifiable {
        let id: Int
        let question: LocalizedStringKey
        let answer: LocalizedStringKey
    }

    private let questions: [Question] = [
        Question(id: 1, question: "The scanner can't read the date",
                 answer: "Hold the phone still, with good light. If it can't focus, move a little farther away. You can turn on the flashlight in the scanner, and if the pack has more than one date, tap the right one. You can always type the date yourself."),
        Question(id: 2, question: "I can't find a product when I type its name",
                 answer: "Search uses Open Food Facts, a free database filled in by volunteers, so not every product is there yet and sometimes their server is slow. Scanning the barcode works best. If nothing comes up, just save the name as you typed it."),
        Question(id: 3, question: "When do the reminders arrive?",
                 answer: "At 9:00, a few days before the date. You choose how many in Settings, from 1 to 7. The day after the date, Belloop asks if you used the product."),
        Question(id: 4, question: "Where are my products saved?",
                 answer: "On your iPhone and, if you're signed in to iCloud, in your own iCloud, so they're the same on all your devices. Only you can see them, we can't."),
        Question(id: 5, question: "Does Belloop work without internet?",
                 answer: "Your pantry and the reminders do. Searching for products and finding recipes need a connection."),
        Question(id: 6, question: "Why do some recipes sound a bit odd?",
                 answer: "The recipes come from TheMealDB in English and are translated on your iPhone. Most of the time it's fine, but now and then a word comes out a bit literal."),
        Question(id: 7, question: "How do I remove a product?",
                 answer: "In Pantry, swipe left on it and tap Delete. If you finished it, you can also answer the question you get the day after its date."),
    ]

    var body: some View {
        List {
            Section {
                ForEach(questions) { item in
                    DisclosureGroup {
                        Text(item.answer)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                    } label: {
                        Text(item.question)
                    }
                }
            } footer: {
                Text("Still stuck? Write to us from Settings, under Contact Us.")
            }
        }
        .navigationTitle("Help & FAQ")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - About
struct AboutView: View {
    private let team = ["Francesco Esposito", "Shamima Islam", "Alina Siddiqui", "Smail Oujaoura", "Elbachir El alaoui"]

    var body: some View {
        List {
            Section {
                VStack(spacing: 6) {
                    Text(verbatim: "Belloop")
                        .font(.largeTitle.bold())
                    Text("Version \(AppLinks.appVersion)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }

            Section {
                Text("We made Belloop because we kept finding things at the back of the cupboard a day too late. Scan what you buy, and the app reminds you before it expires and helps you cook it.")
            }

            Section {
                ForEach(team, id: \.self) { name in
                    Text(verbatim: name)
                }
            } header: {
                Text("Made by High Five")
            } footer: {
                Text("Students at the Apple Developer Academy.")
            }
        }
        .navigationTitle("About")
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
