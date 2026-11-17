import SwiftUI
import SwiftData
import Translation

// MARK: - Recipe list (tap one to open it)
struct RecipeSheet: View {
    let items: [FoodItem]
    // the whole pantry: recipes get extra points if they use other products too
    @Query private var pantry: [FoodItem]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var thumbnailSize: CGFloat = 72

    private enum LoadState {
        case loading
        case results([Recipe])
        case failed(RecipeSearchResult.EmptyReason)
    }

    // one list per type, so going Savory -> Sweet -> Savory shows the same recipes.
    // only Refresh makes a new list
    private struct TypeResult {
        var state: LoadState
        var shownIDs: Set<String>   // already shown, so Refresh gives new ones
        var unused: [String]        // products with no recipes, shown at the bottom
        var translated = false
    }

    @State private var results: [RecipeType: TypeResult] = [:]
    @State private var loading: Set<RecipeType> = []
    @State private var translationConfig: TranslationSession.Configuration?
    @State private var isTranslating = false
    @State private var translationFailed = false
    // sweet or savory, nil until the user picks
    @State private var recipeType: RecipeType?

    private var state: LoadState {
        guard let recipeType, !loading.contains(recipeType), let result = results[recipeType] else { return .loading }
        return result.state
    }

    private var unused: [String] { recipeType.flatMap { results[$0]?.unused } ?? [] }

    private var isLoading: Bool { recipeType.map { loading.contains($0) } ?? false }

    private var noneTitle: LocalizedStringKey {
        switch recipeType {
        case .sweet: "No sweet recipes for these products"
        case .savory: "No savory recipes for these products"
        default: "No recipes found"
        }
    }

    // for the picker at the top
    private var typeBinding: Binding<RecipeType> {
        Binding(get: { recipeType ?? .savory }, set: { recipeType = $0 })
    }

    var body: some View {
        NavigationStack {
            Group {
                if recipeType == nil {
                    typeChoice
                } else {
                    switch state {
                    case .loading:
                        VStack(spacing: 20) {
                            ProgressView().controlSize(.large)
                            Text("Finding the best recipes for you…")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    case .results(let recipes):
                        resultsList(recipes)

                    case .failed(let reason):
                        failedView(reason)
                    }
                }
            }
            // after choosing, you can switch here
            .safeAreaBar(edge: .top) {
                if recipeType != nil {
                    Picker("Recipe type", selection: typeBinding) {
                        ForEach(RecipeType.choices) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }
            }
            .navigationTitle("Recipes")
            .navigationBarTitleDisplayMode(.inline)
            // X and not checkmark because nothing gets saved here
            // (the Refresh text is still read by VoiceOver)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .close) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Refresh", systemImage: "arrow.clockwise") { reload() }
                        .disabled(recipeType == nil || isLoading || isTranslating)
                }
            }
            // loads the first time a type is picked. if that type already has a list
            // (or we're coming back from a recipe) nothing happens
            .task(id: recipeType) {
                guard let recipeType, results[recipeType] == nil, !loading.contains(recipeType) else { return }
                await load(recipeType)
            }
            .translationTask(translationConfig) { session in
                await translate(using: session)
            }
        }
    }

