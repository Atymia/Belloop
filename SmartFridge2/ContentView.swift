import SwiftUI
import SwiftData

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
    @AppStorage(AppSettings.Key.appearance) private var appearance = Appearance.system.rawValue

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
        // theme from settings. set on the window so it also works on sheets already open
        .onChange(of: appearance, initial: true) {
            (Appearance(rawValue: appearance) ?? .system).applyToWindows()
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: FoodItem.self, inMemory: true)
}
