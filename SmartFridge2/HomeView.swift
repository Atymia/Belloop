import SwiftUI
import SwiftData

// Home order (from my mentor's feedback):
// 1. scan button, the main action
// 2. expired products + products about to expire
// 3. recipes
struct HomeView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \FoodItem.expirationDate) private var items: [FoodItem]
    // read here so the list updates when the setting changes
    @AppStorage(AppSettings.Key.reminderDays) private var reminderDays = AppSettings.defaultReminderDays
    @ScaledMetric(relativeTo: .largeTitle) private var scanIconSize: CGFloat = 40

    var onAdd: () -> Void
    var onRecipes: ([FoodItem]) -> Void
    var onChoose: () -> Void
    var onProfile: () -> Void

    @State private var reviewing: FoodItem?

    // expired and not answered yet
    private var pastDate: [FoodItem] { items.filter { $0.isExpired && !$0.expiryReviewed } }
    // from today to reminderDays
    private var expiring: [FoodItem] { items.filter { $0.daysLeft >= 0 && $0.daysLeft <= reminderDays } }
    // recipes use all the urgent stuff, expired ones included
    private var forRecipes: [FoodItem] { items.filter { $0.daysLeft <= reminderDays } }

    private var recipeCardText: LocalizedStringKey {
        // e.g. "Milk and Eggs are about to expire."
        let names = forRecipes.map(\.name)
        switch names.count {
        case 0: break
        case 1: return "\(names[0]) is about to expire. What shall we cook with it?"
        case 2: return "\(names[0]) and \(names[1]) are about to expire. What shall we cook with them?"
        default: return "\(names[0]), \(names[1]) and \(names.count - 2) more are about to expire. What shall we cook with them?"
        }
        if !items.isEmpty { return "Nothing is about to expire, but you can pick products from your pantry." }
        return "Add some products to get recipe ideas."
    }

    private var freshText: LocalizedStringKey {
        reminderDays == 1 ? "Nothing expires today or tomorrow." : "Nothing expires in the next \(reminderDays) days."
    }

    var body: some View {
        NavigationStack {
            List {
                // scan
                Section {
                    scanButton
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }

                // expired: ask what happened
                if !pastDate.isEmpty {
                    Section {
                        ForEach(pastDate) { item in
                            Button { reviewing = item } label: {
                                ItemRow(item: item).foregroundStyle(.primary)
                            }
                            .swipeActions(edge: .trailing) {
                                Button("Thrown away", systemImage: "trash", role: .destructive) {
                                    ExpiryReview.apply(.thrownAway, to: item, in: context)
                                }
                                Button("Used", systemImage: "checkmark") {
                                    ExpiryReview.apply(.used, to: item, in: context)
                                }
                                .tint(Color("StatusFresh"))
                            }
                        }
                    } header: {
                        Text("Did you use these?")
                    } footer: {
                        Text("These products are past their date. Tap one to update your pantry.")
                    }
                }

                // expiring soon
                Section("Expiring soon") {
                    if expiring.isEmpty {
                        allFreshRow
                    } else {
                        ForEach(expiring) { item in
                            NavigationLink(value: item) { ItemRow(item: item, dateOnly: true) }
                        }
                    }
                }

                // recipes
                Section { recipeCard }
            }
            .navigationTitle("Home")
            .navigationDestination(for: FoodItem.self) { ItemDetailView(item: $0) }
            .toolbar {
                // avatar button like in the App Store
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onProfile) { AvatarView(size: 36) }
                        .accessibilityLabel("Account")
                }
                .sharedBackgroundVisibility(.hidden)
            }
            .confirmationDialog(
                Text("Did you use \(reviewing?.name ?? "")?"),
                isPresented: Binding(get: { reviewing != nil }, set: { if !$0 { reviewing = nil } }),
                titleVisibility: .visible,
                presenting: reviewing
            ) { item in
                Button("Yes, I used it") { ExpiryReview.apply(.used, to: item, in: context) }
                Button("No, I threw it away", role: .destructive) { ExpiryReview.apply(.thrownAway, to: item, in: context) }
                Button("I still have it") { ExpiryReview.apply(.kept, to: item, in: context) }
            } message: { _ in
                Text("Products you used or threw away are removed from your pantry.")
            }
        }
    }

    // MARK: - Subviews
    // big scan button
    private var scanButton: some View {
        Button(action: onAdd) {
            HStack(spacing: 16) {
                Image(systemName: "barcode.viewfinder")
                    .font(.system(size: scanIconSize, weight: .medium))   // scales with text size
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Scan a product")
                        .font(.title3.bold())
                    Text("Barcode and expiration date")
                        .font(.subheadline)
                        .opacity(0.9)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 14)
            .padding(.horizontal, 6)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.roundedRectangle(radius: 28))
        .controlSize(.large)
    }

    // when nothing is expiring, just a line of text
    private var allFreshRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("All fresh!").font(.headline)
            Text(freshText).font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    // white card so the scan button stays the most visible thing
    private var recipeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            // no icon, so the text is aligned
            Text("Recipe ideas")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            Text(recipeCardText)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            // recipes with the expiring products
            Button { onRecipes(forRecipes) } label: {
                Label("Recipes for expiring products", systemImage: "clock.badge.exclamationmark")
                    .labelStyle(AlignedIconLabelStyle())
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(forRecipes.isEmpty)

            // or pick products yourself
            Button(action: onChoose) {
                Label("Choose from pantry…", systemImage: "checklist")
                    .labelStyle(AlignedIconLabelStyle())
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(items.isEmpty)
        }
        // lighter buttons since they're secondary
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .padding(.vertical, 4)
    }
}

// MARK: - Label style with fixed icon width
// SF Symbols don't all have the same width, so I give each icon the same space
// and the texts line up
private struct AlignedIconLabelStyle: LabelStyle {
    @ScaledMetric(relativeTo: .body) private var iconWidth: CGFloat = 28

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon
                .frame(width: iconWidth)
            configuration.title
        }
    }
}
