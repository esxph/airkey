import CoreGraphics
import Foundation

/// Incrementally fitted mean/variance. Samples are normalized to a letter-sized cell.
struct OnlineMoments: Codable, Sendable {
    private(set) var count = 0
    private(set) var mean = 0.0
    private(set) var squaredDeviation = 0.0
    var variance: Double { count > 1 ? max(0, squaredDeviation / Double(count - 1)) : 0 }

    mutating func add(_ value: Double) {
        guard value.isFinite, count < 10000 else { return }
        count += 1
        let delta = value - mean
        mean += delta / Double(count)
        squaredDeviation += delta * (value - mean)
    }
}

struct AimModel: Codable, Sendable {
    var x = OnlineMoments()
    var y = OnlineMoments()
    var isReady: Bool { x.count >= 6 && y.count >= 6 && x.variance < 0.12 && y.variance < 0.12 }
    var sampleCount: Int { min(x.count, y.count) }

    @discardableResult
    mutating func observe(point: CGPoint, target: CGPoint, cell: CGSize) -> Bool {
        guard point.isFinite, target.isFinite, cell.width > 0, cell.height > 0 else { return false }
        let dx = (point.x - target.x) / cell.width, dy = (point.y - target.y) / cell.height
        // A distant/wild pinch is not a useful labeled example.
        guard abs(dx) <= 1.1, abs(dy) <= 1.1 else { return false }
        x.add(dx); y.add(dy)
        return true
    }

    func corrected(_ point: CGPoint, cell: CGSize) -> CGPoint {
        guard isReady else { return point }
        // A zero-offset prior and a hard bound keep small/noisy training sets conservative.
        let weight = Double(sampleCount) / Double(sampleCount + 4)
        return CGPoint(x: point.x - min(0.35, max(-0.35, x.mean * weight)) * cell.width,
                       y: point.y - min(0.35, max(-0.35, y.mean * weight)) * cell.height)
    }
}

struct LearnedSwipe: Codable, Sendable {
    var id = UUID()
    var word: String
    /// Keyboard-relative points, never camera frames or hand landmark recordings.
    var x: [Double]
    var y: [Double]
    var points: [CGPoint] { zip(x, y).map { CGPoint(x: $0.0, y: $0.1) } }
}

struct LearningReceipt {
    let word: String
    let previous: String?
    var wordIncremented = true
    var pairIncremented = true
    var swipeID: UUID?
}

struct LearnedLanguage: Codable, Sendable {
    var words: [String: Int] = [:]
    var nextWords: [String: [String: Int]] = [:]
    var swipes: [LearnedSwipe] = []

    var vocabulary: [String] { words.keys.sorted() }
    func boost(for word: String, previous: String?) -> CGFloat {
        let uses = min(100, words[word] ?? 0)
        let transitions = min(50, previous.flatMap { nextWords[$0]?[word] } ?? 0)
        return min(0.16, CGFloat(log1p(Double(uses))) * 0.035 + CGFloat(log1p(Double(transitions))) * 0.04)
    }
    func predictedNext(after previous: String?) -> [String] {
        let counts = previous.flatMap { nextWords[$0] } ?? [:]
        return words.keys.sorted {
            let a = (counts[$0] ?? 0) * 10 + (words[$0] ?? 0)
            let b = (counts[$1] ?? 0) * 10 + (words[$1] ?? 0)
            return a == b ? $0 < $1 : a > b
        }
    }

    @discardableResult
    mutating func learn(word: String, previous: String?, path: [CGPoint]? = nil, panel: CGRect? = nil) -> LearningReceipt? {
        guard let word = Self.validWord(word) else { return nil }
        let previous = previous.flatMap(Self.validWord)
        var receipt = LearningReceipt(word: word, previous: previous)
        receipt.wordIncremented = (words[word] ?? 0) < 1000
        words[word] = min(1000, (words[word] ?? 0) + 1)
        if let previous {
            receipt.pairIncremented = (nextWords[previous]?[word] ?? 0) < 1000
            nextWords[previous, default: [:]][word] = min(1000, (nextWords[previous]?[word] ?? 0) + 1)
        }
        // Reservoir bounds keep the private profile small and inference predictable.
        if words.count > 500, let victim = words.keys.filter({ $0 != word }).min(by: {
            let a = words[$0] ?? 0, b = words[$1] ?? 0
            return a == b ? $0 < $1 : a < b
        }) {
            words[victim] = nil
            nextWords[victim] = nil
            for key in Array(nextWords.keys) { nextWords[key]?[victim] = nil }
            swipes.removeAll { $0.word == victim }
        }
        if nextWords.count > 500, let first = nextWords.keys.sorted().first { nextWords[first] = nil }
        if let path, let panel, path.count >= 3, panel.width > 0, panel.height > 0 {
            let normalized = SwipeDecoder.resample(path, count: 32).map {
                CGPoint(x: ($0.x - panel.minX) / panel.width, y: ($0.y - panel.minY) / panel.height)
            }
            guard normalized.allSatisfy({ $0.isFinite && (-0.2...1.2).contains($0.x) && (-0.3...1.3).contains($0.y) }) else { return receipt }
            // Up to three distinct recent demonstrations per word, 120 total.
            if swipes.filter({ $0.word == word }).count >= 3,
               let index = swipes.firstIndex(where: { $0.word == word }) { swipes.remove(at: index) }
            let example = LearnedSwipe(word: word, x: normalized.map { Double($0.x) }, y: normalized.map { Double($0.y) })
            receipt.swipeID = example.id
            swipes.append(example)
            if swipes.count > 120 { swipes.removeFirst(swipes.count - 120) }
        }
        return receipt
    }

