import SwiftUI
import SwiftData

// MARK: - Resize photos before saving (full size is way too big)
extension UIImage {
    func downscaledJPEG(maxDimension: CGFloat = 1200, quality: CGFloat = 0.7) -> Data? {
        let scale = min(1, maxDimension / max(size.width, size.height))
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format)
            .jpegData(withCompressionQuality: quality) { _ in
                draw(in: CGRect(origin: .zero, size: target))
            }
    }
}

// MARK: - Thumbnail (loaded in the background)
struct ItemThumbnail: View {
    let item: FoodItem
    var size: CGFloat = 45

    // gets bigger with the text size, but not too much
    @ScaledMetric(relativeTo: .headline) private var scale = 1.0

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(.purple.opacity(0.2))
                    .overlay(Image(systemName: "photo").foregroundStyle(.purple))
            }
        }
        .frame(width: size * min(scale, 2), height: size * min(scale, 2))
        .clipShape(.rect(cornerRadius: 8))
        .accessibilityHidden(true)
        .task(id: item.persistentModelID) {
            guard let data = item.imageData, let full = UIImage(data: data) else { return }
            image = await full.byPreparingThumbnail(ofSize: CGSize(width: size * 3, height: size * 3))
        }
    }
}

// MARK: - Row
struct ItemRow: View {
    let item: FoodItem
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // with very big text, put things one under the other
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 12))

        layout {
            ItemThumbnail(item: item)
            // name, then "Expires in 3 days · 15 Nov"
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.headline)
                    .lineLimit(2)
                // just text so it's aligned with the name
                Text(verbatim: "\(item.statusText) · \(item.expirationDate.formatted(.dateTime.day().month(.abbreviated)))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // icon on the right like in Reminders (the text says it too, not only the color)
            if !typeSize.isAccessibilitySize {
                Image(systemName: item.status.symbol)
                    .font(.title3)
                    .foregroundStyle(item.status.tint)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Detail
struct ItemDetailView: View {
    @Bindable var item: FoodItem
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var photo: UIImage?
    @State private var confirmDelete = false

    var body: some View {
        Form {
            Section {
                if let photo {
                    Image(uiImage: photo)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 280)
                        .clipShape(.rect(cornerRadius: 16))
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                } else {
                    ContentUnavailableView("No photo", systemImage: "photo.badge.exclamationmark")
                        .listRowBackground(Color.clear)
                }
            }

            Section {
                TextField("Product", text: $item.name)
                DatePicker("Expiration", selection: $item.expirationDate, displayedComponents: .date)
                LabeledContent("Status", value: item.statusText)
                LabeledContent("Added on") { Text(item.addedDate, style: .date) }
                if let barcode = item.barcode {
                    LabeledContent("Barcode", value: barcode)
                }
            }

            Section {
                Button("Remove from pantry", systemImage: "trash", role: .destructive) {
                    confirmDelete = true
                }
            }
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if let data = item.imageData, let full = UIImage(data: data) {
                photo = await full.byPreparingThumbnail(ofSize: CGSize(width: 1200, height: 1200))
            }
        }
        // new date or name = new notification and new recipe keyword
        .onChange(of: item.expirationDate) {
            item.expiryReviewed = false   // ask again after the new date
            NotificationManager.schedule(for: item)
        }
        .onChange(of: item.name) {
            item.recipeKeyword = nil
            item.recipeKeywordVersion = 0
            NotificationManager.schedule(for: item)
        }
        .confirmationDialog("Remove \(item.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                dismiss()
                // delete a bit later, otherwise the view crashes while going back
                Task { @MainActor in context.remove(item) }
            }
        }
    }
}
