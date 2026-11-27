import Foundation
import FoundationModels
import Translation

@Generable
struct ProductName {
    @Guide(description: """
        What the product is, in English, lowercase, generic, no brand and no quantity. \
        Name the product itself, never one of its ingredients. \
        Examples: 'milk', 'chicken breast', 'pesto', 'passata', 'digestive biscuits', \
        'hot chocolate mix', 'chocolate corn cakes', 'protein bar'
        """)
    var product: String
}

// "Latte Parmalat intero UHT" -> "milk", so we can search recipes in english.
// A product is never turned into one of its ingredients: "chocolate corn cakes" stay corn cakes.
// Then the recipe database decides: if no recipe uses corn cakes, they're simply not used
enum IngredientNormalizer {
    // increase this when the rules change, old keywords get recalculated
    // v2: pesto stays pesto (not basil)
    // v3: scanned products also save their OFF categories
    // v5: the model names the product itself (corn cakes, hot chocolate mix), never its ingredients
    // v6: names typed by hand are checked against TheMealDB's ingredients
    //     ("Latte" became the coffee drink and found no recipes, it's milk)
    static let version = 6

    struct Keyword: Sendable {
        let value: String
        // false = no connection, so we couldn't check it: it's worked out again next time
        let checked: Bool
    }

    // with Apple Intelligence: the model says what the product is (using the database info too).
    // without it: OFF english name, OFF category, small dictionary, the name as is
    static func englishKeyword(for name: String, englishName: String?, categories: [String]) async -> Keyword {
        let viaModel = await viaFoundationModel(name, englishName: englishName, categories: categories)

        // scanned products: if the keyword finds nothing, the recipe search
        // still tries their OFF categories, so this order is enough
        if let category = categories.last, !category.isEmpty {
            let value = viaModel ?? clean(englishName) ?? category
            return Keyword(value: value, checked: true)
        }

        // typed by hand there's nothing else to fall back on,
        // so we keep the first guess that is really a TheMealDB ingredient
        return await checkedKeyword(for: name, guesses: [viaModel, clean(englishName), dictionaryHit(name)])
    }

    // finds the keyword for each item and saves it.
    // only the most urgent ones (8 by default, the recipe search doesn't use more)
    @MainActor
    static func resolve(_ items: [FoodItem], limit: Int = 8) async -> [IngredientInfo] {
        var result: [IngredientInfo] = []
        for item in items.sorted(by: { $0.daysLeft < $1.daysLeft }).prefix(limit) {
            let keyword: String
            if let saved = item.recipeKeyword, !saved.isEmpty, item.recipeKeywordVersion == version {
                keyword = saved
            } else {
                // older scanned items don't have categories,
                // so ask OFF again one time
                var english: String?
                if let barcode = item.barcode, item.categoryTags.isEmpty,
                   let product = try? await OpenFoodFactsService.product(for: barcode) {
                    item.categoryTags = product.categories
                    english = product.englishName
                }
                let found = await englishKeyword(for: item.name, englishName: english, categories: item.categoryTags)
                keyword = found.value
                item.recipeKeyword = found.value
                item.recipeKeywordVersion = found.checked ? version : 0
            }
            result.append(IngredientInfo(name: item.name, keyword: keyword, categories: item.categoryTags,
                                         daysLeft: item.daysLeft))
        }
        return result
    }

    // MARK: - Checking names typed by hand
    // the guesses in order, then Apple's translator, then the name as it is.
    // none of them is an ingredient: keep the first guess, the recipe search can still
    // look for it in the recipe titles (pesto) or say it found nothing
    private static func checkedKeyword(for name: String, guesses: [String?]) async -> Keyword {
        let guesses = guesses.compactMap { $0 }
        let fallback = guesses.first ?? clean(name) ?? name

        guard let catalog = try? await MealDBCatalog.shared.ingredientNames(), !catalog.isEmpty else {
            return Keyword(value: fallback, checked: false)
        }
        func isIngredient(_ word: String) -> Bool {
            IngredientMatcher.bestMatch(for: word, in: catalog) != nil
        }

        if let known = guesses.first(where: isIngredient) {
            return Keyword(value: known, checked: true)
        }
        let translated = await translatedToEnglish(name)
        if let translated = clean(translated), isIngredient(translated) {
            return Keyword(value: translated, checked: true)
        }
        if let plain = clean(name), isIngredient(plain) {
            return Keyword(value: plain, checked: true)
        }
        return Keyword(value: fallback, checked: true)
    }

