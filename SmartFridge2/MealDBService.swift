import Foundation

// MARK: - Models
struct IngredientInfo: Sendable {
    let name: String   // what the user sees
    let keyword: String   // english keyword
    var categories: [String] = []   // OFF categories, from general to specific
    let daysLeft: Int

    // products expiring sooner count more
    var weight: Int {
        switch daysLeft {
        case ...0: 5
        case 1: 4
        case 2...3: 3
        default: 1
        }
    }
}

struct Recipe: Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    let imageURL: URL?
    var ingredients: [String]
    var steps: [String]
    let sourceURL: URL?
    let usedProducts: [String]   // which of the chosen products it uses
    var pantryProducts: [String] = []   // other pantry products it also uses
    let missingCount: Int   // more or less what's missing
    let complexity: Complexity   // calculated on the english text
    let area: String?   // cuisine, to mix the results
    let category: String?   // category, used for sweet/savory
}

// sweet = TheMealDB category "Dessert". I don't use the ingredients
// because desserts have salt and savory dishes can have sugar
enum RecipeType: String, CaseIterable, Identifiable, Sendable {
    case all, savory, sweet
    var id: Self { self }

    func matches(category: String?) -> Bool {
        let isDessert = category?.caseInsensitiveCompare("Dessert") == .orderedSame
        switch self {
        case .all: return true
        case .sweet: return isDessert
        case .savory: return !isDessert
        }
    }
}

// the recipes found, or why there are none
struct RecipeSearchResult: Sendable {
    enum EmptyReason: Sendable {
        case network   // no connection
        case noKnownIngredient   // no recipe uses these products
        case noneOfType   // recipes exist but not sweet/savory as chosen
    }

    var recipes: [Recipe] = []
    // products not used by any recipe, we show them so the user knows why
    var unusedProducts: [String] = []
    var emptyReason: EmptyReason? = nil
}

// difficulty, guessed from number of ingredients and steps
enum Complexity: Int, Comparable, Hashable, Sendable {
    case easy, medium, elaborate

    static func < (lhs: Complexity, rhs: Complexity) -> Bool { lhs.rawValue < rhs.rawValue }

    static func rate(ingredients: Int, characters: Int) -> Complexity {
        if ingredients <= 9 && characters <= 1000 { return .easy }
        if ingredients <= 13 && characters <= 2000 { return .medium }
        return .elaborate
    }
}

// MARK: - TheMealDB ingredient list (downloaded once)
actor MealDBCatalog {
    static let shared = MealDBCatalog()
    private var cached: [String]?
    private var cachedDesserts: Set<String>?
    // recipes per ingredient, so Refresh and Sweet/Savory don't ask the server again
    private var byIngredient: [String: [MealDBService.MealSummary]] = [:]

    func recipes(with ingredient: String) -> [MealDBService.MealSummary]? { byIngredient[ingredient] }
    func store(_ meals: [MealDBService.MealSummary], for ingredient: String) { byIngredient[ingredient] = meals }

    // ids of all desserts, also downloaded once
    func dessertIDs() async throws -> Set<String> {
        if let cachedDesserts { return cachedDesserts }
        guard let url = URL(string: "https://www.themealdb.com/api/json/v1/1/filter.php?c=Dessert") else { return [] }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }

        struct Response: Decodable {
            struct Entry: Decodable { let idMeal: String }
            let meals: [Entry]?
        }
        let ids = Set(try JSONDecoder().decode(Response.self, from: data).meals?.map(\.idMeal) ?? [])
        cachedDesserts = ids
        return ids
    }

    func ingredientNames() async throws -> [String] {
        if let cached { return cached }
        guard let url = URL(string: "https://www.themealdb.com/api/json/v1/1/list.php?i=list") else { return [] }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }

        struct Response: Decodable {
            struct Entry: Decodable { let strIngredient: String }
            let meals: [Entry]?
        }
        let names = try JSONDecoder().decode(Response.self, from: data).meals?.map(\.strIngredient) ?? []
        cached = names
        return names
    }
}

// MARK: - Matching: "whole milk" -> "Milk"
enum IngredientMatcher {
    // the keyword first, then the OFF categories (most specific first)
    static func catalogName(for info: IngredientInfo, in catalog: [String]) -> String? {
        bestMatch(for: info.keyword, in: catalog)
            ?? info.categories.reversed().lazy.compactMap { categoryMatch(for: $0, in: catalog) }.first
    }

