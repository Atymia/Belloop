import SwiftUI
import SwiftData

// MARK: - "Did you use these?" one product at a time
// Home shows a single row for the expired products, this sheet goes through them.
// there's no index to keep track of: every answer takes the product out of the list
// (used or thrown away = deleted, still have it = expiryReviewed), so the next
// product is always the first one
struct ReviewExpiredSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \FoodItem.expirationDate) private var items: [FoodItem]

    // how many there were when the sheet opened, for "2 of 5"
    @State private var total = 0

    private var pending: [FoodItem] { items.filter { $0.isExpired && !$0.expiryReviewed } }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let item = pending.first {
                    card(for: item)
                        .id(item.uid)   // new product = new view, so it slides in
                        .transition(.push(from: .trailing))
                }
            }
            .scrollBounceBehavior(.basedOnSize)   // no bounce when it all fits
            .animation(.default, value: pending.first?.uid)
            .navigationTitle("Did you use these?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // X: you can answer the rest later, they stay on Home
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .close) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            total = pending.count
            if pending.isEmpty { dismiss() }
        }
        // last one answered, nothing left to ask
        .onChange(of: pending.isEmpty) { _, empty in
            if empty { dismiss() }
        }
    }

    private func card(for item: FoodItem) -> some View {
        // iCloud could add one while the sheet is open, so never show "6 of 5"
        let count = max(total, pending.count)
        let position = count - pending.count + 1

        return VStack(spacing: 20) {
            ItemThumbnail(item: item, size: 64)

            VStack(spacing: 4) {
                if count > 1 {
                    Text("\(position) of \(count)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Text(item.name)
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text(item.statusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)

            // same weight for all three: we want the honest answer, not the nice one
            VStack(spacing: 8) {
                Button { ExpiryReview.apply(.used, to: item, in: context) } label: {
                    Text("Yes, I used it").frame(maxWidth: .infinity)
                }
                Button(role: .destructive) { ExpiryReview.apply(.thrownAway, to: item, in: context) } label: {
                    Text("No, I threw it away").frame(maxWidth: .infinity)
                }
                Button { ExpiryReview.apply(.kept, to: item, in: context) } label: {
                    Text("I still have it").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
    }
}
