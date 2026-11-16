import Foundation
import FoundationModels

@Generable
struct EnglishIngredient {
    @Guide(description: """
        The generic food in English, lowercase, no brand and no quantity. \
        Prepared foods, sauces and spreads stay what they are: never replace them with one of their ingredients. \
        Examples: 'chicken breast', 'milk', 'tomatoes', 'parmesan', 'pesto', 'passata', 'hummus'
        """)
    var name: String
}

// "Latte Parmalat intero UHT" -> "milk", so we can search recipes in english
enum IngredientNormalizer {
    // increase this when the rules change, old keywords get recalculated
    // v2: pesto stays pesto (not basil)
    // v3: scanned products also save their OFF categories
    static let version = 3

    // tries in order: OFF english name, apple model, OFF category, small dictionary, the name as is
    static func englishKeyword(for name: String, englishName: String?, category: String?) async -> String {
        if let englishName, !englishName.isEmpty { return englishName.lowercased() }
        if let viaModel = await viaFoundationModel(name) { return viaModel }
        if let category, !category.isEmpty { return category }
        return dictionaryTranslation(name)
    }

    // finds the keyword for each item and saves it.
    // only the 8 most urgent ones, the recipe search doesn't use more
    @MainActor
    static func resolve(_ items: [FoodItem]) async -> [IngredientInfo] {
        var result: [IngredientInfo] = []
        for item in items.sorted(by: { $0.daysLeft < $1.daysLeft }).prefix(8) {
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
                keyword = await englishKeyword(for: item.name, englishName: english, category: item.categoryTags.last)
                item.recipeKeyword = keyword
                item.recipeKeywordVersion = version
            }
            result.append(IngredientInfo(name: item.name, keyword: keyword, categories: item.categoryTags,
                                         daysLeft: item.daysLeft))
        }
        return result
    }

    // MARK: - Apple Intelligence (if available)
    private static func viaFoundationModel(_ name: String) async -> String? {
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        let session = LanguageModelSession(instructions: """
            You convert grocery product names, in any language and often with brand names, \
            into the generic English food name used in recipes. Answer with the food only. \
            A prepared product keeps its own name: "Pesto alla genovese" is "pesto", not "basil"; \
            "Passata di pomodoro" is "passata", not "tomatoes".
            """)
        guard let response = try? await session.respond(to: "Product: \(name)", generating: EnglishIngredient.self) else {
            return nil
        }
        let value = response.content.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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
