import Foundation
import FoundationModels

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
    static let version = 5

    // with Apple Intelligence: the model says what the product is (using the database info too).
    // without it: OFF english name, OFF category, small dictionary, the name as is
    static func englishKeyword(for name: String, englishName: String?, categories: [String]) async -> String {
        if let viaModel = await viaFoundationModel(name, englishName: englishName, categories: categories) {
            return viaModel
        }
        if let englishName, !englishName.isEmpty { return englishName.lowercased() }
        if let category = categories.last, !category.isEmpty { return category }
        return dictionaryTranslation(name)
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
                keyword = await englishKeyword(for: item.name, englishName: english, categories: item.categoryTags)
                item.recipeKeyword = keyword
                item.recipeKeywordVersion = version
            }
            result.append(IngredientInfo(name: item.name, keyword: keyword, categories: item.categoryTags,
                                         daysLeft: item.daysLeft))
        }
        return result
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
            Prepared foods keep their own name: "Pesto alla genovese" is pesto, not basil.
            """)
        // the database info helps a lot with brand names
        var prompt = "Product: \(name)"
        if let englishName, !englishName.isEmpty { prompt += "\nEnglish name: \(englishName)" }
        if !categories.isEmpty { prompt += "\nCategories: \(categories.suffix(4).joined(separator: ", "))" }

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

    private static func dictionaryTranslation(_ name: String) -> String {
        let lower = name.lowercased()
        return dictionary.first { lower.contains($0.it) }?.en ?? lower
    }
}
