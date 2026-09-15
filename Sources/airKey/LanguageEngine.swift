import CoreGraphics
import Foundation

enum TypingLanguage: String, CaseIterable, Identifiable, Sendable {
    case spanish = "es"
    case english = "en"
    var id: String { rawValue }
    var title: String { self == .spanish ? "Español" : "English" }
}

struct WordEntry: Sendable {
    let word: String
    let frequency: Int
    let letters: [Character]
    init(word: String, frequency: Int) {
        self.word = word
        self.frequency = frequency
        self.letters = Array(Self.keyboardForm(word))
    }

    /// Accented vowels use the base key; ñ remains a distinct key.
    static func keyboardForm(_ text: String) -> String {
        text.lowercased().map { character in
            if character == "ñ" { return "ñ" }
            return String(character).folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        }.joined().filter { $0.isLetter }
    }
}

struct SwipeCandidate: Sendable {
    let word: String
    let score: CGFloat
    let geometryScore: CGFloat
}

struct SwipeDecoder {
    struct Template: Sendable {
        let entry: WordEntry
        let points: [CGPoint]
        let length: CGFloat
    }
    let templates: [Template]
    let keyWidth: CGFloat

    init(entries: [WordEntry], centers: [Character: CGPoint], keyWidth: CGFloat) {
        self.keyWidth = max(1, keyWidth)
        templates = entries.compactMap { entry in
            guard entry.letters.count >= 2 else { return nil }
            var points: [CGPoint] = []
            for letter in entry.letters {
                guard let point = centers[letter] else { return nil }
                if points.last != point { points.append(point) }
            }
            guard points.count >= 2 else { return nil }
            return Template(entry: entry, points: Self.resample(points, count: 32), length: Self.length(points))
        }
    }

    func decode(_ path: [CGPoint], context: [String] = [], limit: Int = 4,
                personal: LearnedLanguage = LearnedLanguage(), previous: String? = nil, panel: CGRect? = nil) -> [SwipeCandidate] {
        guard path.count >= 3, path.allSatisfy(\.isFinite), Self.length(path) > keyWidth * 0.6 else { return [] }
        let sampled = Self.resample(path, count: 32)
        let start = sampled[0], end = sampled[sampled.count - 1]
        let length = Self.length(path)
        // Endpoints and a cheap equal-distance score prune before the more expensive DTW pass.
        let shortlist: [(Template, CGFloat)] = templates.compactMap { template in
            let first = template.points[0], last = template.points[template.points.count - 1]
            guard start.distance(to: first) < keyWidth * 1.45,
                  end.distance(to: last) < keyWidth * 1.45,
                  length / template.length > 0.35, length / template.length < 2.8 else { return nil }
            let rough = zip(sampled, template.points).reduce(CGFloat(0)) { $0 + $1.0.distance(to: $1.1) } / 32
            return (template, rough)
        }.sorted { $0.1 < $1.1 }.prefix(160).map { $0 }
        if Task.isCancelled { return [] }
        let maxFrequency = CGFloat(templates.map(\.entry.frequency).max() ?? 1)
        return shortlist.map { template, _ in
            let endpoint = (start.distance(to: template.points[0]) + end.distance(to: template.points[31])) / (2 * keyWidth)
            let shape = Self.dtw(sampled, template.points) / keyWidth
            let lengthPenalty = abs(log(max(0.001, length / template.length)))
            let geometry = shape * 0.68 + endpoint * 0.27 + lengthPenalty * 0.05
            let rarity = log(maxFrequency / CGFloat(max(1, template.entry.frequency))) * 0.012
            let contextBoost: CGFloat = context.contains(template.entry.word) ? 0.075 : 0
            let personalBoost = personal.boost(for: template.entry.word, previous: previous)
            var exampleBoost: CGFloat = 0
            if let panel, panel.width > 0, panel.height > 0 {
                for example in personal.swipes where example.word == template.entry.word {
                    let learnedPath = example.points.map {
                        CGPoint(x: panel.minX + $0.x * panel.width, y: panel.minY + $0.y * panel.height)
                    }
                    guard learnedPath.count == 32 else { continue }
                    let distance = Self.dtw(sampled, learnedPath) / keyWidth
                    exampleBoost = max(exampleBoost, max(0, 0.16 * (1 - distance / 0.5)))
                }
            }
            return SwipeCandidate(word: template.entry.word,
                                  score: geometry + rarity - contextBoost - personalBoost - exampleBoost,
                                  geometryScore: geometry)
        }.filter { $0.geometryScore < 0.95 }.sorted {
            $0.score == $1.score ? $0.word < $1.word : $0.score < $1.score
        }.prefix(limit).map { $0 }
    }