    mutating func unlearn(_ receipt: LearningReceipt) {
        if receipt.wordIncremented, let count = words[receipt.word] {
            words[receipt.word] = count > 1 ? count - 1 : nil
        }
        if receipt.pairIncremented, let previous = receipt.previous, let count = nextWords[previous]?[receipt.word] {
            nextWords[previous]?[receipt.word] = count > 1 ? count - 1 : nil
            if nextWords[previous]?.isEmpty == true { nextWords[previous] = nil }
        }
        if let id = receipt.swipeID { swipes.removeAll { $0.id == id } }
    }

    static func validWord(_ input: String) -> String? {
        let word = input.lowercased().precomposedStringWithCanonicalMapping.replacingOccurrences(of: "’", with: "'")
        guard (1...24).contains(word.count), word.first?.isLetter == true, word.last?.isLetter == true,
              word.allSatisfy({ $0.isLetter || $0 == "'" }), !WordEntry.keyboardForm(word).isEmpty else { return nil }
        return word
    }

    /// Context stops at sentence punctuation/newlines; it never stores the full composed text.
    static func previousWord(in text: String, completingPartial: Bool) -> String? {
        var prefix = text
        if completingPartial, let range = TextEditing.trailingWordRange(in: prefix) {
            prefix = String(prefix[..<range.lowerBound])
        }
        prefix = prefix.trimmingCharacters(in: .init(charactersIn: " \t"))
        guard let range = TextEditing.trailingWordRange(in: prefix) else { return nil }
        return validWord(String(prefix[range]))
    }
}

struct PersonalProfile: Codable, Sendable {
    var version = 1
    var enabled = true
    var aim: [String: AimModel] = [:]
    var languages: [String: LearnedLanguage] = [:]
    // Optional so profiles saved before resting-hand learning still decode intact.
    var accidentalPinches: [String: Int]?

    var wordCount: Int { languages.values.reduce(0) { $0 + $1.words.count } }
    func language(_ language: TypingLanguage) -> LearnedLanguage {
        enabled ? languages[language.rawValue] ?? LearnedLanguage() : LearnedLanguage()
    }
    func corrected(_ point: CGPoint, side: HandSide, cell: CGSize) -> CGPoint {
        guard enabled else { return point }
        return aim[side.rawValue]?.corrected(point, cell: cell) ?? point
    }
}