    // MARK: - Sweet or savory?
    private var typeChoice: some View {
        VStack(spacing: 24) {
            Text("What would you like to cook?")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            VStack(spacing: 12) {
                ForEach(RecipeType.choices) { type in
                    Button { recipeType = type } label: {
                        Label(type.title, systemImage: type.symbol)
                            .font(.title3.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty state
    @ViewBuilder
    private func failedView(_ reason: RecipeSearchResult.EmptyReason) -> some View {
        switch reason {
        case .network:
            ContentUnavailableView {
                Label("Couldn't load recipes", systemImage: "wifi.slash")
            } description: {
                Text("Check your connection and try again.")
            } actions: {
                Button("Try Again") { reload() }
                    .buttonStyle(.bordered)
            }

        case .noKnownIngredient:
            ContentUnavailableView {
                Label("No recipes found", systemImage: "fork.knife")
            } description: {
                if unused.isEmpty {
                    Text("Try selecting other products.")
                } else {
                    Text("No recipe in our collection uses \(unused.formatted(.list(type: .or))). Try selecting other products.")
                }
            }

        case .noneOfType:
            ContentUnavailableView {
                Label(noneTitle, systemImage: "fork.knife")
            } description: {
                Text("These products are only used in recipes of the other type.")
            } actions: {
                if recipeType == .sweet {
                    Button("Show Savory Recipes") { recipeType = .savory }.buttonStyle(.bordered)
                } else {
                    Button("Show Sweet Recipes") { recipeType = .sweet }.buttonStyle(.bordered)
                }
            }
        }
    }

    // MARK: - Loading
    private func reload() {
        guard let recipeType else { return }
        Task { await load(recipeType) }
    }

    private func load(_ type: RecipeType) async {
        loading.insert(type)
        defer { loading.remove(type) }
        translationFailed = false

        var shown = results[type]?.shownIDs ?? []
        let chosen = await IngredientNormalizer.resolve(items)
        let chosenIDs = Set(items.map(\.uid))
        let others = await IngredientNormalizer.resolve(pantry.filter { !chosenIDs.contains($0.uid) }, limit: 12)

        var result = await MealDBService.recipes(for: chosen, pantry: others, type: type, excluding: shown)
        if result.recipes.isEmpty && !shown.isEmpty {
            // we've shown everything, start again
            shown.removeAll()
            result = await MealDBService.recipes(for: chosen, pantry: others, type: type, excluding: [])
        }
        guard !Task.isCancelled else { return }   // the sheet was closed, ignore

        let recipes = result.recipes
        guard !recipes.isEmpty else {
            results[type] = TypeResult(state: .failed(result.emptyReason ?? .noKnownIngredient),
                                       shownIDs: shown, unused: result.unusedProducts, translated: true)
            return
        }
        shown.formUnion(recipes.map(\.id))
        results[type] = TypeResult(state: .results(recipes), shownIDs: shown, unused: result.unusedProducts)
        requestTranslation()
    }

    // translate if the phone isn't in english
    private func requestTranslation() {
        let target = Locale.current.language
        guard target.languageCode != .english else { return }
        if translationConfig == nil {
            translationConfig = .init(source: Locale.Language(identifier: "en"), target: target)
        } else {
            translationConfig?.invalidate()   // runs .translationTask again
        }
    }

    private func translate(using session: TranslationSession) async {
        isTranslating = true
        defer { isTranslating = false }
        for (type, entry) in results where !entry.translated {
            guard case .results(let recipes) = entry.state else { continue }
            do {
                let translated = try await RecipeTranslator.translate(recipes, using: session)
                // if Refresh made a new list in the meantime, don't overwrite it
                guard case .results(let now) = results[type]?.state, now.map(\.id) == recipes.map(\.id) else { continue }
                results[type]?.state = .results(translated)
                results[type]?.translated = true
            } catch {
                translationFailed = true
                results[type]?.translated = true
            }
        }
    }

    // MARK: - List
    private func resultsList(_ recipes: [Recipe]) -> some View {
        List {
            if isTranslating || translationFailed {
                Section { statusLine }
            }

            Section {
                ForEach(recipes) { recipe in
                    // pass the id so the detail shows the translated version
                    NavigationLink(value: recipe.id) {
                        row(recipe)
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if !unused.isEmpty {
                        Text("No recipes use: \(unused.formatted(.list(type: .and)))")
                    }
                    Text("Recipes from TheMealDB")
                }
            }
        }
        .navigationDestination(for: String.self) { id in
            if let recipe = recipes.first(where: { $0.id == id }) {
                RecipeDetailView(recipe: recipe)
            }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if isTranslating {
            HStack(spacing: 8) {
                ProgressView()
                Text("Translating…").font(.footnote).foregroundStyle(.secondary)
            }
        } else if translationFailed {
            Text("Couldn't translate the recipes, showing the originals.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // photo, title and which products it uses
    private func row(_ recipe: Recipe) -> some View {
        // photo next to the title, or above with big text
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 12))

        return layout {
            RecipeThumbnail(url: recipe.imageURL, size: thumbnailSize)
            VStack(alignment: .leading, spacing: 4) {
                Text(recipe.title)
                    .font(.headline)
                    .lineLimit(3)
                if !recipe.usedProducts.isEmpty {
                    Text("Uses \(recipe.usedProducts.formatted(.list(type: .and)))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if !recipe.pantryProducts.isEmpty {
                    Text("Also from your pantry: \(recipe.pantryProducts.formatted(.list(type: .and)))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Thumbnail
private struct RecipeThumbnail: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Color.gray.opacity(0.15).overlay {
                if url != nil {
                    ProgressView()
                } else {
                    Image(systemName: "fork.knife").foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: 12))
        .accessibilityHidden(true)
    }
}

// MARK: - Recipe detail
private struct RecipeDetailView: View {
    let recipe: Recipe

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let url = recipe.imageURL {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color.gray.opacity(0.15).overlay(ProgressView())
                    }
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)   // works at any width
                    .clipped()
                    .clipShape(.rect(cornerRadius: 12))
                    .accessibilityHidden(true)
                }

                Text(recipe.title).font(.title2.bold()).accessibilityAddTraits(.isHeader)

                Text("Ingredients").font(.headline).padding(.top, 8).accessibilityAddTraits(.isHeader)
                ForEach(Array(recipe.ingredients.enumerated()), id: \.offset) { _, line in
                    Text(verbatim: "• \(line)").font(.subheadline)
                }

                Text("Method").font(.headline).padding(.top, 8).accessibilityAddTraits(.isHeader)
                ForEach(Array(recipe.steps.enumerated()), id: \.offset) { index, step in
                    Text(verbatim: "\(index + 1). \(step)").font(.subheadline)
                }

                if let source = recipe.sourceURL {
                    Link("Open original source", destination: source).padding(.top, 8)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}
