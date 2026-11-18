import SwiftUI

// MARK: - Settings (UserDefaults)
// all the keys in one place so I don't misspell them.
// views use @AppStorage, the rest of the code uses the static vars below
nonisolated enum AppSettings {
    enum Key {
        static let reminderDays = "settings.reminderDays"
        static let notificationsOn = "settings.notificationsOn"
        static let askAfterExpiry = "settings.askAfterExpiry"
        static let country = "settings.country"

        static let profileName = "profile.name"
        static let profileUsername = "profile.username"
        static let profileIcon = "profile.icon"
        static let avatarVersion = "profile.avatarVersion"   // changes when the photo changes so the avatar refreshes

        static let accountProvider = "account.provider"   // empty = not signed in
        static let accountEmail = "account.email"
        static let appleUserID = "account.appleUserID"

        static let usedCount = "stats.used"   // for a future stats screen
        static let thrownCount = "stats.thrown"
    }

    static let defaultReminderDays = 3

    // how many days before (1-7), used by the notification and the Home list
    static var reminderDays: Int {
        let value = UserDefaults.standard.integer(forKey: Key.reminderDays)
        return value == 0 ? defaultReminderDays : min(max(value, 1), 7)
    }

    static var notificationsOn: Bool { UserDefaults.standard.object(forKey: Key.notificationsOn) as? Bool ?? true }
    static var askAfterExpiry: Bool { UserDefaults.standard.object(forKey: Key.askAfterExpiry) as? Bool ?? true }

    // country from the profile, otherwise the phone region
    static var countryCode: String {
        if let saved = UserDefaults.standard.string(forKey: Key.country), !saved.isEmpty { return saved }
        return defaultCountry
    }
    static var defaultCountry: String { Locale.current.region?.identifier ?? "US" }
}

// MARK: - Countries
enum Countries {
    // country codes sorted by name
    static let all: [String] = Locale.Region.isoRegions
        .map(\.identifier)
        .filter { $0.count == 2 && $0.allSatisfy(\.isLetter) }
        .sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }

    static func name(_ code: String) -> String {
        Locale.current.localizedString(forRegionCode: code) ?? code
    }

    // turns "IT" into the flag emoji
    static func flag(_ code: String) -> String {
        code.uppercased().unicodeScalars
            .compactMap { UnicodeScalar(127_397 + $0.value) }
            .map(String.init)
            .joined()
    }
}

// MARK: - Avatar photo (saved as a jpg file)
enum AvatarStore {
    private static var url: URL {
        URL.applicationSupportDirectory.appending(path: "avatar.jpg")
    }

    static func load() -> UIImage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    static func save(_ image: UIImage) {
        guard let data = image.downscaledJPEG(maxDimension: 600, quality: 0.8) else { return }
        try? FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        bumpVersion()
    }

    static func remove() {
        try? FileManager.default.removeItem(at: url)
        bumpVersion()
    }

    private static func bumpVersion() {
        let key = AppSettings.Key.avatarVersion
        UserDefaults.standard.set(UserDefaults.standard.integer(forKey: key) + 1, forKey: key)
    }
}

// MARK: - Accounts
// the views only know this protocol. for now it's a fake local login,
// later we can add Firebase or something else without touching the views
protocol AuthService: Sendable {
    func signUp(name: String, email: String, password: String) async throws
    func signIn(email: String, password: String) async throws
    func signInWithApple(userID: String, email: String?, name: String?) async throws
    func signOut() async
    func deleteAccount() async throws
}

// not called Auth because Firebase already uses that name
enum Accounts {
    static let service: any AuthService = LocalDemoAuthService()
}

// TODO: demo only! it just saves the email, no password check.
// replace before release
struct LocalDemoAuthService: AuthService {
    private var defaults: UserDefaults { .standard }

    func signUp(name: String, email: String, password: String) async throws {
        if defaults.string(forKey: AppSettings.Key.profileName)?.isEmpty ?? true {
            defaults.set(name, forKey: AppSettings.Key.profileName)
        }
        finish(provider: "email", email: email)
    }

    func signIn(email: String, password: String) async throws {
        finish(provider: "email", email: email)
    }

    func signInWithApple(userID: String, email: String?, name: String?) async throws {
        defaults.set(userID, forKey: AppSettings.Key.appleUserID)
        // apple gives name/email only the first time, so don't overwrite them
        if let name, !name.isEmpty, defaults.string(forKey: AppSettings.Key.profileName)?.isEmpty ?? true {
            defaults.set(name, forKey: AppSettings.Key.profileName)
        }
        finish(provider: "apple", email: email ?? defaults.string(forKey: AppSettings.Key.accountEmail) ?? "")
    }

    func signOut() async {
        defaults.set("", forKey: AppSettings.Key.accountProvider)
        defaults.set("", forKey: AppSettings.Key.accountEmail)
    }

    func deleteAccount() async throws {
        await signOut()
        defaults.removeObject(forKey: AppSettings.Key.appleUserID)
        defaults.removeObject(forKey: AppSettings.Key.profileName)
        defaults.removeObject(forKey: AppSettings.Key.profileUsername)
        defaults.removeObject(forKey: AppSettings.Key.profileIcon)
        AvatarStore.remove()
    }

    private func finish(provider: String, email: String) {
        defaults.set(email, forKey: AppSettings.Key.accountEmail)
        defaults.set(provider, forKey: AppSettings.Key.accountProvider)
    }
}
