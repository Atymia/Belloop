import SwiftUI
import SwiftData
import UserNotifications

@main
struct BelloopApp: App {
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
    // the CloudKit container (Signing & Capabilities → iCloud)
    static let cloudContainerID = "iCloud.com.fraxexp.belloop"

    static let container: ModelContainer = {
        // the pantry goes in the user's private iCloud database:
        // only they can see it and it's the same on all their devices.
        // without an iCloud account it still works, just on this iPhone
        let cloud = ModelConfiguration(cloudKitDatabase: .private(cloudContainerID))
        do {
            return try ModelContainer(for: FoodItem.self, configurations: cloud)
        } catch {
            // if iCloud can't be set up, don't crash: same store, local only
            print("iCloud store not available, using local only: \(error)")
            do {
                return try ModelContainer(for: FoodItem.self,
                                          configurations: ModelConfiguration(cloudKitDatabase: .none))
            } catch {
                fatalError("Could not open the SwiftData store: \(error)")
            }
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
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    // user tapped a button or the notification itself.
    // the crash on 28 Nov (TestFlight build 9, two testers): with the `async` version of this
    // method, Swift ran it on a background thread and then told iOS "done" from there too.
    // iOS wants that "done" on the main thread, so it stopped the app
    // (UIApplication _performBlockAfterCATransactionCommitSynchronizes). this version is called
    // on the main thread, does the work on the main actor and calls completionHandler there
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        // only plain strings cross over, not the response itself
        let action = response.actionIdentifier
        let info = response.notification.request.content.userInfo
        let itemID = info["itemID"] as? String
        let kind = info["kind"] as? String
        Task { @MainActor in
            if action == UNNotificationDefaultActionIdentifier {
                // a tap on the notification: open what it's about (Apple's HIG: people expect
                // to land on the related content, not just in the app)
                NotificationRouter.shared.open(kind: kind, itemID: itemID)
            } else if let itemID {
                // one of the buttons: answer without opening the app, then fix the badge
                // and the next notifications before iOS puts the app back to sleep
                ExpiryReview.handle(action: action, itemID: itemID)
                await NotificationManager.refreshNow()
            }
            completionHandler()
        }
    }
}

// where a tapped notification takes you. AppDelegate sets it, ContentView goes there
// (also when the tap launched the app and ContentView shows up a moment later)
@MainActor @Observable
final class NotificationRouter {
    static let shared = NotificationRouter()

    enum Destination: Equatable {
        case product(UUID)   // one product expiring soon: its page
        case expiringList    // several expiring soon: the See all list
        case review(UUID?)   // past their date: "Did you use these?", on that product if it's one
    }

    var destination: Destination?

    func open(kind: String?, itemID: String?) {
        let id = itemID.flatMap(UUID.init(uuidString:))
        switch kind ?? "" {
        case NotificationManager.Kind.soon: destination = id.map(Destination.product) ?? .expiringList
        case NotificationManager.Kind.past: destination = .review(id)
        default: destination = nil   // a notification from an older version: the app just opens
        }
    }
}
