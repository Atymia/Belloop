import SwiftUI
import SwiftData
import CoreData
import Combine

enum AppTab: Hashable { case home, pantry }

// only one sheet open at a time, changing the case swaps what's inside
enum ActiveSheet: Identifiable {
    case add(scanning: Bool)   // scanning: the camera opens right away (Home's scan button)
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

    // each tab keeps its own screens: switching tabs and coming back you find
    // them where you left them (that's how tab bars work on iOS)
    @State private var homePath: [Route] = []
    @State private var pantryPath: [Route] = []

    // only to notice when a product is deleted (Pantry, iCloud, the review sheet)
    @Query private var items: [FoodItem]

    // tapping the tab you're already on brings it back to its first screen
    private var tabSelection: Binding<AppTab> {
        Binding(get: { selectedTab }, set: { tab in
            if tab == selectedTab { popToRoot(tab) }
            selectedTab = tab
        })
    }

    var body: some View {
        TabView(selection: tabSelection) {
            Tab("Home", systemImage: "house", value: AppTab.home) {
                HomeView(
                    path: $homePath,
                    onAdd: { activeSheet = .add(scanning: true) },
                    onRecipes: { activeSheet = .recipes($0) },
                    onChoose: { activeSheet = .picker },
                    onProfile: { activeSheet = .profile }
                )
            }
            Tab("Pantry", systemImage: "refrigerator", value: AppTab.pantry) {
                PantryView(
                    path: $pantryPath,
                    onAdd: { activeSheet = .add(scanning: false) },
                    onChoose: { activeSheet = .picker }
                )
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .add(let scanning):
                AddItemView(startScanning: scanning)
            case .picker:
                IngredientPickerSheet { chosen in activeSheet = .recipes(chosen) }
            case .recipes(let items):
                RecipeSheet(items: items)
            case .profile:
                ProfileView()
            }
        }
        // a product that was open in a tab got deleted somewhere else:
        // close its screen quietly, otherwise you'd come back to a product that doesn't exist
        .onChange(of: items.count) {
            let alive = Set(items.map(\.persistentModelID))
            homePath.removeAll { !$0.isAlive(in: alive) }
            pantryPath.removeAll { !$0.isAlive(in: alive) }
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

    private func popToRoot(_ tab: AppTab) {
        switch tab {
        case .home: homePath.removeAll()
        case .pantry: pantryPath.removeAll()
        }
    }
}

// MARK: - Navigation
// everything a tab can open. Home and Pantry share it, so ContentView can fix both paths.
// products travel as their id and not as the object: if one gets deleted
// we can still compare ids without touching a deleted object (that crashes)
enum Route: Hashable {
    case item(PersistentIdentifier)
    case allExpiring

    func isAlive(in alive: Set<PersistentIdentifier>) -> Bool {
        if case .item(let id) = self { return alive.contains(id) }
        return true
    }

    @ViewBuilder
    var destination: some View {
        switch self {
        case .item(let id): ItemDestination(id: id)
        case .allExpiring: ExpiringListView()
        }
    }
}

extension Binding where Value == [Route] {
    // a quick double tap on a product pushed it twice, so Back showed the same
    // product again and it felt like a loop. the same screen twice in a row is kept once
    var withoutRepeats: Binding<[Route]> {
        Binding(get: { wrappedValue }, set: { newPath in
            var clean: [Route] = []
            for route in newPath where clean.last != route { clean.append(route) }
            wrappedValue = clean
        })
    }
}

// finds the product from its id. if it's gone, it shows a short message
// for the split second before ContentView closes the screen
struct ItemDestination: View {
    @Query private var match: [FoodItem]

    init(id: PersistentIdentifier) {
        _match = Query(filter: #Predicate<FoodItem> { $0.persistentModelID == id })
    }

    var body: some View {
        if let item = match.first {
            ItemDetailView(item: item)
        } else {
            ContentUnavailableView("Product removed", systemImage: "trash")
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: FoodItem.self, inMemory: true)
}
