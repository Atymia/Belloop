import SwiftUI
import SwiftData
import UserNotifications

@main
struct FoodSaverApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        // same container for the app and the notification buttons
        .modelContainer(AppModel.container)
    }
}

@MainActor
enum AppModel {
    static let container: ModelContainer = {
        do {
            return try ModelContainer(for: FoodItem.self)
        } catch {
            fatalError("Could not open the SwiftData store: \(error)")
        }
    }()
}

// handles the "Did you use it?" notification
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        NotificationManager.registerCategories()
        return true
    }

    // show the notification even if the app is open
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    // user tapped a button or the notification itself
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        guard let itemID = response.notification.request.content.userInfo["itemID"] as? String else { return }
        await ExpiryReview.handle(action: action, itemID: itemID)
    }
}
