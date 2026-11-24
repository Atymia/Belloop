import SwiftUI
import SwiftData

// Home order (changed after the second round of mentor feedback, because with a full
// fridge the recipe buttons ended up way below the fold):
// 1. scan button, the main action
// 2. expired products, one row and only when there are some (like "Software Update"
//    at the top of Settings): it's something to do, so it stays where you see it
// 3. recipes
// 4. the 3 most urgent products, "See all" is in the header like in the App Store
struct HomeView: View {
    @Query(sort: \FoodItem.expirationDate) private var items: [FoodItem]
    // read here so the list updates when the setting changes
    @AppStorage(AppSettings.Key.reminderDays) private var reminderDays = AppSettings.defaultReminderDays
    @ScaledMetric(relativeTo: .largeTitle) private var scanIconSize: CGFloat = 40

    var onAdd: () -> Void
    var onRecipes: ([FoodItem]) -> Void
    var onChoose: () -> Void
    var onProfile: () -> Void

    @State private var reviewingExpired = false
    @State private var showingAllExpiring = false

    // how many expiring products Home shows, the rest are in "See all"
    private static let previewLimit = 3

    // expired and not answered yet
    private var pastDate: [FoodItem] { items.filter { $0.isExpired && !$0.expiryReviewed } }
    // from today to reminderDays (already sorted by date, so the most urgent come first)
    private var expiring: [FoodItem] { items.filter { $0.expires(within: reminderDays) } }
    // expiring soon + expired since yesterday at most (rule is in Models)
    private var forRecipes: [FoodItem] { items.filter { $0.goodForRecipes(within: reminderDays) } }

    // a hint only when the first button is off, so you know why.
    // with something to cook the buttons speak for themselves
    private var recipeHint: LocalizedStringKey? {
        if !forRecipes.isEmpty { return nil }
        return items.isEmpty
            ? "Add a few products to get recipe ideas."
            : "Nothing's about to expire. Pick anything from your pantry."
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

                // expired: one row, the questions are in the sheet
                if !pastDate.isEmpty {
                    Section {
                        Button { reviewingExpired = true } label: { expiredRow }
                            .badge(pastDate.count)   // count on the right, like in Settings
                    }
                }

                // recipes
                Section("Recipe ideas") { recipeCard }

                // expiring soon, only the first 3
                Section {
                    if expiring.isEmpty {
                        allFreshRow
                    } else {
                        ForEach(expiring.prefix(Self.previewLimit)) { item in
                            NavigationLink(value: item) { ItemRow(item: item, dateOnly: true) }
                        }
                    }
                } header: {
                    expiringHeader
                }
            }
            .listSectionSpacing(24)   // same gap between every section
            .navigationTitle("Home")
            .navigationDestination(for: FoodItem.self) { ItemDetailView(item: $0) }
            .navigationDestination(isPresented: $showingAllExpiring) { ExpiringListView() }
            .toolbar {
                // avatar button like in the App Store
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onProfile) { AvatarView(size: 36) }
                        .accessibilityLabel("Account")
                }
                .sharedBackgroundVisibility(.hidden)
            }
            .sheet(isPresented: $reviewingExpired) { ReviewExpiredSheet() }
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

    // "Expiring soon" on the left, "See all" on the right from the 4th product on
    // (in the header and not as a row, so it doesn't take a line of the list)
    private var expiringHeader: some View {
        HStack {
            Text("Expiring soon")
            Spacer()
            if expiring.count > Self.previewLimit {
                Button("See all") { showingAllExpiring = true }
                    .fontWeight(.regular)
                    .textCase(nil)
            }
        }
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

    // same icon as the urgent products, the number is on the right (badge)
    private var expiredRow: some View {
        Label {
            Text("Past their date")
                .foregroundStyle(.primary)   // otherwise the button paints it blue
        } icon: {
            Image(systemName: ExpiryStatus.urgent.symbol)
                .foregroundStyle(ExpiryStatus.urgent.tint)
        }
    }

    // white card so the scan button stays the most visible thing
    private var recipeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let recipeHint {
                Text(recipeHint)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

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
