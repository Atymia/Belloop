import SwiftUI
import SwiftData

struct PantryView: View {
    var onAdd: () -> Void
    var onChoose: () -> Void

    @State private var searchText = ""
    @State private var selectedSort: SortOption = .expirationAsc

    var body: some View {
        NavigationStack {
            PantryList(searchText: searchText, sort: selectedSort)
                .navigationTitle("Pantry")
                .searchable(text: $searchText, prompt: "Search products...")
                .navigationDestination(for: FoodItem.self) { ItemDetailView(item: $0) }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Picker("Sort by", selection: $selectedSort) {
                                ForEach(SortOption.allCases) { Text($0.title).tag($0) }
                            }
                        } label: {
                            Label("Sort", systemImage: "arrow.up.arrow.down")
                        }
                    }
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button("Recipes", systemImage: "fork.knife", action: onChoose)
                        Button("Add", systemImage: "plus", action: onAdd)
                    }
                }
        }
    }
}

// filter and sort are done by @Query
private struct PantryList: View {
    @Environment(\.modelContext) private var context
    @Query private var items: [FoodItem]
    let searchText: String

    init(searchText: String, sort: SortOption) {
        self.searchText = searchText
        let predicate = #Predicate<FoodItem> {
            searchText.isEmpty || $0.name.localizedStandardContains(searchText)
        }
        _items = Query(filter: predicate, sort: sort.descriptors)
    }

    var body: some View {
        List {
            ForEach(items) { item in
                NavigationLink(value: item) { ItemRow(item: item) }
            }
            .onDelete { offsets in
                offsets.map { items[$0] }.forEach { context.remove($0) }
            }
        }
        .overlay {
            if items.isEmpty {
                if searchText.isEmpty {
                    ContentUnavailableView("Pantry is empty", systemImage: "refrigerator",
                                           description: Text("Tap + to add your first product."))
                } else {
                    ContentUnavailableView.search(text: searchText)
                }
            }
        }
    }
}
