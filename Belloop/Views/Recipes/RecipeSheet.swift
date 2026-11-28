import SwiftUI
import SwiftData
import Translation
import AVFoundation
import NaturalLanguage

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
    // a language Apple's translator needs for products typed by hand (Apple's own download sheet)
    @State private var languageConfig: TranslationSession.Configuration?
    // asked only once per language: if the person said no, we don't ask every time
    @AppStorage("translation.askedLanguages") private var askedLanguages = ""
    @State private var isTranslating = false
    @State private var translationFailed = false
    // opens on Savory. if the products only make desserts it moves to Sweet by itself,
    // after that only the switch at the top changes it
    @State private var recipeType: RecipeType = .savory
    @State private var startTypeChecked = false

    // while pulling to refresh the old list stays on screen, the spinner is only for the first load
    private var state: LoadState { results[recipeType]?.state ?? .loading }

    private var unused: [String] { results[recipeType]?.unused ?? [] }

    private var noneTitle: LocalizedStringKey {
        switch recipeType {
        case .sweet: "No sweet recipes for these products"
        case .savory: "No savory recipes for these products"
        default: "No recipes found"
        }
    }

    var body: some View {
        NavigationStack {
            Group {
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
            // savory / sweet switch, always at the top
            .safeAreaBar(edge: .top) {
                Picker("Recipe type", selection: $recipeType) {
                    ForEach(RecipeType.choices) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            .navigationTitle("Recipes")
            .navigationBarTitleDisplayMode(.inline)
            // X and not checkmark because nothing gets saved here.
            // no Refresh button: you pull the list down for new recipes
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .close) { dismiss() }
                }
            }
            // loads the first time a type is shown. if that type already has a list
            // (or we're coming back from a recipe) nothing happens
            .task(id: recipeType) {
                guard results[recipeType] == nil, !loading.contains(recipeType) else { return }
                await load(recipeType)
            }
            // the language is downloaded (or the person said no): search again
            .translationTask(languageConfig) { session in
                try? await session.prepareTranslation()
                guard results[recipeType] == nil, !loading.contains(recipeType) else { return }
                await load(recipeType)
            }
            .translationTask(translationConfig) { session in
                await translate(using: session)
            }
        }
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
    // "Try Again" on the error screens: back to the spinner, then load
    private func reload() {
        let type = recipeType
        results[type] = nil
        Task { await load(type) }
    }

    private func load(_ type: RecipeType) async {
        loading.insert(type)
        defer { loading.remove(type) }
        translationFailed = false

        var shown = results[type]?.shownIDs ?? []
        let chosen = await IngredientNormalizer.resolve(items)
        let chosenIDs = Set(items.map(\.uid))
        let others = await IngredientNormalizer.resolve(pantry.filter { !chosenIDs.contains($0.uid) }, limit: 12)

        // a product typed by hand is still waiting for Apple's translator, because its language
        // isn't on the phone yet: Apple's sheet asks to download it, then the search runs again.
        // only when it's needed (with Apple Intelligence the name is usually understood already)
        if let language = await IngredientNormalizer.languageToDownload(for: items + pantry),
           let code = language.languageCode?.identifier,
           !askedLanguages.split(separator: ",").contains(Substring(code)) {
            askedLanguages += askedLanguages.isEmpty ? code : ",\(code)"
            languageConfig = .init(source: language, target: Locale.Language(identifier: "en"))
            return   // the spinner stays, .translationTask above searches again
        }

        var result = await MealDBService.recipes(for: chosen, pantry: others, type: type, excluding: shown)
        if result.recipes.isEmpty && !shown.isEmpty {
            // we've shown everything, start again
            shown.removeAll()
            result = await MealDBService.recipes(for: chosen, pantry: others, type: type, excluding: [])
        }
        guard !Task.isCancelled else { return }   // the sheet was closed, ignore

        // only the very first search can choose the tab, never after the user touched the switch
        let isFirstSearch = !startTypeChecked
        startTypeChecked = true

        let recipes = result.recipes
        guard !recipes.isEmpty else {
            results[type] = TypeResult(state: .failed(result.emptyReason ?? .noKnownIngredient),
                                       shownIDs: shown, unused: result.unusedProducts, translated: true)
            // no savory recipes, but there are sweet ones (e.g. only biscuits): open on Sweet.
            // savory and sweet together stays on Savory
            if isFirstSearch, type == .savory, recipeType == .savory, result.emptyReason == .noneOfType {
                recipeType = .sweet
            }
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
        // pull down for new recipes (same as the old Refresh button)
        .refreshable { await load(recipeType) }
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
    @State private var reader = RecipeReader()

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
                    Link(destination: source) {
                        // the words alone were too small to tap: 44 pt like any button
                        Text("Open original source")
                            .frame(minHeight: 44)
                            .contentShape(.rect)
                    }
                    .padding(.top, 4)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationBarTitleDisplayMode(.inline)
        // reads the recipe out loud, handy when your hands are dirty
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // LocalizedStringKey on purpose: a ternary of plain strings would skip the translation
                Button(reader.isSpeaking ? LocalizedStringKey("Stop Reading") : LocalizedStringKey("Read Aloud"),
                       systemImage: reader.isSpeaking ? "stop.fill" : "speaker.wave.2") {
                    reader.toggle(recipe)
                }
            }
        }
        .onDisappear { reader.stop() }
    }
}