/// Loading is read-only. Writes are atomic on a dedicated serial queue, in scheduling order.
final class PersonalProfileStore: @unchecked Sendable {
    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AirKey/personal-learning.json")
    }
    private let url: URL?
    private let queue = DispatchQueue(label: "airkey.personal-profile", qos: .utility)
    init(url: URL?) { self.url = url }

    func load() -> PersonalProfile {
        guard let url, let data = try? Data(contentsOf: url), data.count < 2_000_000,
              let profile = try? JSONDecoder().decode(PersonalProfile.self, from: data), profile.version == 1,
              (profile.accidentalPinches ?? [:]).allSatisfy({ HandSide(rawValue: $0.key) != nil && (0...6).contains($0.value) }),
              profile.aim.count <= 2, profile.aim.values.allSatisfy({ model in
                  [model.x, model.y].allSatisfy {
                      (0...10000).contains($0.count) && $0.mean.isFinite && abs($0.mean) <= 1.1
                          && $0.squaredDeviation.isFinite && $0.squaredDeviation >= 0
                  }
              }), profile.languages.count <= 2, profile.languages.values.allSatisfy({ language in
                  language.words.count <= 500 && language.words.values.allSatisfy { (1...1000).contains($0) }
                      && language.words.keys.allSatisfy { LearnedLanguage.validWord($0) != nil }
                      && language.nextWords.count <= 500 && language.nextWords.allSatisfy { pair in
                          LearnedLanguage.validWord(pair.key) != nil && pair.value.count <= 500
                              && pair.value.allSatisfy { LearnedLanguage.validWord($0.key) != nil && (1...1000).contains($0.value) }
                      }
                      && language.swipes.count <= 120 && language.swipes.allSatisfy {
                          LearnedLanguage.validWord($0.word) != nil && $0.x.count == 32 && $0.y.count == 32
                              && $0.x.allSatisfy { $0.isFinite && (-0.2...1.2).contains($0) }
                              && $0.y.allSatisfy { $0.isFinite && (-0.3...1.3).contains($0) }
                      }
              }) else { return PersonalProfile() }
        return profile
    }

    func save(_ profile: PersonalProfile, completion: @escaping @Sendable (Bool) -> Void = { _ in }) {
        guard let url else { completion(true); return }
        queue.async {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                let data = try JSONEncoder().encode(profile)
                try data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                completion(true)
            } catch { completion(false) }
        }
    }

    func flush() async { await withCheckedContinuation { continuation in queue.async { continuation.resume() } } }
}

struct AimCalibration {
    // Repeated controls plus distributed letters let the offset model see the whole keyboard.
    static let targets = ["char_F", "char_J", "space", "char_T", "delete", "char_M",
                          "char_A", "char_L", "space", "char_G", "delete", "char_U"]
    var side: HandSide?
    private(set) var samples: [Int: CGPoint] = [:]
    private(set) var pendingTargets = Array(targets.indices)
    private(set) var isRefining = false
    var index: Int { pendingTargets.first ?? Self.targets.count }
    var key: String { Self.targets[min(index, Self.targets.count - 1)] }

    struct Fit {
        let model: AimModel
        let consistentTargets: Set<Int>
        let retryTargets: [Int]
        // Require coverage from most of the round, not just a small convenient cluster.
        var isReady: Bool { consistentTargets.count >= 9 && model.isReady }
    }

    var fit: Fit {
        guard !samples.isEmpty else { return Fit(model: AimModel(), consistentTargets: [], retryTargets: []) }
        func median(_ values: [CGFloat]) -> CGFloat {
            let sorted = values.sorted(), middle = sorted.count / 2
            return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        }
        let center = CGPoint(x: median(samples.values.map(\.x)), y: median(samples.values.map(\.y)))
        // Median absolute deviation resists a few bad pinches. The ceiling prevents
        // inconsistent clusters from making their own acceptance region arbitrarily wide.
        let radiusX = min(0.60, max(0.24, 3 * 1.4826 * median(samples.values.map { abs($0.x - center.x) })))
        let radiusY = min(0.60, max(0.24, 3 * 1.4826 * median(samples.values.map { abs($0.y - center.y) })))
        let consistent = Set(samples.keys.filter {
            let point = samples[$0]!
            return abs(point.x - center.x) <= radiusX && abs(point.y - center.y) <= radiusY
        })
        var model = AimModel()
        for index in consistent.sorted() {
            let point = samples[index]!
            model.observe(point: point, target: .zero, cell: CGSize(width: 1, height: 1))
        }
        let retries = samples.keys.sorted { left, right in
            // Revisit outliers first; if the entire round is noisy, revisit its least
            // representative targets. All other samples remain available.
            if consistent.contains(left) != consistent.contains(right) { return !consistent.contains(left) }
            let a = samples[left]!.distance(to: center), b = samples[right]!.distance(to: center)
            return a == b ? left < right : a > b
        }
        return Fit(model: model, consistentTargets: consistent, retryTargets: Array(retries.prefix(4)))
    }

    @discardableResult
    mutating func record(point: CGPoint, target: CGPoint, cell: CGSize) -> Bool {
        guard !pendingTargets.isEmpty, point.isFinite, target.isFinite,
              cell.width.isFinite, cell.height.isFinite, cell.width > 0, cell.height > 0 else { return false }
        let offset = CGPoint(x: (point.x - target.x) / cell.width, y: (point.y - target.y) / cell.height)
        guard abs(offset.x) <= 1.1, abs(offset.y) <= 1.1 else { return false }
        samples[index] = offset
        pendingTargets.removeFirst()
        return true
    }

    var hasFullRound: Bool { samples.count == Self.targets.count }

    mutating func refine() {
        guard pendingTargets.isEmpty else { return }
        pendingTargets = fit.retryTargets
        isRefining = true
    }
}
