import SwiftUI
import SwiftData

// Home order (changed after the second round of mentor feedback, because with a full
// fridge the recipe buttons ended up way below the fold):
// 1. scan button, the main action
// 2. expired products, one row and only when there are some (like "Software Update"
//    at the top of Settings): it's something to do, so it stays where you see it
// 3. recipes
// 4. the 4 most urgent products as round photos with their date (names were too long
//    for a row of four), "See all" is in the header like in the App Store
struct HomeView: View {
    @Query(sort: \FoodItem.expirationDate) private var items: [FoodItem]
    // read here so the list updates when the setting changes
    @AppStorage(AppSettings.Key.reminderDays) private var reminderDays = AppSettings.defaultReminderDays
    @ScaledMetric(relativeTo: .largeTitle) private var scanIconSize: CGFloat = 44

    // owned by ContentView (it closes a product's screen if the product gets deleted)
    @Binding var path: [Route]

    // also owned by ContentView, so a tapped notification can open the review
    @Binding var reviewingExpired: Bool
    var reviewStart: UUID?

    var onAdd: () -> Void
    var onRecipes: ([FoodItem]) -> Void
    var onChoose: () -> Void
    var onProfile: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    // how many expiring products Home shows, the rest are in "See all"
    private static let previewLimit = 4

    // expired and not answered yet
    private var pastDate: [FoodItem] { items.filter(\.waitsForAnswer) }
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
        NavigationStack(path: $path.withoutRepeats) {
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

                // expiring soon, only the first 4
                Section {
                    if expiring.isEmpty {
                        allFreshRow
                    } else if typeSize.isAccessibilitySize {
                        // with very big text four circles don't fit, and the dates
                        // would be cut: the usual rows, the name helps there too
                        ForEach(expiring.prefix(Self.previewLimit)) { item in
                            NavigationLink(value: Route.item(item.persistentModelID)) { ItemRow(item: item, dateOnly: true) }
                        }
                    } else {
                        expiringCircles
                    }
                } header: {
                    expiringHeader
                }
            }
            .listSectionSpacing(24)   // same gap between every section
            .navigationTitle("Home")
            .navigationDestination(for: Route.self) { $0.destination }
            .toolbar {
                // avatar button like in the App Store
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onProfile) {
                        // 40 pt to see, 44 pt to tap (Apple's minimum for anything you tap)
                        AvatarView(size: 40)
                            .frame(width: 44, height: 44)
                            .contentShape(.circle)
                    }
                    .accessibilityLabel("Account")
                }
                .sharedBackgroundVisibility(.hidden)
            }
            .sheet(isPresented: $reviewingExpired) { ReviewExpiredSheet(startAt: reviewStart) }
        }
    }

    // MARK: - Subviews
    // big scan button
    private var scanButton: some View {
        Button(action: onAdd) {
            // one line only, bigger: it's the main thing you do in the app
            HStack(spacing: 14) {
                Image(systemName: "barcode.viewfinder")
                    .font(.system(size: scanIconSize, weight: .medium))   // scales with text size
                    .accessibilityHidden(true)
                Text("Scan a product")
                    .font(.title2.bold())
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
        // the subtitle is gone from the screen, VoiceOver still says what gets scanned
        .accessibilityHint(Text("Barcode and expiration date"))
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
                Button { path.append(.allExpiring) } label: {
                    // just the words were ~20 pt tall: 44 pt is Apple's minimum to tap
                    Text("See all")
                        .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                        .contentShape(.rect)
                }
                .fontWeight(.regular)
                .textCase(nil)
            }
        }
        // always 44 pt, so the header doesn't jump when See all appears
        .frame(minHeight: 44)
    }

    // one row of round photos, like the favorites in Phone or People in Photos.
    // four fixed columns, so one or two products start on the left and don't spread out
    private var expiringCircles: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: Self.previewLimit),
                  spacing: 0) {
            ForEach(expiring.prefix(Self.previewLimit)) { item in
                // a Button and not a NavigationLink: four links in one row
                // would make the whole row a single tap
                Button { open(item) } label: { ExpiringCircle(item: item) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
    }

    private func open(_ item: FoodItem) {
        let route = Route.item(item.persistentModelID)
        // a quick double tap would open the same product twice
        if path.last != route { path.append(route) }
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

// MARK: - Round photo for "Expiring soon"
// the photo in a ring of the status color, and only the date under it.
// VoiceOver still reads the name and the status, which the circle doesn't show
private struct ExpiringCircle: View {
    let item: FoodItem

    @ScaledMetric(relativeTo: .body) private var diameter: CGFloat = 64
    @Environment(\.accessibilityDifferentiateWithoutColor) private var withoutColor
    @State private var photo: UIImage?

    private let ring: CGFloat = 2.5
    private let gap: CGFloat = 3   // a thin space between ring and photo, so the ring reads as a ring

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().strokeBorder(item.status.tint, lineWidth: ring)
                picture
                    .clipShape(.circle)
                    .padding(ring + gap)
            }
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: diameter)   // smaller if the column is narrower (small iPhones, bigger text)
            // "Differentiate Without Color" on: the status icon too, not only the ring
            .overlay(alignment: .bottomTrailing) {
                if withoutColor { badge }
            }

            Text(date)
                .font(.footnote)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .contentShape(.rect)   // the space around the circle opens it too
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(item.name), \(item.statusText), \(date)"))
        .task(id: item.persistentModelID) {
            guard let data = item.imageData, let full = UIImage(data: data) else { return }
            photo = await full.byPreparingThumbnail(ofSize: CGSize(width: diameter * 3, height: diameter * 3))
        }
    }

    @ViewBuilder
    private var picture: some View {
        if let photo {
            Color.clear.overlay {
                Image(uiImage: photo).resizable().scaledToFill()
            }
        } else {
            // no photo (typed by hand): the first letter on gray, like Contacts
            Circle()
                .fill(Color(.systemGray2).gradient)
                .overlay {
                    if let letter = item.name.first(where: { $0.isLetter || $0.isNumber }) {
                        Text(verbatim: String(letter).uppercased())
                            .font(.system(size: diameter * 0.4, weight: .medium, design: .rounded))
                            .minimumScaleFactor(0.5)
                            .foregroundStyle(.white)
                    } else {
                        Image(systemName: "photo").foregroundStyle(.white)
                    }
                }
        }
    }

    private var badge: some View {
        Image(systemName: item.status.symbol)
            .font(.subheadline)
            .foregroundStyle(item.status.tint)
            .padding(2)
            .background(Color(.secondarySystemGroupedBackground), in: .circle)   // same as the row
    }

    private var date: String {
        item.expirationDate.formatted(.dateTime.day().month(.abbreviated))
    }
}