    private static let stopwords: Set<String> = ["of", "and", "the", "with", "in", "a", "for"]

    private struct Entry { let name: String; let tokens: Set<String> }

    static func bestMatch(for keyword: String, in catalog: [String]) -> String? {
        let entries = catalog.map { Entry(name: $0, tokens: Set(orderedTokens($0))) }

        // exact match
        let full = Set(orderedTokens(keyword))
        if !full.isEmpty, let exact = entries.first(where: { $0.tokens == full }) { return exact.name }

        // "hazelnut spread with cocoa" is a spread, so only the first part counts
        let ordered = orderedTokens(mainPart(of: keyword))
        let key = Set(ordered)
        guard let head = ordered.last else { return nil }

        // same words
        if let exact = entries.first(where: { $0.tokens == key }) { return exact.name }
        // keyword contains the ingredient ("whole milk" has "milk"), longest one wins.
        // it has to be the last word though: "whole milk" -> milk is fine
        // but "basil pesto" -> basil is wrong, pesto isn't basil
        let inside = entries.filter { !$0.tokens.isEmpty && $0.tokens.isSubset(of: key) && $0.tokens.contains(head) }
        if let best = inside.max(by: { $0.tokens.count < $1.tokens.count }) { return best.name }
        // ingredient contains the keyword ("chicken" in "chicken breast"), shortest wins
        let containing = entries.filter { key.isSubset(of: $0.tokens) }
        return containing.min(by: { $0.tokens.count < $1.tokens.count })?.name
        // nothing found: better to skip the product than use a wrong one
    }

    private static func mainPart(of keyword: String) -> String {
        var text = " " + keyword.lowercased() + " "
        // don't split on "and": "cocoa and hazelnut spread" is still a spread
        for separator in [" with ", " in ", ",", "(", " - ", " – "] {
            if let range = text.range(of: separator) { text = String(text[..<range.lowerBound]) + " " }
        }
        return text
    }

    // for OFF categories: an exact match, or a one-word category inside a longer ingredient
    // ("digestives" -> "Digestive Biscuits").
    // nothing looser: categories are too broad to guess from (Ciobar is filed under "cocoa powders",
    // chocolate corn cakes under "cereals", but you can't cook with them like that)
    static func categoryMatch(for category: String, in catalog: [String]) -> String? {
        let ordered = orderedTokens(mainPart(of: category))
        let key = Set(ordered)
        guard !key.isEmpty else { return nil }
        let entries = catalog.map { Entry(name: $0, tokens: Set(orderedTokens($0))) }
        if let exact = entries.first(where: { $0.tokens == key }) { return exact.name }
        guard ordered.count == 1 else { return nil }
        return entries.filter { key.isSubset(of: $0.tokens) }.min(by: { $0.tokens.count < $1.tokens.count })?.name
    }

    // MARK: Pasta
    // In TheMealDB every pasta shape is its own ingredient (Rigatoni, Penne Rigate, Spaghetti...)
    // with only a few recipes each, so "Rigatoni De Cecco" found nothing savory.
    // But a carbonara works with rigatoni or bucatini, so pasta looks at TheMealDB's whole
    // "Pasta" category. Both sides come from the databases, no word lists in the code:
    // Open Food Facts puts every pasta product in "Pastas" (pasta sauces are in another category)
    static func isPasta(_ info: IngredientInfo) -> Bool {
        info.categories.contains("pastas")
    }

    // same words only ("rigatoni" -> "Rigatoni"), nothing looser
    static func exactMatch(for keyword: String, in catalog: [String]) -> String? {
        let key = Set(orderedTokens(keyword))
        guard !key.isEmpty else { return nil }
        return catalog.first { Set(orderedTokens($0)) == key }
    }

    // if it's not an ingredient, maybe we can find it in recipe titles
    static func titleTerm(keyword: String) -> String? {
        // only one word like pesto or tahini: two words matched random titles
        let words = orderedTokens(keyword)
        guard words.count == 1, keyword.count >= 4 else { return nil }
        return keyword
    }

    private static func orderedTokens(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
            .filter { $0.count > 1 && !stopwords.contains($0) }
            .map(stem)
    }

