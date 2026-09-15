import Foundation

struct TypingBenchmark {
    let language: String
    let swipe: Bool
    let protection: Bool
    let learning: Bool
    let target: String
    let pinchThreshold: Double
    private(set) var started: TimeInterval?
    var handInputs = 0
    var assistedInputs = 0
    var corrections = 0
    var reportedAccidents = 0
    var reportedMisses = 0
    var blockedPinches = 0
    var trackingGaps = 0
    var processingMilliseconds: [Double] = []

    init(language: TypingLanguage, swipe: Bool, protection: Bool, learning: Bool, pinchThreshold: Double = 0.4) {
        self.language = language.rawValue
        self.swipe = swipe
        self.protection = protection
        self.learning = learning
        self.pinchThreshold = pinchThreshold
        target = language == .spanish
            ? "mañana vamos al parque para pasar un buen rato con los amigos"
            : "we can meet at the park and spend some time with our friends"
    }

    mutating func input(at time: TimeInterval, hand: Bool) {
        guard time.isFinite else { return }
        if started == nil { started = time }
        if hand { handInputs += 1 } else { assistedInputs += 1 }
    }

    func finish(text: String, at time: TimeInterval) -> BenchmarkResult? {
        guard let started, time.isFinite, time > started else { return nil }
        // Suggestion acceptance adds a trailing space. Ignore surrounding whitespace
        // only; case, accents, internal spaces, and punctuation remain meaningful.
        let entered = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let errors = Self.distance(Array(target), Array(entered))
        return BenchmarkResult(language: language, swipe: swipe, protection: protection, learning: learning,
            pinchThreshold: pinchThreshold, seconds: time - started, characters: entered.count, targetCharacters: target.count,
            errors: errors, handInputs: handInputs, assistedInputs: assistedInputs, corrections: corrections,
            reportedAccidents: reportedAccidents, reportedMisses: reportedMisses, blockedPinches: blockedPinches,
            trackingGaps: trackingGaps, processingMedian: Self.percentile(processingMilliseconds, fraction: 0.5),
            processingP95: Self.percentile(processingMilliseconds, fraction: 0.95))
    }

    static func distance(_ reference: [Character], _ entered: [Character]) -> Int {
        var row = Array(0...entered.count)
        for (i, a) in reference.enumerated() {
            var next = [i + 1]
            for (j, b) in entered.enumerated() {
                next.append(min(next[j] + 1, row[j + 1] + 1, row[j] + (a == b ? 0 : 1)))
            }
            row = next
        }
        return row[entered.count]
    }

    static func percentile(_ values: [Double], fraction: Double) -> Double? {
        let sorted = values.filter { $0.isFinite && $0 >= 0 }.sorted()
        guard !sorted.isEmpty else { return nil }
        return sorted[max(0, min(sorted.count - 1, Int(ceil(Double(sorted.count) * fraction)) - 1))]
    }
}

struct BenchmarkResult {
    let language: String
    let swipe: Bool
    let protection: Bool
    let learning: Bool
    let pinchThreshold: Double
    let seconds: Double
    let characters: Int
    let targetCharacters: Int
    let errors: Int
    let handInputs: Int
    let assistedInputs: Int
    let corrections: Int
    let reportedAccidents: Int
    let reportedMisses: Int
    let blockedPinches: Int
    let trackingGaps: Int
    let processingMedian: Double?
    let processingP95: Double?
    var fatigue: String = "Not reported"
    var wordsPerMinute: Double { Double(characters) / 5 / (seconds / 60) }
    var errorPercent: Double { Double(errors) / Double(max(1, targetCharacters)) * 100 }
    var summary: String {
        String(format: "%.1f WPM · %.1f%% remaining error · %d corrections", wordsPerMinute, errorPercent, corrections)
            + (assistedInputs > 0 ? " · Assisted input" : " · Hand input")
    }
    var report: String {
        """
        AirKey typing benchmark v1
        Language: \(language); swipe: \(swipe); resting-hand protection: \(protection); personal learning: \(learning)
        Pinch threshold: \(pinchThreshold)
        \(summary)
        Elapsed seconds (first input to Finish, including corrections): \(String(format: "%.2f", seconds))
        Entered characters: \(characters); target characters: \(targetCharacters); character edit distance: \(errors)
        Hand beginnings: \(handInputs); mouse/editor inputs: \(assistedInputs)
        Reported accidental pinches: \(reportedAccidents); reported missed pinches: \(reportedMisses)
        Blocked pinches (not verified mistakes): \(blockedPinches); tracking interruptions: \(trackingGaps)
        Capture callback to hand-event handling, median/p95 ms: \(processingMedian.map { String(format: "%.1f", $0) } ?? "unavailable") / \(processingP95.map { String(format: "%.1f", $0) } ?? "unavailable")
        Pipeline timing excludes camera exposure, display rendering, and word decoding.
        Hand fatigue: \(fatigue)
        WPM uses five characters per word. Remaining error is edit distance / target length; it can exceed 100%. Surrounding whitespace is ignored.
        Fixed phrase per language. Compare the same language, input mode, pinch effort, and camera setup. Results are kept only for this app session.
        """
    }
}