    static func length(_ points: [CGPoint]) -> CGFloat {
        zip(points, points.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
    }

    static func resample(_ points: [CGPoint], count: Int) -> [CGPoint] {
        guard let first = points.first, count > 1 else { return points }
        let total = length(points)
        guard total > 0.001 else { return Array(repeating: first, count: count) }
        var distances: [CGFloat] = [0]
        for (a, b) in zip(points, points.dropFirst()) { distances.append(distances.last! + a.distance(to: b)) }
        var segment = 1
        return (0..<count).map { index in
            let target = total * CGFloat(index) / CGFloat(count - 1)
            while segment < points.count - 1 && distances[segment] < target { segment += 1 }
            let start = distances[segment - 1]
            let fraction = (target - start) / max(0.0001, distances[segment] - start)
            return points[segment - 1].interpolated(to: points[segment], fraction: min(1, max(0, fraction)))
        }
    }

    private static func dtw(_ a: [CGPoint], _ b: [CGPoint]) -> CGFloat {
        var previous = Array(repeating: CGFloat.infinity, count: b.count + 1)
        previous[0] = 0
        for i in 1...a.count {
            var current = Array(repeating: CGFloat.infinity, count: b.count + 1)
            for j in max(1, i - 8)...min(b.count, i + 8) {
                current[j] = a[i - 1].distance(to: b[j - 1]) + min(previous[j], current[j - 1], previous[j - 1])
            }
            previous = current
        }
        return previous[b.count] / CGFloat(max(a.count, b.count))
    }
}

/// All dictionary work runs away from the main actor and camera queue; nothing is sent online.
actor LanguageEngine {
    private var dictionaries: [TypingLanguage: [WordEntry]] = [:]
    private var decoder: SwipeDecoder?
    private var decoderLanguage: TypingLanguage?
    private var decoderCenters: [Character: CGPoint] = [:]
    private var decoderVocabulary: [String] = []

    func entries(for language: TypingLanguage) -> [WordEntry] {
        if let cached = dictionaries[language] { return cached }
        guard let url = Bundle.module.url(forResource: language.rawValue, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let entries = text.split(separator: "\n").compactMap { line -> WordEntry? in
            let parts = line.split(separator: " ")
            guard parts.count == 2, let frequency = Int(parts[1]) else { return nil }
            return WordEntry(word: String(parts[0]), frequency: frequency)
        }
        dictionaries[language] = entries
        return entries
    }

    func suggestions(for text: String, language: TypingLanguage, personal: LearnedLanguage = LearnedLanguage()) -> [String] {
        let entries = personalizedEntries(language: language, personal: personal)
        let context = Self.contextWords(text: text, language: language)
        let previous = LearnedLanguage.previousWord(in: text, completingPartial: true)
        guard let range = TextEditing.trailingWordRange(in: text) else {
            let learnedContext = previous.flatMap { personal.nextWords[$0] } ?? [:]
            let learnedNext = learnedContext.keys.sorted {
                let a = learnedContext[$0] ?? 0, b = learnedContext[$1] ?? 0
                return a == b ? $0 < $1 : a > b
            }
            return Array((learnedNext + context + personal.predictedNext(after: nil) + entries.prefix(10).map(\.word)).uniqued().prefix(4))
        }
        let token = String(text[range])
        let prefix = WordEntry.keyboardForm(token)
        guard !prefix.isEmpty else { return [] }
        let exact = entries.filter { String($0.letters).hasPrefix(prefix) }
        var words = exact.sorted {
            let left = Double($0.frequency) * (context.contains($0.word) ? 4 : 1) * exp(personal.boost(for: $0.word, previous: previous) * 45)
            let right = Double($1.frequency) * (context.contains($1.word) ? 4 : 1) * exp(personal.boost(for: $1.word, previous: previous) * 45)
            return left > right
        }.prefix(4).map(\.word)
        if words.count < 4, prefix.count >= 2, prefix.count <= 24 {
            let threshold = prefix.count < 5 ? 1 : 2
            let corrections = entries.compactMap { entry -> (String, Double)? in
                guard abs(entry.letters.count - prefix.count) <= threshold else { return nil }
                let distance = Self.editDistance(Array(prefix), entry.letters)
                guard distance <= threshold else { return nil }
                return (entry.word, Double(distance) - log(Double(max(1, entry.frequency))) * 0.025
                        - personal.boost(for: entry.word, previous: previous))
            }.sorted { $0.1 < $1.1 }.map(\.0)
            words = Array((words + corrections).uniqued().prefix(4))
        }
        return Task.isCancelled ? [] : words
    }

    /// A conservative offer, never a silent replacement. Known words and personal
    /// vocabulary survive unchanged, including informal words such as "jaja".
    func correctionAfterSpace(for word: String, language: TypingLanguage, personal: LearnedLanguage) -> String? {
        let token = WordEntry.keyboardForm(word)
        guard (3...24).contains(token.count), word == word.lowercased() else { return nil }
        let entries = personalizedEntries(language: language, personal: personal)
        guard !entries.contains(where: { String($0.letters) == token }) else { return nil }
        let letters = Array(token)
        // Repeated syllables are often intentional laughter or expressive spelling.
        if letters.count.isMultiple(of: 2), letters.count >= 4 {
            let pairs = stride(from: 0, to: letters.count, by: 2).map { Array(letters[$0..<$0 + 2]) }
            if pairs.allSatisfy({ $0 == pairs[0] }) { return nil }
        }
        let candidates = entries.filter {
            $0.letters.first == letters.first && abs($0.letters.count - letters.count) <= 1
                && Self.editDistance(letters, $0.letters) == 1
        }.sorted { $0.frequency > $1.frequency }
        guard let best = candidates.first, best.frequency >= 1000 else { return nil }
        if candidates.count > 1, Double(best.frequency) < Double(candidates[1].frequency) * 2 { return nil }
        return best.word
    }

    func decode(path: [CGPoint], language: TypingLanguage, centers: [Character: CGPoint], keyWidth: CGFloat,
                text: String, personal: LearnedLanguage = LearnedLanguage(), panel: CGRect? = nil) -> [SwipeCandidate] {
        let vocabulary = personal.vocabulary
        if decoder == nil || decoderLanguage != language || decoderCenters != centers || decoderVocabulary != vocabulary {
            decoder = SwipeDecoder(entries: personalizedEntries(language: language, personal: personal), centers: centers, keyWidth: keyWidth)
            decoderLanguage = language
            decoderCenters = centers
            decoderVocabulary = vocabulary
        }
        return decoder?.decode(path, context: Self.contextWords(text: text, language: language), personal: personal,
                               previous: LearnedLanguage.previousWord(in: text, completingPartial: false), panel: panel) ?? []
    }

    private func personalizedEntries(language: TypingLanguage, personal: LearnedLanguage) -> [WordEntry] {
        let base = entries(for: language)
        guard !personal.words.isEmpty else { return base }
        let existing = Set(base.map(\.word))
        return base + personal.vocabulary.filter { !existing.contains($0) }.map { WordEntry(word: $0, frequency: 10000) }
    }

    static func contextWords(text: String, language: TypingLanguage) -> [String] {
        var words = text.lowercased().split { !$0.isLetter }.map(String.init)
        if TextEditing.trailingWordRange(in: text) != nil { _ = words.popLast() }
        let english = ["how": ["are", "do", "can", "much"], "thank": ["you"], "good": ["morning", "night", "luck"],
                       "i": ["am", "have", "will", "can"], "see": ["you"], "want": ["to"], "going": ["to"],
                       "you": ["are", "can", "have", "know"], "would": ["like", "be"], "hello": ["world", "there"]]
        let spanish = ["buenos": ["días", "amigos"], "buenas": ["tardes", "noches"], "muchas": ["gracias"],
                       "cómo": ["estás", "está", "te"], "como": ["estás", "está"], "por": ["favor", "qué", "eso"],
                       "quiero": ["que", "ir", "ver"], "voy": ["a"], "hasta": ["mañana", "luego"],
                       "hola": ["qué", "amigo", "cómo"], "gracias": ["por", "a"]]
        return (language == .english ? english : spanish)[words.last ?? ""] ?? []
    }

    /// Optimal string alignment distance, including adjacent transpositions (teh → the).
    static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { table[i][0] = i }
        for j in 0...b.count { table[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                table[i][j] = min(table[i - 1][j] + 1, table[i][j - 1] + 1,
                                  table[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    table[i][j] = min(table[i][j], table[i - 2][j - 2] + 1)
                }
            }
        }
        return table[a.count][b.count]
    }
}

enum TextEditing {
    static func trailingWordRange(in text: String) -> Range<String.Index>? {
        // A separator ends the word. Never reach back over spaces/newlines to replace it.
        guard let last = text.last, last.isLetter || last == "'" || last == "’" else { return nil }
        let start = text.lastIndex { !$0.isLetter && $0 != "'" && $0 != "’" }.map { text.index(after: $0) } ?? text.startIndex
        return start..<text.endIndex
    }

    static func accepting(_ word: String, in text: String, caps: Bool) -> String {
        let output = caps ? word.uppercased() : word
        if let range = trailingWordRange(in: text) {
            let token = String(text[range])
            let cased = !caps && token.first?.isUppercase == true ? output.prefix(1).uppercased() + output.dropFirst() : output
            return String(text[..<range.lowerBound]) + cased + " "
        }
        let separator = text.isEmpty || text.last?.isWhitespace == true ? "" : " "
        return text + separator + output + " "
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}
