import SwiftUI
import SwiftData

// MARK: - "Did you use these?"
// Home shows a single row for the expired products, this sheet goes through them.
// one card per product: you swipe left and right to look at them in any order,
// and answering one moves you to the next. used or thrown away = deleted,
// still have it = set aside until tomorrow (keptOn), so either way the card leaves the list
struct ReviewExpiredSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \FoodItem.expirationDate) private var items: [FoodItem]

    // the product to show first (a tapped notification about it), else the first one
    var startAt: UUID? = nil

    // the card on screen
    @State private var current: FoodItem.ID?

    private var pending: [FoodItem] { items.filter(\.waitsForAnswer) }

    private var position: Int {
        (pending.firstIndex { $0.id == current } ?? 0) + 1
    }

    var body: some View {
        NavigationStack {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(pending) { item in
                        card(for: item)
                            .containerRelativeFrame(.horizontal)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $current)
            .scrollIndicators(.hidden)
            .safeAreaInset(edge: .bottom) { pageDots }
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
            if pending.isEmpty { dismiss() }
            current = (pending.first { $0.uid == startAt } ?? pending.first)?.id
        }
        // last one answered, nothing left to ask
        .onChange(of: pending.isEmpty) { _, empty in
            if empty { dismiss() }
        }
    }

    // MARK: - Card
    private func card(for item: FoodItem) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                ItemThumbnail(item: item, size: 64)

                VStack(spacing: 4) {
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
                    Button { answer(.used, item) } label: {
                        Text("Yes, I used it").frame(maxWidth: .infinity)
                    }
                    Button(role: .destructive) { answer(.thrownAway, item) } label: {
                        Text("No, I threw it away").frame(maxWidth: .infinity)
                    }
                    Button { answer(.kept, item) } label: {
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
        .scrollBounceBehavior(.basedOnSize)   // no bounce when it all fits
    }

    // dots like the Home screen pages, plus "2 of 5" for VoiceOver
    @ViewBuilder
    private var pageDots: some View {
        if pending.count > 1 {
            Group {
                // up to 10 dots, after that they wouldn't fit: "3 of 25"
                if pending.count <= 10 {
                    HStack(spacing: 8) {
                        ForEach(pending) { item in
                            Circle()
                                .fill(item.id == current ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                                .frame(width: 7, height: 7)
                        }
                    }
                } else {
                    Text("\(position) of \(pending.count)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.bottom, 8)
            .accessibilityElement()
            .accessibilityLabel(Text("\(position) of \(pending.count)"))
            .accessibilityHint(Text("Swipe left or right to see the other products"))
        }
    }

    // the answered card leaves, so move to the next one (or the one before, if it was the last)
    private func answer(_ outcome: ExpiryReview.Outcome, _ item: FoodItem) {
        let list = pending
        if let index = list.firstIndex(where: { $0.id == item.id }) {
            let next = index + 1 < list.count ? list[index + 1] : (index > 0 ? list[index - 1] : nil)
            withAnimation { current = next?.id }
        }
        withAnimation { ExpiryReview.apply(outcome, to: item, in: context) }
    }
}
