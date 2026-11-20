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
