import SwiftUI
import SwiftData
import PhotosUI

struct AddItemView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    // everything already in the pantry (for instant suggestions + duplicate check)
    @Query(sort: \FoodItem.addedDate, order: .reverse) private var existing: [FoodItem]

    // opened from Home's "Scan a product": the camera is the first thing you see,
    // the form comes after the scan (or with "Enter manually")
    init(startScanning: Bool = false) {
        _cameraFirst = State(initialValue: startScanning)
    }
    @State private var cameraFirst: Bool

    @State private var name = ""
    @State private var expiration = Calendar.current.date(byAdding: .day, value: 3, to: Date()) ?? Date()
    @State private var barcode: String?
    @State private var imageData: Data?

    // info from OFF or an older item, used when saving to get the english recipe keyword
    @State private var filledName: String?
    @State private var englishHint: String?
    @State private var categoryHint: [String] = []

    @State private var showScanner = false
    @State private var showCamera = false
    @State private var photoItem: PhotosPickerItem?
    @State private var isWorking = false
    @State private var message: String?
    // the date read by the camera: while the picker still shows it, a note says so
    @State private var scannedDate: Date?

    // duplicate alert
    @State private var duplicate: FoodItem?
    @State private var allowDuplicate = false
    @State private var saveAfterConfirm = false

    // suggestions while typing
    @State private var suggestions: [OFFProduct] = []
    @State private var suggestionTask: Task<Void, Never>?
    @State private var isSearching = false
    @State private var searchNote: String?

    // old items that match the text, no network needed
    private var localMatches: [FoodItem] {
        let query = name.trimmingCharacters(in: .whitespaces)
        guard query.count >= 2, name != filledName else { return [] }
        var seen = Set<String>()
        return existing
            .filter { $0.name.localizedStandardContains(query)
                && $0.name.caseInsensitiveCompare(query) != .orderedSame }
            .filter { seen.insert($0.name.lowercased()).inserted }
            .prefix(3)
            .map { $0 }
    }

    var body: some View {
        if cameraFirst {
            // same sheet: first the camera, then the form with what was found.
            // the X closes the whole sheet, nothing has been added yet
            ScannerSheet(onManual: { withAnimation { cameraFirst = false } }) { found in
                withAnimation { cameraFirst = false }
                use(found)
            }
        } else {
            form
        }
    }

    private var form: some View {
        NavigationStack {
            Form {
                Section("Scan") {
                    // barcode and date in the same scan (also to scan again and fix the date)
                    Button { showScanner = true } label: {
                        Label("Scan barcode and date", systemImage: "barcode.viewfinder")
                    }
                    Button { showCamera = true } label: {
                        Label("Take a photo", systemImage: "camera")
                    }
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label("Choose a photo", systemImage: "photo.on.rectangle")
                    }
                }

                if isWorking {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Looking up the product…")
                    }
                }

                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Details") {
                    TextField("Product name", text: $name)

                    // suggestions right below the text field, like a search bar
                    ForEach(localMatches) { item in
                        Button { applyLocal(item) } label: {
                            Label(item.name, systemImage: "clock.arrow.circlepath")
                                .foregroundStyle(.primary)
                        }
                    }
                    ForEach(suggestions) { product in
                        Button {
                            apply(product)
                            suggestions = []
                        } label: {
                            HStack(spacing: 12) {
                                AsyncImage(url: product.imageURL) { image in
                                    image.resizable().scaledToFill()
                                } placeholder: {
                                    Color.secondary.opacity(0.15)
                                }
                                .frame(width: 36, height: 36)
                                .clipShape(.rect(cornerRadius: 6))

                                VStack(alignment: .leading) {
                                    Text(product.name).foregroundStyle(.primary)
                                    if let brand = product.brand {
                                        Text(brand).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }

                    // products still coming: say it, so it doesn't look like there are none
                    if isSearching && suggestions.isEmpty && searchNote == nil {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Searching products…")
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let searchNote {
                        Text(searchNote)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    DatePicker("Expiration", selection: $expiration, displayedComponents: .date)
                    if let scannedDate, Calendar.current.isDate(scannedDate, inSameDayAs: expiration) {
                        Label("Read from the package", systemImage: "checkmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if let data = imageData, let uiImage = UIImage(data: data) {
                    Section("Photo") {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 200)
                            .clipShape(.rect(cornerRadius: 10))
                    }
                }
            }
            .navigationTitle("New product")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // X to close, checkmark to save (iOS 26 style, no text)
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .close) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm, action: save)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onChange(of: name) { _, newValue in scheduleSuggestions(for: newValue) }
            .sheet(isPresented: $showScanner) {
                ScannerSheet { found in
                    showScanner = false
                    use(found)
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { image in
                    imageData = image.downscaledJPEG()
                }
                .ignoresSafeArea()
            }
            .alert(
                "Already in your pantry",
                isPresented: Binding(get: { duplicate != nil }, set: { if !$0 { duplicate = nil } }),
                presenting: duplicate
            ) { _ in
                Button("Add Another") {
                    allowDuplicate = true
                    if saveAfterConfirm { save() }
                }
                Button("Don't Add", role: .cancel) { dismiss() }
            } message: { item in
                Text("\(item.name) is already in your pantry and expires on \(item.expirationDate.formatted(date: .abbreviated, time: .omitted)). Do you want to add another one?")
            }
            .onChange(of: photoItem) { _, newItem in
                guard let newItem else { return }
                Task {
                    if let data = try? await newItem.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        imageData = image.downscaledJPEG()
                    }
                }
            }
        }
    }

    // MARK: - Live suggestions
    // searches Open Food Facts for real products only (with brand and photo).
    // waits for a pause in typing and drops old requests if the text changed in the meantime
    private func scheduleSuggestions(for text: String) {
        suggestionTask?.cancel()
        isSearching = false   // only the latest request controls the spinner
        let query = text.trimmingCharacters(in: .whitespaces)

        // skip if the text is too short or it was just filled by a suggestion/barcode
        guard query.count >= 2, text != filledName else {
            suggestions = []
            searchNote = nil
            return
        }

        suggestionTask = Task {
            // OFF matches whole words so give the user time to finish the word
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            isSearching = true

            // only real products from Open Food Facts, min 3 letters
            guard query.count >= 3 else { isSearching = false; return }
            do {
                let result = try await OpenFoodFactsService.search(query)
                guard !Task.isCancelled else { return }
                suggestions = result
                searchNote = nil
            } catch {
                guard !Task.isCancelled else { return }   // user kept typing, not a real error
                suggestions = []
                if case OFFSearchError.rateLimited = error {
                    searchNote = String(localized: "Too many searches in a row. Wait a few seconds, or save the name as typed.")
                } else {
                    searchNote = String(localized: "Product search isn't responding. You can still save the name as typed.")
                }
            }
            isSearching = false
        }
    }

    private func stopSuggestions() {
        suggestionTask?.cancel()
        isSearching = false
        suggestions = []
        searchNote = nil
    }

    // MARK: - Scan results
    private func use(_ found: ScanResult) {
        if let date = found.date { useScannedDate(date) }
        if let code = found.barcode { useScannedBarcode(code) }
    }

    private func useScannedDate(_ date: Date) {
        expiration = date
        scannedDate = date
    }

    private func useScannedBarcode(_ code: String) {
        // meat, fish, deli: the label is printed by the store, no database knows it
        guard !Self.isStoreLabel(code) else {
            message = String(localized: "This is a label printed by the store (meat, fish, deli counter), so no database knows it. Type the name, then scan the date on the label.")
            return
        }
        barcode = code
        // if we already have this barcode, ask now before filling everything
        if !allowDuplicate, let match = existingMatch(barcode: code, name: "") {
            duplicate = match
        }
        Task { await lookup(code) }
    }

    // MARK: - Open Food Facts
    // Barcodes starting with 2 are "in-store" codes (GS1 prefixes 20-29): the supermarket prints them
    // on things it weighs and packs itself, and they hold its own item number + weight or price.
    // They aren't real product codes, so they're never in Open Food Facts (and the same code can be
    // a different product tomorrow, so we don't save it either).
    // 13 digits starting with 02 = the American version of the same thing (UPC number system 2).
    private static func isStoreLabel(_ code: String) -> Bool {
        guard code.allSatisfy(\.isNumber) else { return false }
        switch code.count {
        case 13: return code.hasPrefix("2") || code.hasPrefix("02")
        case 8: return code.hasPrefix("2")
        case 12: return code.hasPrefix("2")
        default: return false
        }
    }

    private func lookup(_ code: String) async {
        isWorking = true
        defer { isWorking = false }
        do {
            if let product = try await OpenFoodFactsService.product(for: code) {
                apply(product)
            } else {
                message = String(localized: "Product not found in the database: enter the name by hand.")
            }
        } catch {
            message = String(localized: "Network error: enter the name by hand.")
        }
    }

    private func apply(_ product: OFFProduct) {
        stopSuggestions()
        name = product.displayName
        filledName = name
        englishHint = product.englishName
        categoryHint = product.categories
        if barcode == nil { barcode = product.barcode }
        message = String(localized: "Product found: \(product.displayName)")

        // keep the user's photo if they took one
        if imageData == nil, let url = product.imageURL {
            Task {
                if let (data, _) = try? await URLSession.shared.data(from: url),
                   let image = UIImage(data: data), imageData == nil {
                    imageData = image.downscaledJPEG()
                }
            }
        }
    }

    // reuse the data of an item added before
    private func applyLocal(_ item: FoodItem) {
        stopSuggestions()
        name = item.name
        filledName = item.name
        englishHint = item.recipeKeyword
        categoryHint = item.categoryTags
        if barcode == nil { barcode = item.barcode }
        if imageData == nil { imageData = item.imageData }
        message = nil
    }

    // MARK: - Duplicates
    // same barcode, or same name if typed by hand
    private func existingMatch(barcode: String?, name: String) -> FoodItem? {
        if let barcode, let match = existing.first(where: { $0.barcode == barcode }) { return match }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return existing.first { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    // MARK: - Save
    private func save() {
        let finalName = name.trimmingCharacters(in: .whitespaces)
        if !allowDuplicate, let match = existingMatch(barcode: barcode, name: finalName) {
            saveAfterConfirm = true   // so "Add Another" can save directly
            duplicate = match
            return
        }
        let item = FoodItem(name: finalName, expirationDate: expiration, barcode: barcode, imageData: imageData)
        context.insert(item)
        NotificationManager.schedule(for: item)

        // if the user changed the name after, the hints are not valid anymore
        let hintsValid = (finalName == filledName)
        let english = hintsValid ? englishHint : nil
        let categories = hintsValid ? categoryHint : []
        item.categoryTags = categories
        Task {
            item.recipeKeyword = await IngredientNormalizer.englishKeyword(
                for: finalName, englishName: english, categories: categories
            )
            item.recipeKeywordVersion = IngredientNormalizer.version
        }
        dismiss()
    }
}
