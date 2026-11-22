import SwiftUI
import SwiftData
import CoreData
import Combine

enum AppTab: Hashable { case home, pantry }

// only one sheet open at a time, changing the case swaps what's inside
enum ActiveSheet: Identifiable {
    case add
    case picker
    case recipes([FoodItem])
    case profile

    var id: String {
        switch self {
        case .add: "add"
        case .picker: "picker"
        case .recipes: "recipes"
        case .profile: "profile"
        }
    }
}

// MARK: - Tabs
struct ContentView: View {
    @State private var selectedTab: AppTab = .home
    @State private var activeSheet: ActiveSheet?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Home", systemImage: "house", value: AppTab.home) {
                HomeView(
                    onAdd: { activeSheet = .add },
                    onRecipes: { activeSheet = .recipes($0) },
                    onChoose: { activeSheet = .picker },
                    onProfile: { activeSheet = .profile }
                )
            }
            Tab("Pantry", systemImage: "refrigerator", value: AppTab.pantry) {
                PantryView(
                    onAdd: { activeSheet = .add },
                    onChoose: { activeSheet = .picker }
                )
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .add:
                AddItemView()
            case .picker:
                IngredientPickerSheet { chosen in activeSheet = .recipes(chosen) }
            case .recipes(let items):
                RecipeSheet(items: items)
            case .profile:
                ProfileView()
            }
        }
        // every time the app is opened, rebuild the notifications from what's in the pantry
        .onChange(of: scenePhase, initial: true) {
            if scenePhase == .active { NotificationManager.refresh() }
        }
        // a change arrived from iCloud (another device added or removed something)
        .onReceive(NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange)
                    .receive(on: DispatchQueue.main)) { _ in
            NotificationManager.refresh()
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: FoodItem.self, inMemory: true)
}