    // the phone's language, if it isn't english (the name is probably written in it)
    private static var userLanguage: Locale.Language? {
        let language = Locale.current.language
        guard let code = language.languageCode, code != .english else { return nil }
        return language
    }

    // Apple's translator, only if the language is already on the phone:
    // here there's no screen to ask for the download (the recipe sheet asks for it)
    private static func translatedToEnglish(_ text: String) async -> String? {
        guard let source = userLanguage else { return nil }
        let english = Locale.Language(identifier: "en")
        guard await LanguageAvailability().status(from: source, to: english) == .installed else { return nil }
        let session = TranslationSession(installedSource: source, target: english)
        return try? await session.translate(text).targetText
    }

    private static func clean(_ text: String?) -> String? {
        guard let value = text?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else { return nil }
        return value
    }

    // MARK: - Apple Intelligence (if available)
    // nil if the model isn't available or can't answer
    private static func viaFoundationModel(_ name: String, englishName: String?, categories: [String]) async -> String? {
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        let session = LanguageModelSession(instructions: """
            You look at grocery products, in any language and often with brand names, \
            and say what they are. \
            A product is never one of its ingredients: "Gallette di mais al cioccolato" are \
            chocolate corn cakes (a snack), not corn and not chocolate; "Ciobar" is a hot chocolate mix \
            (a drink), not chocolate; a protein bar with nuts is a snack, not nuts. \
            Prepared foods keep their own name: "Pesto alla genovese" is pesto, not basil. \
            Read the name in the person's language first, a word can mean something else in English: \
            in Italian "latte" is milk, not a coffee drink.
            """)
        // the database info helps a lot with brand names
        var prompt = "Product: \(name)"
        if let englishName, !englishName.isEmpty { prompt += "\nEnglish name: \(englishName)" }
        if !categories.isEmpty { prompt += "\nCategories: \(categories.suffix(4).joined(separator: ", "))" }
        if let code = userLanguage?.languageCode?.identifier,
           let language = Locale(identifier: "en").localizedString(forLanguageCode: code) {
            prompt += "\nPerson's language: \(language)"
        }

        guard let response = try? await session.respond(to: prompt, generating: ProductName.self) else { return nil }
        let value = response.content.product.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.isEmpty ? nil : value
    }

    // MARK: - Backup dictionary (first match wins, so specific words go first)
    private static let dictionary: [(it: String, en: String)] = [
        ("pesto", "pesto"), ("passata", "passata"), ("sugo", "tomato sauce"),
        ("mozzarella", "mozzarella"), ("parmigian", "parmesan"), ("prosciutto", "ham"),
        ("formaggio", "cheese"), ("ricotta", "ricotta"), ("latte", "milk"), ("uov", "eggs"),
        ("pollo", "chicken"), ("tacchino", "turkey"), ("manzo", "beef"), ("maiale", "pork"),
        ("salmone", "salmon"), ("tonno", "tuna"), ("pomodor", "tomatoes"), ("patat", "potatoes"),
        ("cipoll", "onions"), ("aglio", "garlic"), ("burro", "butter"), ("riso", "rice"),
        ("spaghetti", "spaghetti"), ("pasta", "pasta"), ("pane", "bread"), ("carot", "carrots"),
        ("zucchin", "courgettes"), ("funghi", "mushrooms"), ("spinaci", "spinach"),
        ("panna", "double cream"), ("yogurt", "yogurt"), ("limone", "lemon"),
        ("melanzan", "aubergine"), ("mela", "apple"), ("mele", "apple"), ("banan", "banana"),
        ("peperon", "pepper"), ("farina", "flour"), ("zucchero", "sugar"), ("olio", "olive oil"),
        ("miele", "honey")
    ]

    private static func dictionaryHit(_ name: String) -> String? {
        let lower = name.lowercased()
        return dictionary.first { lower.contains($0.it) }?.en
    }
}