    // simple plural -> singular (eggs, tomatoes, berries)
    private static func stem(_ word: String) -> String {
        if word.hasSuffix("ies"), word.count > 4 { return String(word.dropLast(3)) + "y" }
        if word.hasSuffix("oes") { return String(word.dropLast(2)) }
        if word.hasSuffix("s"), !word.hasSuffix("ss") { return String(word.dropLast()) }
        return word
    }
}

// MARK: - TheMealDB
// NOTE: key "1" is only for testing, for the App Store we need the paid supporter key
// (it also lets you filter by more ingredients at once)
enum MealDBService {
    // TODO: change before release
    private static let apiKey = "1"
    private static let base = "https://www.themealdb.com/api/json/v1/\(apiKey)"

    struct MealSummary: Decodable, Hashable, Sendable {
        let idMeal: String
        let strMeal: String
    }
    private struct FilterResponse: Decodable { let meals: [MealSummary]? }
    private struct LookupResponse: Decodable { let meals: [[String: String?]]? }

    // Finds recipes for the chosen products.
    // A recipe must use at least one chosen product (that's the main focus).
    // Then it gets extra points if it also uses other things in the pantry,
    // and loses points for every ingredient the user would have to buy.
    // Recipes already shown are skipped so Refresh gives new ones.
    static func recipes(for ingredients: [IngredientInfo], pantry: [IngredientInfo] = [],
                        type: RecipeType = .all,
                        excluding shown: Set<String> = [], limit: Int = 8) async -> RecipeSearchResult {
        guard let catalog = try? await MealDBCatalog.shared.ingredientNames(), !catalog.isEmpty else {
            return RecipeSearchResult(emptyReason: .network)
        }

        // 1. find the TheMealDB ingredient for each chosen product,
        // and if nothing works, search the word in recipe titles
        var groups: [String: [IngredientInfo]] = [:]
        var pending: [Lookup] = []
        var unused: [String] = []
        for info in ingredients.sorted(by: { $0.weight > $1.weight }).prefix(8) {
            if IngredientMatcher.isPasta(info) {
                // the whole Pasta category, and the recipe must have some kind of pasta in it
                pending.append(Lookup(infos: [info], category: pastaCategory))
                // the exact shape too, it can find recipes filed under Beef or Seafood
                if let shape = IngredientMatcher.exactMatch(for: info.keyword, in: catalog) {
                    groups[shape, default: []].append(info)
                }
            } else if let match = IngredientMatcher.catalogName(for: info, in: catalog) {
                groups[match, default: []].append(info)
            } else if let term = IngredientMatcher.titleTerm(keyword: info.keyword) {
                pending.append(Lookup(infos: [info], ingredient: nil, title: term))
            } else {
                unused.append(info.name)
            }
        }
        let lookups = pending + groups.map { Lookup(infos: $0.value, ingredient: $0.key, title: nil) }
        guard !lookups.isEmpty else {
            return RecipeSearchResult(unusedProducts: unused, emptyReason: .noKnownIngredient)
        }

        // the rest of the pantry: only products that are real TheMealDB ingredients,
        // the most urgent first, max 12 so we don't send too many requests
        var pantryGroups: [String: [String]] = [:]   // ingredient -> product names
        let choosingPasta = lookups.contains { $0.category == pastaCategory }
        for info in pantry.sorted(by: { $0.weight > $1.weight }) {
            if IngredientMatcher.isPasta(info) {
                if !choosingPasta { pantryGroups[pastaKey, default: []].append(info.name) }
                continue
            }
            guard let match = IngredientMatcher.catalogName(for: info, in: catalog), groups[match] == nil else { continue }
            guard pantryGroups[match] != nil || pantryGroups.count < 12 else { continue }
            pantryGroups[match, default: []].append(info.name)
        }

        // 2. one request per ingredient, all at the same time (free key = 1 ingredient per request).
        // nil = request failed, [] = no recipes
        async let selectedAnswers = fetch(lookups)
        async let pantryAnswers = fetchPantry(Array(pantryGroups.keys))
        let answers = await selectedAnswers
        let pantryLists = await pantryAnswers

        // which pantry ingredients each recipe uses
        var pantryHits: [String: Set<String>] = [:]
        for (ingredient, ids) in pantryLists {
            for id in ids { pantryHits[id, default: []].insert(ingredient) }
        }

        // 3. score
        var scored: [String: Scored] = [:]
        var failedRequests = 0
        // a product can have two searches (Pasta + Rigatoni): it's unused only if both found nothing
        var answered: Set<String> = []
        var found: Set<String> = []
        for (index, meals) in answers {
            let lookup = lookups[index]
            guard let meals else { failedRequests += 1; continue }
            answered.formUnion(lookup.infos.map(\.name))
            if !meals.isEmpty { found.formUnion(lookup.infos.map(\.name)) }
            for meal in meals {
                var entry = scored[meal.idMeal, default: Scored()]
                // once per product, even if two searches found the same recipe (Pasta + Rigatoni)
                for info in lookup.infos where !entry.used.contains(info.name) {
                    entry.score += info.weight
                    entry.used.insert(info.name)
                }
                let key = lookup.ingredient ?? lookup.title ?? lookup.category ?? ""
                entry.have.insert(key)
                if let category = lookup.category {
                    entry.chosenCategories.insert(category)
                } else {
                    entry.chosenKeys.insert(key)
                    entry.exact = true   // TheMealDB lists the product itself (Rigatoni), not just its category
                }
                scored[meal.idMeal] = entry
            }
        }
        unused.append(contentsOf: answered.subtracting(found).sorted())
        for id in scored.keys {
            guard let hits = pantryHits[id] else { continue }
            scored[id]?.have.formUnion(hits)
            scored[id]?.pantry = Set(hits.flatMap { pantryGroups[$0] ?? [] })
        }
        let finalScores = scored
        var all = finalScores.map { Candidate(id: $0.key, scored: $0.value) }
        guard !all.isEmpty else {
            let reason: RecipeSearchResult.EmptyReason = failedRequests == answers.count ? .network : .noKnownIngredient
            return RecipeSearchResult(unusedProducts: unused, emptyReason: reason)
        }

        // sweet/savory filter before downloading details, with the dessert ids.
        // if that list fails we filter later by category
        if type != .all, let desserts = try? await MealDBCatalog.shared.dessertIDs() {
            all = all.filter { desserts.contains($0.id) == (type == .sweet) }
        }
        guard !all.isEmpty else {
            return RecipeSearchResult(unusedProducts: unused, emptyReason: .noneOfType)
        }

        // 4. random pick, but higher score = more chances. so Refresh is always different.
        // take 3x so mix() can drop the complicated ones. old recipes only if there aren't enough new ones
        // recipes with the exact product (Rigatoni) are picked first, then the rest of the category (Pasta)
        let wanted = limit * 3
        func pick(_ pool: [Candidate], count: Int) -> [Candidate] {
            let exact = weightedSample(pool.filter(\.scored.exact), count: count)
            return exact + weightedSample(pool.filter { !$0.scored.exact }, count: count - exact.count)
        }
        var picked = pick(all.filter { !shown.contains($0.id) }, count: wanted)
        if picked.count < limit {
            picked += pick(all.filter { shown.contains($0.id) }, count: wanted - picked.count)
        }
        let candidates = picked

        let details = await withTaskGroup(of: Recipe?.self, returning: [Recipe].self) { group in
            for candidate in candidates {
                let scored = candidate.scored
                group.addTask {
                    guard let recipe = try? await detail(id: candidate.id, used: scored.used.sorted(),
                                                         pantry: scored.pantry.sorted(), haveCount: scored.have.count)
                    else { return nil }
                    // double check: the recipe really has the chosen product in it
                    // a recipe from the Pasta category is a pasta dish, TheMealDB says so
                    if let category = recipe.category, scored.chosenCategories.contains(category) { return recipe }
                    return uses(recipe, any: scored.chosenKeys) ? recipe : nil
                }
            }
            var out: [Recipe] = []
            for await recipe in group { if let recipe { out.append(recipe) } }
            return out
        }

        // 5. mix and sort
        let matching = details.filter { type.matches(category: $0.category) }
        let exactIDs = Set(finalScores.filter { $0.value.exact }.keys)
        let recipes = mix(matching, scores: finalScores.mapValues(\.score), exact: exactIDs, limit: limit)
        guard !recipes.isEmpty else {
            return RecipeSearchResult(unusedProducts: unused,
                                      emptyReason: details.isEmpty ? .network : .noneOfType)
        }
        return RecipeSearchResult(recipes: recipes, unusedProducts: unused)
    }

