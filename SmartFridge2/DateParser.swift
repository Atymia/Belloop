import Foundation

// Finds the expiry date in the text the camera reads.
// Formats it understands:
//   12/05/2026  12.05.26  12-05-2026   (day/month/year)
//   2026-05-12                          (ISO)
//   05/2026  05.26                      (month/year, uses the last day)
//   12 MAY 2026  MAG 2026  12 GEN 27    (month names in IT and EN)
//   15 10 2027  15102027                (printed with dots, camera skips them)
//   15.1O.2O27                          (letters read instead of numbers)
enum DateParser {
    static func parse(_ raw: String, now: Date = .now) -> Date? {
        let upper = fixDigits(raw.uppercased())

        // dates printed with dots (milk bottles, cans) often lose the separators,
        // so check them before removing long numbers
        let spaced = upper.replacingOccurrences(of: #"(?<!\d)(\d{2})\s+(\d{2})\s+(\d{4}|\d{2})(?!\d)"#,
                                                with: "$1/$2/$3", options: .regularExpression)
        var found = compact(in: spaced, hasKeyword: hasDateKeyword(upper))

        // use / everywhere
        let text = spaced
            // remove numbers with 5+ digits (barcodes, lot numbers), a date never has them
            .replacingOccurrences(of: #"\d{5,}"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[.,:\-\\]"#, with: "/", options: .regularExpression)
        found = candidates(in: text) + found
        return found.first { isPlausible($0, now: now) }
    }

    // words usually printed near the expiry date
    private static func hasDateKeyword(_ text: String) -> Bool {
        ["SCAD", "CONSUMARSI", "ENTRO", "EXP", "BEST", "USE BY", "BB", "BBE", "DLC", "DLUO", "MHD", "CAD", "A CONSOMMER"]
            .contains { text.contains($0) }
    }

    // the camera mixes up O/0, I/1, S/5, B/8. only fix it in pieces that are
    // mostly numbers, otherwise SCAD or LOTTO would break
    private static func fixDigits(_ text: String) -> String {
        let map: [Character: Character] = ["O": "0", "Q": "0", "D": "0", "I": "1", "L": "1", "|": "1", "S": "5", "B": "8", "Z": "2"]
        return text.split(separator: " ", omittingEmptySubsequences: false).map { token -> String in
            let digits = token.filter(\.isNumber).count
            let letters = token.filter { map[$0] != nil }.count
            guard digits >= 3, letters > 0, letters <= 2, digits > letters * 2 else { return String(token) }
            return String(token.map { map[$0] ?? $0 })
        }.joined(separator: " ")
    }

    // 8 digits always ok, 6 digits only if there's SCAD/EXP nearby
    // (6 digit numbers are often lot codes)
    private static func compact(in text: String, hasKeyword: Bool) -> [Date] {
        var result: [Date] = []
        for m in matches(#"(?<!\d)(\d{2})(\d{2})(20\d{2})(?!\d)"#, in: text) {
            if let d = int(m[0]), let mo = int(m[1]), let y = int(m[2]), let date = makeDate(y, mo, d) { result.append(date) }
        }
        if hasKeyword {
            for m in matches(#"(?<!\d)(\d{2})(\d{2})(\d{2})(?!\d)"#, in: text) {
                if let d = int(m[0]), let mo = int(m[1]), let y = int(m[2]), let date = makeDate(expand(y), mo, d) { result.append(date) }
            }
        }
        return result
    }

    // ignore production dates: an expiry date can't be too far in the past
    // or more than 15 years ahead
    static func isPlausible(_ date: Date, now: Date = .now) -> Bool {
        let cal = Calendar.current
        guard let earliest = cal.date(byAdding: .day, value: -7, to: cal.startOfDay(for: now)),
              let latest = cal.date(byAdding: .year, value: 15, to: now) else { return false }
        return (earliest...latest).contains(date)
    }

    // MARK: - Regex (lookarounds so "26/05/12" isn't found inside "2026/05/12")
    private static let ymd = #"(?<!\d)(\d{4})\s*/\s*(\d{1,2})\s*/\s*(\d{1,2})(?!\d)"#
    private static let dmy = #"(?<!\d)(\d{1,2})\s*/\s*(\d{1,2})\s*/\s*(\d{4}|\d{2})(?!\d)"#
    private static let my  = #"(?<!\d)(\d{1,2})\s*/\s*(\d{4}|\d{2})(?!\d)"#
    private static let named = #"(?<!\d)(?:(\d{1,2})\s*/?\s*)?(JAN|GEN|FEB|MAR|APR|MAY|MAG|JUN|GIU|JUL|LUG|AUG|AGO|SEP|SET|OCT|OTT|NOV|DEC|DIC)[A-Z]*\s*/?\s*(\d{4}|\d{2})(?!\d)"#

    private static let months: [String: Int] = [
        "JAN": 1, "GEN": 1, "FEB": 2, "MAR": 3, "APR": 4, "MAY": 5, "MAG": 5,
        "JUN": 6, "GIU": 6, "JUL": 7, "LUG": 7, "AUG": 8, "AGO": 8,
        "SEP": 9, "SET": 9, "OCT": 10, "OTT": 10, "NOV": 11, "DEC": 12, "DIC": 12
    ]

    private static func candidates(in text: String) -> [Date] {
        var result: [Date] = []

        for m in matches(ymd, in: text) {
            if let y = int(m[0]), let mo = int(m[1]), let d = int(m[2]),
               let date = makeDate(y, mo, d) { result.append(date) }
        }
        for m in matches(dmy, in: text) {
            if let d = int(m[0]), let mo = int(m[1]), let y = int(m[2]),
               let date = makeDate(expand(y), mo, d) { result.append(date) }
        }
        for m in matches(my, in: text) {
            if let mo = int(m[0]), let y = int(m[1]),
               let date = endOfMonth(expand(y), mo) { result.append(date) }
        }
        for m in matches(named, in: text) {
            guard let key = m[1], let mo = months[key], let y = int(m[2]) else { continue }
            if let d = int(m[0]) {
                if let date = makeDate(expand(y), mo, d) { result.append(date) }
            } else if let date = endOfMonth(expand(y), mo) {
                result.append(date)
            }
        }
        return result
    }

    // MARK: - Helpers
    private static func expand(_ year: Int) -> Int { year < 100 ? year + 2000 : year }
    private static func int(_ s: String?) -> Int? { s.flatMap { Int($0) } }

    private static func makeDate(_ year: Int, _ month: Int, _ day: Int) -> Date? {
        guard (1...12).contains(month), (1...31).contains(day), (2000...2100).contains(year) else { return nil }
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        let cal = Calendar.current
        guard let date = cal.date(from: comps) else { return nil }
        // no 31/02 etc
        let check = cal.dateComponents([.year, .month, .day], from: date)
        return check.day == day && check.month == month ? date : nil
    }

    private static func endOfMonth(_ year: Int, _ month: Int) -> Date? {
        guard let first = makeDate(year, month, 1),
              let range = Calendar.current.range(of: .day, in: .month, for: first) else { return nil }
        return makeDate(year, month, range.count)
    }

    // returns every match with its groups (nil if a group is missing)
    private static func matches(_ pattern: String, in text: String) -> [[String?]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            (1..<match.numberOfRanges).map { i -> String? in
                let r = match.range(at: i)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            }
        }
    }
}
