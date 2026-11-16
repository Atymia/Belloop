import Translation

// TheMealDB is only in english so I translate with the Translation framework
// (the first time iOS asks to download the language)
enum RecipeTranslator {
    static func translate(_ recipes: [Recipe], using session: TranslationSession) async throws -> [Recipe] {
        // put all the texts in one list: title, ingredients, steps
        var texts: [String] = []
        for recipe in recipes {
            texts.append(recipe.title)
            texts.append(contentsOf: recipe.ingredients)
            texts.append(contentsOf: recipe.steps)
        }
        guard !texts.isEmpty else { return recipes }

        let requests = texts.enumerated().map {
            TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset))
        }
        let responses = try await session.translations(from: requests)

        var byIndex: [Int: String] = [:]
        for response in responses {
            if let id = response.clientIdentifier, let index = Int(id) { byIndex[index] = response.targetText }
        }

        // then put them back in the same order
        var cursor = 0
        func next() -> String {
            defer { cursor += 1 }
            return byIndex[cursor] ?? texts[cursor]   // if it fails keep the english
        }
        return recipes.map { recipe in
            var copy = recipe
            copy.title = next()
            copy.ingredients = recipe.ingredients.map { _ in next() }
            copy.steps = recipe.steps.map { _ in next() }
            return copy
        }
    }
}