    // search by ingredient, or by title if that's all we have
    private struct Lookup: Sendable {
        let infos: [IngredientInfo]
        var ingredient: String? = nil
        var title: String? = nil
        var category: String? = nil
    }

    private static let pastaCategory = "Pasta"
    // pantry key for "any pasta"
    private static let pastaKey = "category:Pasta"

    private static func fetch(_ lookups: [Lookup]) async -> [(Int, [MealSummary]?)] {
        await withTaskGroup(of: (Int, [MealSummary]?).self, returning: [(Int, [MealSummary]?)].self) { group in
            for (index, lookup) in lookups.enumerated() {
                group.addTask {
                    if let ingredient = lookup.ingredient {
                        return (index, try? await search(ingredient: ingredient))
                    }
                    if let title = lookup.title {
                        return (index, try? await search(title: title))
                    }
                    if let category = lookup.category {
                        return (index, try? await search(category: category))
                    }
                    return (index, [])
                }
            }
            var all: [(Int, [MealSummary]?)] = []
            for await entry in group { all.append(entry) }
            return all
        }
    }

    // recipe ids for each pantry ingredient (a failed request just counts as none)
    private static func fetchPantry(_ ingredients: [String]) async -> [String: Set<String>] {
        await withTaskGroup(of: (String, Set<String>).self, returning: [String: Set<String>].self) { group in
            for ingredient in ingredients {
                group.addTask {
                    let meals: [MealSummary]
                    if ingredient == pastaKey {
                        meals = (try? await search(category: pastaCategory)) ?? []
                    } else {
                        meals = (try? await search(ingredient: ingredient)) ?? []
                    }
                    return (ingredient, Set(meals.map(\.idMeal)))
                }
            }
            var all: [String: Set<String>] = [:]
            for await (ingredient, ids) in group { all[ingredient] = ids }
            return all
        }
    }