// MARK: - Read aloud
// Uses the iPhone's built-in voices (AVSpeechSynthesizer): no AI, no internet, free.
// The voice matches the language the recipe is written in (translated or still English).
@MainActor @Observable
final class RecipeReader: NSObject, AVSpeechSynthesizerDelegate {
    private(set) var isSpeaking = false
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var lastUtterance: ObjectIdentifier?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func toggle(_ recipe: Recipe) {
        isSpeaking ? stop() : read(recipe)
    }

    func read(_ recipe: Recipe) {
        stop()
        let language = Self.language(of: recipe)
        let voice = Self.voice(for: language)

        // headings in the same language as the recipe, otherwise it sounds weird
        let sameAsPhone = language == Locale.current.language.languageCode?.identifier
        let ingredientsTitle = sameAsPhone ? String(localized: "Ingredients") : "Ingredients"
        let methodTitle = sameAsPhone ? String(localized: "Method") : "Method"
        let parts = [recipe.title, ingredientsTitle] + recipe.ingredients + [methodTitle] + recipe.steps

        // lower other audio (music, podcasts) while reading
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)

        var last: AVSpeechUtterance?
        for part in parts where !part.isEmpty {
            let utterance = AVSpeechUtterance(string: part)
            utterance.voice = voice
            utterance.postUtteranceDelay = 0.35   // small pause between lines
            synthesizer.speak(utterance)
            last = utterance
        }
        lastUtterance = last.map(ObjectIdentifier.init)
        isSpeaking = last != nil
        UIApplication.shared.isIdleTimerDisabled = isSpeaking   // screen stays on while cooking
    }

    func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        finished()
    }

    private func finished() {
        guard isSpeaking else { return }
        isSpeaking = false
        lastUtterance = nil
        UIApplication.shared.isIdleTimerDisabled = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            if id == self.lastUtterance { self.finished() }   // the last line was read
        }
    }

    // MARK: Language and voice
    // the recipe can be translated or still in English: look at the text itself
    private static func language(of recipe: Recipe) -> String {
        let text = ([recipe.title] + recipe.steps).joined(separator: " ")
        return NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue ?? "en"
    }

    // best voice for that language, from the phone's region if there is one (it-IT, en-GB…)
    private static func voice(for language: String) -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(language) }
        let regional = "\(language)-\(Locale.current.region?.identifier ?? "")"
        let pool = voices.contains { $0.language == regional } ? voices.filter { $0.language == regional } : voices
        return pool.max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: language)
    }
}
