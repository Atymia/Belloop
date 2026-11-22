import Foundation

// only the product info we actually use
struct OFFProduct: Identifiable, Sendable {
    let barcode: String?
    let name: String   // in the phone language if there is one
    let brand: String?
    let imageURL: URL?
    let englishName: String?   // english name if available
    // e.g. ["dairies", "milks", "semi skimmed milks"]
    let categories: [String]
    var category: String? { categories.last }

    var id: String { barcode ?? name }

    var displayName: String {
        guard let brand, !name.localizedCaseInsensitiveContains(brand) else { return name }
        return "\(name) – \(brand)"
    }
}

enum OFFSearchError: Error {
    // too many searches in a minute
    case rateLimited
}

// Open Food Facts: free database, no API key.
// works with barcode or text, NOT with photos.
// limits per device: 15 barcode lookups/min and 10 searches/min.
// they want a User-Agent like "AppName/Version (contact)".
// we have to credit them in the app (ODbL / CC BY-SA)
enum OpenFoodFactsService {
    // uses the app name, so if we rename the app it updates by itself
    private static let userAgent: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? "App"
        let version = (info["CFBundleShortVersionString"] as? String) ?? "1.0"
        return "\(name)/\(version) (Apple Developer Academy project)"
    }()

    private static var language: String {
        Locale.current.language.languageCode?.identifier ?? "en"
    }

    private static func fields(_ lang: String) -> String {
        ["code", "product_name", "generic_name", "brands", "image_front_small_url", "categories_tags",
         "product_name_\(lang)", "generic_name_\(lang)", "product_name_en", "generic_name_en"]
            .joined(separator: ",")
    }

    // MARK: Barcode
    static func product(for barcode: String) async throws -> OFFProduct? {
        let lang = language
        guard var comps = URLComponents(string: "https://world.openfoodfacts.org/api/v2/product/\(barcode).json") else { return nil }
        comps.queryItems = [URLQueryItem(name: "fields", value: fields(lang))]
        guard let url = comps.url else { return nil }

        let data = try await get(url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["status"] as? Int) == 1,
              let dict = root["product"] as? [String: Any] else { return nil }
        return parse(dict, lang: lang, fallbackCode: barcode)
    }

    // MARK: Text search (old endpoint, v2 doesn't have it)
    // the server searches everywhere in the product, so "burro" was giving
    // chocolate (cocoa butter lol). so I filter: every word has to be
    // at the start of a word in the name or brand
    static func search(_ query: String) async throws -> [OFFProduct] {
        let key = fold(query)
        let words = key.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !words.isEmpty else { return [] }
        if let hit = await searchGuard.cached(key) { return hit }

        // first the user's country, then everywhere
        let region = AppSettings.countryCode.lowercased()
        let country = region.count == 2 && region.allSatisfy(\.isLetter)
            ? (region == "gb" ? "uk" : region)   // OFF uses uk instead of gb
            : "world"

        var results = try await request(query, words: words, host: country)
        if results.isEmpty && country != "world" {
            // if this fails too show nothing, but don't cache it
            guard let world = try? await request(query, words: words, host: "world") else { return [] }
            results = world
        }
        // an empty answer isn't saved, so typing the same thing again asks the server again
        // (before, one bad answer stuck until the app was closed)
        if !results.isEmpty { await searchGuard.store(results, for: key) }
        return results
    }

    private static func request(_ query: String, words: [String], host: String) async throws -> [OFFProduct] {
        // too many searches in the last minute: wait for a free slot instead of giving up.
        // if the user keeps typing this task is cancelled, so only the latest search waits
        try await waitForSlot()

        let lang = language
        guard var comps = URLComponents(string: "https://\(host).openfoodfacts.org/cgi/search.pl") else { return [] }
        comps.queryItems = [
            URLQueryItem(name: "search_terms", value: query),
            URLQueryItem(name: "search_simple", value: "1"),
            URLQueryItem(name: "sort_by", value: "unique_scans_n"),
            URLQueryItem(name: "action", value: "process"),
            URLQueryItem(name: "json", value: "1"),
            URLQueryItem(name: "page_size", value: "30"),   // ask for more since we filter a lot
            URLQueryItem(name: "fields", value: fields(lang))
        ]
        guard let url = comps.url else { return [] }

        let data: Data
        do {
            data = try await get(url)
        } catch let error as URLError where [.timedOut, .badServerResponse, .networkConnectionLost].contains(error.code) {
            // the search server is often slow or busy (timeout or 5xx), and the next try usually works:
            // wait a second and try once more before telling the user
            try await Task.sleep(for: .seconds(1))
            try await waitForSlot()
            data = try await get(url)
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["products"] as? [[String: Any]] else { return [] }

        var seen = Set<String>()
        let matching = list
            .filter { rawNameMatches($0, words: words, lang: lang) }
            .compactMap { parse($0, lang: lang, fallbackCode: nil) }
            .filter { seen.insert($0.displayName.lowercased()).inserted }   // no duplicates

        // names starting with the text first, then by popularity
        let first = words[0]
        return matching.enumerated()
            .sorted { a, b in
                let aStarts = fold(a.element.name).hasPrefix(first)
                let bStarts = fold(b.element.name).hasPrefix(first)
                return aStarts == bStarts ? a.offset < b.offset : aStarts
            }
            .prefix(6)
            .map(\.element)
    }

    // checks ALL the names of the product (italian, english, generic) + brand,
    // so "chocolate" also finds a product whose italian name is "Cioccolato fondente"
    private static func rawNameMatches(_ p: [String: Any], words: [String], lang: String) -> Bool {
        let keys = ["product_name", "product_name_\(lang)", "product_name_en", "generic_name",
                    "generic_name_\(lang)", "generic_name_en", "brands"]
        let text = keys.compactMap { p[$0] as? String }.joined(separator: " ")
        let nameWords = fold(text).split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return words.allSatisfy { word in nameWords.contains { $0.hasPrefix(word) } }
    }

    // sleeps until the guard allows one more request (throws if the search was cancelled)
    private static func waitForSlot() async throws {
        while true {
            let wait = await searchGuard.reserve()
            if wait <= 0 { return }
            try await Task.sleep(for: .seconds(wait))
        }
    }

    // lowercase without accents
    private static func fold(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased()
    }

    private static let searchGuard = SearchGuard()

    private actor SearchGuard {
        private var cache: [String: [OFFProduct]] = [:]
        private var requests: [Date] = []

        func cached(_ key: String) -> [OFFProduct]? { cache[key] }
        func store(_ value: [OFFProduct], for key: String) { cache[key] = value }

        // max ~10 searches/min, I keep it a bit lower.
        // returns 0 if we can go now (and counts it), otherwise how many seconds to wait
        func reserve() -> TimeInterval {
            let now = Date()
            requests = requests.filter { now.timeIntervalSince($0) < 60 }
            guard requests.count >= 8, let oldest = requests.first else {
                requests.append(now)
                return 0
            }
            return 60 - now.timeIntervalSince(oldest) + 0.2
        }
    }

    // MARK: Network
    private static func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12   // search can be slow, don't wait forever
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")   // OFF wants this
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode
        if status == 404 { return Data("{}".utf8) }
        if status == 429 { throw OFFSearchError.rateLimited }   // 429 = too many requests
        guard status == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    private static func parse(_ p: [String: Any], lang: String, fallbackCode: String?) -> OFFProduct? {
        func string(_ key: String) -> String? {
            guard let value = (p[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return nil }
            return value
        }

        // phone language, then product language, then english
        guard let name = string("product_name_\(lang)") ?? string("generic_name_\(lang)")
                ?? string("product_name") ?? string("generic_name") ?? string("product_name_en")
        else { return nil }

        let brand = string("brands")?
            .split(separator: ",").first
            .map { String($0).trimmingCharacters(in: .whitespaces) }

        // tags are like "en:semi-skimmed-milks"
        let categories = ((p["categories_tags"] as? [String]) ?? [])
            .filter { $0.hasPrefix("en:") }
            .map { String($0.dropFirst(3)).replacingOccurrences(of: "-", with: " ") }

        return OFFProduct(
            barcode: string("code") ?? fallbackCode,
            name: name,
            brand: brand,
            imageURL: string("image_front_small_url").flatMap(URL.init(string:)),
            englishName: string("generic_name_en") ?? string("product_name_en"),
            categories: categories
        )
    }
}