    // MARK: Random pick + mix
    private struct Scored: Sendable {
        var score = 0                  // weights of the chosen products it uses
        var used: Set<String> = []     // chosen products it uses
        var pantry: Set<String> = []   // other pantry products it uses
        var have: Set<String> = []     // its ingredients the user already has
        var chosenKeys: Set<String> = []   // the ingredient names (or title words) it was found with
        var chosenCategories: Set<String> = []   // or the TheMealDB category (Pasta)
        var exact = false   // found by the product itself, these go first
    }

    // true if one of the keys is in the recipe's ingredients or title (English text, before translation)
    private static func uses(_ recipe: Recipe, any keys: Set<String>) -> Bool {
        let ingredients = recipe.ingredients.joined(separator: " | ").lowercased()
        let title = recipe.title.lowercased()
        return keys.contains { key in
            let k = key.lowercased()
            return !k.isEmpty && (ingredients.contains(k) || title.contains(k))
        }
    }
    private struct Candidate: Sendable { let id: String; let scored: Scored }

    // weighted random sampling (Efraimidis-Spirakis, found it online):
    // key = u^(1/w), highest keys win. chosen products count double, pantry ones help a bit
    private static func weightedSample(_ candidates: [Candidate], count: Int) -> [Candidate] {
        guard count > 0 else { return [] }
        return candidates
            .map { candidate -> (Candidate, Double) in
                let points = Double(candidate.scored.score * 2 + candidate.scored.pantry.count)
                let weight = max(1, points * points)
                return (candidate, pow(Double.random(in: 0.000_001...1), 1 / weight))
            }
            .sorted { $0.1 > $1.1 }
            .prefix(count)
            .map(\.0)
    }

    // ranking: chosen products matter most, then other pantry products,
    // and every ingredient to buy costs a point. elaborate recipes only if nothing else is left.
    // max 2 per cuisine so the list isn't all Italian
    private static func mix(_ recipes: [Recipe], scores: [String: Int], exact: Set<String>, limit: Int) -> [Recipe] {
        func fit(_ recipe: Recipe) -> Int {
            5 * (scores[recipe.id] ?? 0) + 2 * recipe.pantryProducts.count - recipe.missingCount
        }
        func better(_ a: Recipe, _ b: Recipe) -> Bool {
            // recipes with the exact product on top, then the others (any pasta)
            let ea = exact.contains(a.id), eb = exact.contains(b.id)
            if ea != eb { return ea }
            let fa = fit(a), fb = fit(b)
            if fa != fb { return fa > fb }
            if a.complexity != b.complexity { return a.complexity < b.complexity }   // then easier
            return a.missingCount < b.missingCount   // then less to buy
        }
        let byPriority = recipes.sorted(by: better)

        var chosen: [Recipe] = []
        var perArea: [String: Int] = [:]
        for recipe in byPriority where chosen.count < limit && recipe.complexity != .elaborate {
            let areaCount = recipe.area.map { perArea[$0, default: 0] } ?? 0
            guard areaCount < 2 else { continue }
            chosen.append(recipe)
            if let area = recipe.area { perArea[area, default: 0] += 1 }
        }
        // not enough simple ones: fill with the best of what's left
        for recipe in byPriority where chosen.count < limit && !chosen.contains(recipe) {
            chosen.append(recipe)
        }
        return chosen.sorted(by: better)
    }

