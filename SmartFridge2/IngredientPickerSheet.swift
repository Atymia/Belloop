import SwiftUI
import SwiftData

// choose any products from the pantry for the recipes
struct IngredientPickerSheet: View {
    @Query(sort: \FoodItem.expirationDate) private var items: [FoodItem]
    @Environment(\.dismiss) private var dismiss

    var onSearch: ([FoodItem]) -> Void

    @State private var selection = Set<FoodItem.ID>()
    @State private var didPreselect = false

    var body: some View {
        NavigationStack {
            List(selection: $selection) {
                Section {
                    ForEach(items) { ItemRow(item: $0) }
                } header: {
                    Text("Products about to expire are pre-selected. Up to 8 are used, soonest expiring first.")
                }
            }
            .environment(\.editMode, .constant(.active))   // always show the circles
            .navigationTitle("Choose products")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Find recipes") {
                        onSearch(items.filter { selection.contains($0.id) })
                    }
                    .disabled(selection.isEmpty)
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Expiring soon") { selectExpiring() }
                    Spacer()
                    Button("Clear") { selection.removeAll() }
                }
            }
            .onAppear {
                guard !didPreselect else { return }
                didPreselect = true
                selectExpiring()
            }
        }
    }

    private func selectExpiring() {
        selection = Set(items.filter(\.isExpiringSoon).map(\.id))
    }
}
