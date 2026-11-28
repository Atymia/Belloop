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
// Apple does the translating (Apple Intelligence, or the Translation framework),
// and TheMealDB's own ingredient list says if the word is right: no word lists in our code.
// A product is never turned into one of its ingredients: "chocolate corn cakes" stay corn cakes.
// Then the recipe database decides: if no recipe uses corn cakes, they're simply not used
enum IngredientNormalizer {
    // increase this when the rules change, old keywords get recalculated
    // v2: pesto stays pesto (not basil)
    // v3: scanned products also save their OFF categories
    // v5: the model names the product itself (corn cakes, hot chocolate mix), never its ingredients
    // v6: names typed by hand are checked against TheMealDB's ingredients
    //     ("Latte" became the coffee drink and found no recipes, it's milk)
    // v7: no more italian dictionary, Apple's translator does it
    // v8: the language comes from the shop country too, not only the phone's language
    //     (a phone in English with "Latte" typed in Italian found nothing)
    static let version = 8

    struct Keyword: Sendable {
        let value: String
        // false = we couldn't check it yet (no connection, or the translator's language
        // isn't downloaded): it's worked out again next time
        let checked: Bool
    }

    // with Apple Intelligence: the model says what the product is (using the database info too).
    // without it: OFF english name, OFF category, Apple's translator, the name as is
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
        return await checkedKeyword(for: name, guesses: [viaModel, clean(englishName)])
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
    // the model's guess, then Apple's translator, then the name as it is.
    // none of them is an ingredient: keep the best guess, the recipe search can still
    // look for it in the recipe titles (pesto) or say it found nothing
    private static func checkedKeyword(for name: String, guesses: [String?]) async -> Keyword {
        let guesses = guesses.compactMap { $0 }
        let plain = clean(name) ?? name

        guard let catalog = try? await MealDBCatalog.shared.ingredientNames(), !catalog.isEmpty else {
            return Keyword(value: guesses.first ?? plain, checked: false)
        }
        func isIngredient(_ word: String) -> Bool {
            IngredientMatcher.bestMatch(for: word, in: catalog) != nil
        }

        if let known = guesses.first(where: isIngredient) {
            return Keyword(value: known, checked: true)
        }

        // "Latte" -> "milk"
        let translated = await translationsToEnglish(name)
        if let known = translated.words.first(where: isIngredient) {
            return Keyword(value: known, checked: true)
        }
        if isIngredient(plain) {
            return Keyword(value: plain, checked: true)
        }
        // if a language still has to be downloaded, try again once it's there
        return Keyword(value: guesses.first ?? translated.words.first ?? plain, checked: !translated.missing)
    }

    private static let english = Locale.Language(identifier: "en")

    // the languages names are probably typed in, all from the person's own settings:
    // the language of the shop country (Settings > Country, the phone's region by default),
    // then the phone's languages. english is left out, nothing to translate.
    // the country comes first: a phone in English in Italy still gets "Latte" from an Italian shop.
    // not the keyboards: Apple only allows reading them to adapt the keyboard UI
    // (it's a "required reason" API, and this reason isn't one of them)
    static var typingLanguages: [Locale.Language] {
        var identifiers: [String] = []
        // "IT" -> "it-Latn-IT": Apple's own table of the main language of each country
        let country = Locale.Language(identifier: "und-" + AppSettings.countryCode).maximalIdentifier
        identifiers.append(country)
        identifiers += Locale.preferredLanguages

        var seen: Set<String> = []
        return identifiers
            .map { Locale.Language(identifier: $0) }
            .filter { language in
                // real language codes only
                guard let code = language.languageCode?.identifier, code != "und", code.count <= 3,
                      language.languageCode != .english else { return false }
                return seen.insert(code).inserted
            }
    }

    // the first typing language that Apple's translator could download but hasn't yet,
    // only if some product typed by hand is still waiting for it (version 0 = not checked).
    // the recipe screen then asks for it with Apple's own sheet
    static func languageToDownload(for items: [FoodItem]) async -> Locale.Language? {
        guard items.contains(where: { $0.categoryTags.isEmpty && $0.recipeKeywordVersion == 0 }) else {
            return nil
        }
        for language in typingLanguages {
            if await LanguageAvailability().status(from: language, to: english) == .supported {
                return language
            }
        }
        return nil
    }

    // Apple's translator, from each typing language already on the phone
    // (here there's no screen to ask for a download).
    // missing = a language could still be downloaded, or the translator failed
    private static func translationsToEnglish(_ text: String) async -> (words: [String], missing: Bool) {
        var words: [String] = []
        var missing = false
        for source in typingLanguages {
            let status = await LanguageAvailability().status(from: source, to: english)
            if status == .supported { missing = true }
            guard status == .installed else { continue }
            let session = TranslationSession(installedSource: source, target: english)
            let answer = try? await session.translate(text)
            if let word = clean(answer?.targetText) {
                words.append(word)
            } else {
                missing = true
            }
        }
        return (words, missing)
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
            Read the name in the language of the shop country first, because the same word \
            can mean something else in English.
            """)
        // the database info helps a lot with brand names
        var prompt = "Product: \(name)"
        if let englishName, !englishName.isEmpty { prompt += "\nEnglish name: \(englishName)" }
        if !categories.isEmpty { prompt += "\nCategories: \(categories.suffix(4).joined(separator: ", "))" }
        // where it was bought and the languages the person types in, so "Latte" from an
        // Italian shop is read in Italian (milk) and not as the coffee drink
        let inEnglish = Locale(identifier: "en")
        if let country = inEnglish.localizedString(forRegionCode: AppSettings.countryCode) {
            prompt += "\nShop country: \(country)"
        }
        let languages = typingLanguages.compactMap { language in
            language.languageCode.flatMap { inEnglish.localizedString(forLanguageCode: $0.identifier) }
        }
        if !languages.isEmpty {
            prompt += "\nLanguages the person types in besides English: \(languages.joined(separator: ", "))"
        }

        guard let response = try? await session.respond(to: prompt, generating: ProductName.self) else { return nil }
        let value = response.content.product.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.isEmpty ? nil : value
    }
}