    // MARK: Endpoints
    static func search(ingredient: String) async throws -> [MealSummary] {
        let formatted = ingredient.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")
        if let saved = await MealDBCatalog.shared.recipes(with: formatted) { return saved }
        guard let encoded = formatted.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(base)/filter.php?i=\(encoded)") else { return [] }
        let data = try await fetch(url)
        // when there are no results the API returns something weird, so just empty
        let meals = (try? JSONDecoder().decode(FilterResponse.self, from: data))?.meals ?? []
        await MealDBCatalog.shared.store(meals, for: formatted)
        return meals
    }

    // all the recipes of a category, e.g. Pasta (saved like the ingredients)
    static func search(category: String) async throws -> [MealSummary] {
        let cacheKey = "category:" + category.lowercased()
        if let saved = await MealDBCatalog.shared.recipes(with: cacheKey) { return saved }
        guard var comps = URLComponents(string: "\(base)/filter.php") else { return [] }
        comps.queryItems = [URLQueryItem(name: "c", value: category)]
        guard let url = comps.url else { return [] }
        let data = try await fetch(url)
        let meals = (try? JSONDecoder().decode(FilterResponse.self, from: data))?.meals ?? []
        await MealDBCatalog.shared.store(meals, for: cacheKey)
        return meals
    }

    // recipes with the word in the title
    static func search(title: String) async throws -> [MealSummary] {
        guard var comps = URLComponents(string: "\(base)/search.php") else { return [] }
        comps.queryItems = [URLQueryItem(name: "s", value: title)]
        guard let url = comps.url else { return [] }
        let data = try await fetch(url)
        return (try? JSONDecoder().decode(FilterResponse.self, from: data))?.meals ?? []
    }

    static func detail(id: String, used: [String], pantry: [String] = [], haveCount: Int = 0) async throws -> Recipe? {
        guard let url = URL(string: "\(base)/lookup.php?i=\(id)") else { return nil }
        let data = try await fetch(url)
        guard let meal = try JSONDecoder().decode(LookupResponse.self, from: data).meals?.first else { return nil }

        func value(_ key: String) -> String? {
            guard let raw = meal[key] ?? nil else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        var ingredients: [String] = []
        for i in 1...20 {
            guard let ingredient = value("strIngredient\(i)") else { continue }
            let measure = value("strMeasure\(i)") ?? ""
            ingredients.append("\(measure) \(ingredient)".trimmingCharacters(in: .whitespaces))
        }

        let stepList = steps(from: value("strInstructions") ?? "")

        return Recipe(
            id: id,
            title: value("strMeal") ?? "",
            imageURL: value("strMealThumb").flatMap(URL.init(string:)),
            ingredients: ingredients,
            steps: stepList,
            sourceURL: (value("strSource") ?? value("strYoutube")).flatMap(URL.init(string:)),
            usedProducts: used,
            pantryProducts: pantry,
            missingCount: max(0, ingredients.count - max(haveCount, used.count)),
            complexity: .rate(ingredients: ingredients.count, characters: stepList.joined().count),
            area: value("strArea").flatMap { $0.caseInsensitiveCompare("Unknown") == .orderedSame ? nil : $0 },
            category: value("strCategory")
        )
    }

    // MARK: Helpers
    private static func fetch(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    // split the instructions into steps and remove lines like "STEP 1"
    private static func steps(from text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                !line.isEmpty &&
                line.range(of: #"^(step\s*)?\d+[.:)]?$"#, options: [.regularExpression, .caseInsensitive]) == nil
            }
    }
}
