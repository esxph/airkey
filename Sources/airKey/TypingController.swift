import Combine
import CoreGraphics
import Foundation

@MainActor
final class TypingController: ObservableObject {
    @Published private(set) var text = ""
    @Published var language: TypingLanguage = .spanish {
        didSet { if oldValue != language { cancelBenchmark(); cancelInput(); refreshSuggestions() } }
    }
    @Published var swipeMode = false {
        didSet { if oldValue != swipeMode { cancelBenchmark(); cancelInput(); refreshSuggestions() } }
    }
    @Published private(set) var caps = false
    @Published private(set) var layout = KeyboardLayout()
    @Published private(set) var suggestions: [String] = []
    @Published private(set) var hovered: [HandSide: String] = [:]
    @Published private(set) var traces: [HandSide: [CGPoint]] = [:]
    @Published private(set) var pressed: Set<String> = []
    @Published private(set) var message = "Open your hand to aim, then pinch a key."
    @Published private(set) var isDecoding = false
    @Published private(set) var canUndo = false
    @Published var showPointers = true
    @Published var restingHandProtection = true {
        didSet { cancelGestures() }
    }
    @Published private(set) var profile: PersonalProfile
    @Published private(set) var calibration: AimCalibration?
    @Published private(set) var benchmark: TypingBenchmark?
    @Published private(set) var benchmarkResult: BenchmarkResult?
    private var benchmarkDraft: (text: String, undo: [UndoEntry], caps: Bool, symbols: Bool)?
    private let clock: () -> TimeInterval
    var prepareExternalInput: (() -> Void)?
    var outputTextChange: ((String, String) -> Bool)?
    var deleteExternalCharacter: (() -> Void)?
    var userActivity: (() -> Void)?
    var windowDrag: ((KeyboardDragEvent) -> Void)?
    private(set) var sceneSize = CGSize(width: 1100, height: 760)

    private struct Press {
        let key: String
        let started: TimeInterval
        var nextRepeat: TimeInterval
        let swipe: Bool
        var points: [CGPoint]
        var maxDisplacement: CGFloat = 0
        var intent: HandIntentEvidence?
        var suspended = false
    }
    private enum InputAction {
        case key(String, HandIntentEvidence? = nil)
        case suggestion(String, String, String?, SwipeExample?)
        case swipe([CGPoint], [Character: CGPoint], CGFloat, TypingLanguage, Bool)
    }
    private struct SwipeExample {
        let points: [CGPoint]
        let panel: CGRect
    }
    private struct UndoEntry {
        let text: String
        var learning: (TypingLanguage, LearningReceipt)?
        var intent: HandIntentEvidence?
    }
    private var sessions: [HandSide: Press] = [:]
    private var handIntent = HandIntentGuard()
    private var frame = HandFrame()
    private var lastTimestamp: TimeInterval = -.infinity
    private var queue: [InputAction] = []
    private var inputTask: Task<Void, Never>?
    private var suggestionTask: Task<Void, Never>?
    private var generation = UUID()
    private var revision = 0
    private var swipeReplacement: (snapshot: String, prefix: String, example: SwipeExample)?
    private var spaceCorrection: (snapshot: String, word: String, prefix: String)?
    private var undoHistory: [UndoEntry] = []
    private let languageEngine = LanguageEngine()
    private let profileStore: PersonalProfileStore

    /// Tests default to memory-only learning; the app supplies its Application Support URL.
    init(profileURL: URL? = nil, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        let store = PersonalProfileStore(url: profileURL)
        profileStore = store
        profile = store.load()
        self.clock = clock
    }

    func setSceneSize(_ size: CGSize) {
        guard size != sceneSize, size.width > 0, size.height > 0 else { return }
        sceneSize = size
        cancelInput() // path coordinates from different layouts must not be mixed
        refreshSuggestions()
    }

    func useFullSizeKeys() { layout.fullSizeKeys = true }
    func useCompactKeyboard() { layout.fullSizeKeys = true; layout.compact = true }

    func editText(_ newText: String) {
        guard newText != text else { return }
        benchmark?.input(at: clock(), hand: false)
        if newText.count < text.count { benchmark?.corrections += 1 }
        cancelInput()
        changeText(newText)
        refreshSuggestions()
    }

    func process(_ newFrame: HandFrame) {
        guard newFrame.timestamp > lastTimestamp else { return }
        lastTimestamp = newFrame.timestamp
        if newFrame.imageSize != frame.imageSize { cancelGestures() }
        if benchmark?.started != nil, !frame.tracked.isEmpty, newFrame.tracked.isEmpty {
            benchmark?.trackingGaps += 1
        }
        frame = newFrame
        let projection = CameraProjection(imageSize: frame.imageSize, viewSize: sceneSize)
        if calibration != nil {
            for event in frame.events where event.kind == .began && frame.tracked.contains(event.side) {
                recordCalibration(at: projection.project(event.pointer), side: event.side)
            }
            return
        }
        handIntent.update(frame, projection: projection, cell: aimCell)
        for side in sessions.keys where frame.tracked.contains(side) && frame.phases[side] == .closed {
            handIntent.accepted(side, at: frame.timestamp)
        }
        let candidates = Set(frame.events.filter { $0.kind == .began }.map(\.side))
        let evidence = Dictionary(uniqueKeysWithValues: HandSide.allCases.compactMap { side in
            handIntent.evidence(for: side, at: frame.timestamp, candidates: candidates).map { (side, $0) }
        })
        var nextHovered = hovered
        for side in HandSide.allCases {
            guard frame.tracked.contains(side), let cursor = frame.cursors[side] else {
                // The engine bounds this grace period. Pause all input until the
                // closed hand returns; an actual loss still cancels the gesture.
                if frame.suspended.contains(side), var press = sessions[side] {
                    press.suspended = true
                    press.nextRepeat = max(press.nextRepeat, frame.timestamp + 0.085)
                    sessions[side] = press
                    if press.key == "move_keyboard" { windowDrag?(.paused) }
                } else {
                    removeSession(side)
                    if traces[side] != nil { traces[side] = nil }
                }
                if frame.aiming.contains(side), let cursor = frame.cursors[side] {
                    let point = projection.project(cursor)
                    nextHovered[side] = target(at: point)
                } else if !frame.heldPointers.contains(side) {
                    nextHovered[side] = nil
                }
                continue
            }
            let point = projection.project(cursor)
            if var press = sessions[side], press.suspended {
                let width = layout.keyFrames(in: sceneSize)[press.key]?.width ?? 60
                // An unseen release or a large jump cannot finish a partial word.
                if frame.phases[side] != .closed || (frame.pinchScores[side] ?? 1) >= frame.releaseThreshold
                    || (press.swipe && point.distance(to: press.points.last ?? point) > width * 0.75) {
                    removeSession(side)
                    traces[side] = nil
                } else {
                    press.suspended = false
                    press.nextRepeat = max(press.nextRepeat, frame.timestamp + 0.085)
                    sessions[side] = press
                }
            }
            nextHovered[side] = target(at: point)
        }
        if hovered != nextHovered { hovered = nextHovered }
        for event in frame.events {
            switch event.kind {
            case .began:
                guard frame.tracked.contains(event.side) else { continue }
                let intent = evidence[event.side]
                let corrections = profile.enabled ? profile.accidentalPinches?[event.side.rawValue] ?? 0 : 0
                if restingHandProtection, handIntent.shouldIgnore(intent, corrections: corrections) {
                    if benchmark?.started != nil { benchmark?.blockedPinches += 1 }
                    message = "Ignored a resting \(event.side.rawValue.lowercased()) hand pinch. Move that hand to aim, then open and pinch again."
                    continue
                }
                begin(side: event.side, at: projection.project(event.pointer), timestamp: event.timestamp, intent: intent)
            case .ended:
                finish(side: event.side)
            case .cancelled:
                removeSession(event.side)
                traces[event.side] = nil
            }
        }
        for side in HandSide.allCases {
            guard var press = sessions[side], frame.tracked.contains(side), frame.phases[side] == .closed,
                  let cursor = frame.cursors[side] else { continue }
            let point = projection.project(cursor)
            if press.key == "move_keyboard" {
                if !press.suspended, (frame.pinchScores[side] ?? 1) < frame.releaseThreshold {
                    windowDrag?(.moved(point))
                }
            } else if press.swipe {
                // Do not include opening-finger movement in the word path.
                if (frame.pinchScores[side] ?? 1) < frame.releaseThreshold {
                    press.maxDisplacement = max(press.maxDisplacement, point.distance(to: press.points[0]))
                    if point.distance(to: press.points.last ?? point) > 2 {
                        press.points.append(point)
                        // Preserve both endpoints when bounding long gestures.
                        if press.points.count > 256 { press.points = SwipeDecoder.resample(press.points, count: 128) }
                    }
                    if traces[side] != press.points { traces[side] = press.points }
                }
            } else if press.key == "delete" {
                guard layout.hitKey(at: point, in: sceneSize) == "delete" else {
                    // Leaving Delete pauses repetition without breaking the latch.
                    press.nextRepeat = max(press.nextRepeat, frame.timestamp + 0.085)
                    sessions[side] = press
                    continue
                }
                if frame.timestamp >= press.nextRepeat {
                    enqueue(.key("delete"))
                    press.nextRepeat = frame.timestamp + (frame.timestamp - press.started > 1.2 ? 0.05 : 0.085)
                }
            }
            sessions[side] = press
        }
        let nextPressed = Set(sessions.values.map(\.key))
        if pressed != nextPressed { pressed = nextPressed }
    }

    private func begin(side: HandSide, at point: CGPoint, timestamp: TimeInterval, intent: HandIntentEvidence?) {
        userActivity?()
        guard sessions[side] == nil, let key = target(at: point) else { return }
        guard !sessions.values.contains(where: { $0.key == "move_keyboard" }) else { return }
        if key == "move_keyboard" {
            guard sessions.isEmpty, inputTask == nil else { return }
            sessions[side] = Press(key: key, started: timestamp, nextRepeat: .infinity, swipe: false, points: [point])
            handIntent.accepted(side, at: timestamp)
            windowDrag?(.began(point))
            return
        }
        if benchmark == nil && calibration == nil { prepareExternalInput?() }
        let isSwipe = swipeMode && layout.keys.first(where: { $0.id == key })?.isLetter == true
        if isSwipe, sessions.values.contains(where: \.swipe) {
            message = "Finish this swipe before starting another."
            return
        }
        // Anchor the path to the intended starting key, then retain actual motion samples.
        let keyFrame = layout.keyFrames(in: sceneSize)[key]
        let start = isSwipe ? keyFrame.map { CGPoint(x: $0.midX, y: $0.midY) } ?? point : point
        sessions[side] = Press(key: key, started: timestamp, nextRepeat: timestamp + 0.45,
                               swipe: isSwipe, points: [start], intent: intent)
        benchmark?.input(at: clock(), hand: true)
        let delay = (clock() - timestamp) * 1000
        if delay.isFinite, delay >= 0, delay < 10_000, (benchmark?.processingMilliseconds.count ?? 0) < 2000 {
            benchmark?.processingMilliseconds.append(delay)
        }
        handIntent.accepted(side, at: timestamp)
        if isSwipe {
            traces[side] = [start]
            message = "Keep pinching, glide across the letters, then release."
        } else if key.hasPrefix("pred_") { activate(key, fromHand: true) }
        else { enqueue(.key(key, intent)) }
    }

    private func finish(side: HandSide) {
        guard let press = removeSession(side) else { return }
        traces[side] = nil
        guard press.swipe else { return }
        let width = layout.keyFrames(in: sceneSize)[press.key]?.width ?? 60
        if press.maxDisplacement < width * 0.6 {
            enqueue(.key(press.key, press.intent))
        } else {
            enqueue(.swipe(press.points, layout.letterCenters(in: sceneSize), width, language, caps))
        }
    }

    func activate(_ key: String, fromHand: Bool = false) {
        guard key != "move_keyboard", !sessions.values.contains(where: { $0.key == "move_keyboard" }) else { return }
        userActivity?()
        guard calibration == nil else {
            message = "Use hand pinches for aim practice. Mouse clicks do not train the model."
            return
        }
        if benchmark == nil && !fromHand { prepareExternalInput?() }
        if !fromHand { benchmark?.input(at: clock(), hand: false) }
        if key.hasPrefix("pred_"), let index = Int(key.dropFirst(5)), suggestions.indices.contains(index) {
            if index == 0, let correction = spaceCorrection, correction.snapshot == text,
               correction.word == suggestions[index] {
                enqueue(.suggestion(correction.word, correction.snapshot, correction.prefix, nil))
                return
            }
            enqueue(.suggestion(suggestions[index], swipeReplacement?.snapshot ?? text, swipeReplacement?.prefix,
                                swipeReplacement?.example))
        } else { enqueue(.key(key)) }
    }

    private func target(at point: CGPoint, previous: String? = nil) -> String? {
        if layout.hitsDragHandle(point, in: sceneSize, suggestionCount: suggestions.count) { return "move_keyboard" }
        for (index, rect) in layout.suggestionFrames(in: sceneSize, count: suggestions.count).enumerated() {
            if rect.insetBy(dx: -3, dy: -3).contains(point) { return "pred_\(index)" }
        }
        return layout.hitKey(at: point, in: sceneSize, previous: previous)
    }

    private func enqueue(_ action: InputAction) {
        // Tap input stays synchronous unless a released word is still being decoded.
        if inputTask == nil, case .key(let key, let intent) = action {
            commitKey(key, intent: intent)
            return
        }
        queue.append(action)
        guard inputTask == nil else { return }
        let token = generation
        inputTask = Task { [weak self] in
            guard let self else { return }
            while !self.queue.isEmpty && !Task.isCancelled && self.generation == token {
                let action = self.queue.removeFirst()
                switch action {
                case .key(let key, let intent): self.commitKey(key, intent: intent)
                case .suggestion(let word, let snapshot, let prefix, let example):
                    guard self.text == snapshot else { continue }
                    let previous = LearnedLanguage.previousWord(in: prefix ?? self.text, completingPartial: prefix == nil)
                    if let prefix {
                        guard self.changeText(prefix + (self.caps ? word.uppercased() : word) + " ") else { continue }
                    } else {
                        guard self.changeText(TextEditing.accepting(word, in: self.text, caps: self.caps)) else { continue }
                    }
                    self.learn(word: word, previous: previous, example: example, attachToUndo: true)
                    self.refreshSuggestions()
                case .swipe(let points, let centers, let width, let language, let caps):
                    self.isDecoding = true
                    let candidates = await self.languageEngine.decode(path: points, language: language, centers: centers,
                                                                       keyWidth: width, text: self.text,
                                                                       personal: self.profile.language(language),
                                                                       panel: self.layout.panelFrame(in: self.sceneSize))
                    guard !Task.isCancelled, self.generation == token else { return }
                    self.isDecoding = false
                    self.suggestionTask?.cancel()
                    self.spaceCorrection = nil
                    self.revision += 1
                    guard let best = candidates.first else {
                        self.suggestions = []
                        self.message = "Swipe not recognized. Try again or tap the letters."
                        continue
                    }
                    let prefix = self.text + (self.text.isEmpty || self.text.last?.isWhitespace == true ? "" : " ")
                    let example = SwipeExample(points: points, panel: self.layout.panelFrame(in: self.sceneSize))
                    // Uncertain paths offer candidates without silently inserting a guess.
                    if best.geometryScore < 0.58 {
                        guard self.changeText(prefix + (caps ? best.word.uppercased() : best.word) + " ") else { continue }
                        self.swipeReplacement = (self.text, prefix, example)
                        self.message = "Word added. Choose an alternative to replace it, or keep typing."
                    } else {
                        self.swipeReplacement = (self.text, prefix, example)
                        self.message = "Choose a suggestion to complete this swipe."
                    }
                    self.suggestions = candidates.map(\.word)
                }
            }
            guard self.generation == token else { return }
            self.inputTask = nil
            self.isDecoding = false
        }
    }

    private func commitKey(_ key: String, intent: HandIntentEvidence? = nil) {
        let previousText = text
        switch key {
        case "caps": caps.toggle(); return
        case "symbols":
            cancelGestures()
            layout.symbols.toggle()
            return
        case "undo": undo(); return
        case "delete":
            guard !text.isEmpty else {
                if benchmark == nil { deleteExternalCharacter?() }
                return
            }
            benchmark?.corrections += 1
            changeText(String(text.dropLast()))
        case "space": changeText(text + " ")
        case "done": changeText(text + "\n")
        default:
            guard key.hasPrefix("char_") else { return }
            let token = String(key.dropFirst(5))
            changeText(text + (caps ? token.uppercased() : token.lowercased()))
        }
        guard text != previousText else { return }
        if !undoHistory.isEmpty { undoHistory[undoHistory.count - 1].intent = intent }
        refreshSuggestions()
    }

    @discardableResult
    private func changeText(_ newText: String) -> Bool {
        guard text != newText else { return false }
        if benchmark == nil, outputTextChange?(text, newText) == false { return false }
        undoHistory.append(UndoEntry(text: text))
        if undoHistory.count > 80 { undoHistory.removeFirst() }
        text = newText
        canUndo = true
        swipeReplacement = nil
        suggestionTask?.cancel()
        spaceCorrection = nil
        revision += 1
        return true
    }

    func undo() {
        if benchmark == nil { prepareExternalInput?() }
        guard let entry = undoHistory.last else { return }
        if benchmark == nil, outputTextChange?(text, entry.text) == false { return }
        guard let previous = undoHistory.popLast() else { return }
        benchmark?.corrections += 1
        cancelInput()
        text = previous.text
        if let (language, receipt) = previous.learning {
            profile.languages[language.rawValue]?.unlearn(receipt)
            saveProfile()
        }
        canUndo = !undoHistory.isEmpty
        refreshSuggestions()
    }

    var canCorrectAccidentalPinch: Bool {
        calibration == nil && inputTask == nil && undoHistory.last?.intent?.canTeach == true
    }

    func correctAccidentalPinch() {
        if benchmark == nil { prepareExternalInput?() }
        guard canCorrectAccidentalPinch, let evidence = undoHistory.last?.intent else { return }
        benchmark?.reportedAccidents += 1
        undo()
        if profile.enabled && benchmark == nil {
            var counts = profile.accidentalPinches ?? [:]
            counts[evidence.side.rawValue] = min(6, (counts[evidence.side.rawValue] ?? 0) + 1)
            profile.accidentalPinches = counts
            saveProfile()
        }
        message = profile.enabled && benchmark == nil
            ? "Undone. Resting-hand protection learned from that \(evidence.side.rawValue.lowercased()) hand pinch."
            : "Accidental pinch undone. No personal training was changed."
    }

    func refreshSuggestions() {
        suggestionTask?.cancel()
        swipeReplacement = nil
        spaceCorrection = nil
        suggestions = [] // stale candidates must never target a newly edited word
        revision += 1
        let expectedRevision = revision, text = text, language = language, personal = profile.language(language)
        suggestionTask = Task { [weak self, languageEngine] in
            do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
            let words = await languageEngine.suggestions(for: text, language: language, personal: personal)
            var correction: (snapshot: String, word: String, prefix: String)?
            if text.last == " " {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if let range = TextEditing.trailingWordRange(in: trimmed),
                   let replacement = await languageEngine.correctionAfterSpace(for: String(trimmed[range]), language: language, personal: personal) {
                    correction = (text, replacement, String(trimmed[..<range.lowerBound]))
                }
            }
            guard let self, !Task.isCancelled, self.revision == expectedRevision else { return }
            self.spaceCorrection = correction
            self.suggestions = correction.map { value in Array(([value.word] + words.filter { $0 != value.word }).prefix(4)) } ?? words
        }
    }

    func cancelGestures() {
        if sessions.values.contains(where: { $0.key == "move_keyboard" }) { windowDrag?(.ended) }
        handIntent.reset()
        sessions.removeAll()
        traces.removeAll()
        hovered.removeAll()
        pressed.removeAll()
    }

    @discardableResult private func removeSession(_ side: HandSide) -> Press? {
        let press = sessions.removeValue(forKey: side)
        if press?.key == "move_keyboard" { windowDrag?(.ended) }
        return press
    }

    func cancelInput() {
        calibration = nil
        cancelGestures()
        inputTask?.cancel()
        inputTask = nil
        queue.removeAll()
        suggestionTask?.cancel()
        generation = UUID()
        revision += 1
        isDecoding = false
        swipeReplacement = nil
        spaceCorrection = nil
        suggestions = []
    }

    var learningSummary: String {
        if let calibration {
            let label = layout.keys.first(where: { $0.id == calibration.key })?.label ?? calibration.key
            let progress = calibration.isRefining
                ? "Fine-tuning · \(calibration.fit.consistentTargets.count)/12 consistent"
                : "Aim practice \(calibration.index + 1)/12"
            return "\(progress) · Pinch \(label) · \(calibration.side?.rawValue ?? "Either") hand"
        }
        guard profile.enabled else { return "Personal learning is paused" }
        return "Learning on this Mac · \(profile.wordCount) words · Fingertip midpoint aiming"
    }

    private var aimCell: CGSize {
        let frame = layout.keyFrames(in: sceneSize)[layout.symbols ? "char_1" : "char_Q"]
        return frame?.size ?? CGSize(width: 70, height: 65)
    }

    func correctedAim(_ point: CGPoint, side: HandSide) -> CGPoint {
        guard calibration == nil else { return point }
        return profile.corrected(point, side: side, cell: aimCell)
    }

    func displayedCursor(for side: HandSide) -> CGPoint? {
        guard let cursor = frame.cursors[side] else { return nil }
        return CameraProjection(imageSize: frame.imageSize, viewSize: sceneSize).project(cursor)
    }

    func suggestionLabel(at index: Int) -> String {
        guard suggestions.indices.contains(index) else { return "" }
        let word = caps ? suggestions[index].uppercased() : suggestions[index]
        return index == 0 && spaceCorrection?.snapshot == text ? "Fix: \(word)" : word
    }

    func startAimTraining() {
        guard benchmark == nil else { return }
        cancelInput()
        guard profile.enabled else { message = "Enable personal learning to train your aim."; return }
        layout.symbols = false
        calibration = AimCalibration()
        message = "Aim inside the yellow ring and pinch, then open your fingers. Use one hand for the round. Your text stays unchanged."
    }

    func cancelAimTraining() {
        calibration = nil
        message = "Aim practice cancelled. Your previous training is unchanged."
        refreshSuggestions()
    }

    private func recordCalibration(at point: CGPoint, side: HandSide) {
        guard var practice = calibration, let rect = layout.keyFrames(in: sceneSize)[practice.key] else { return }
        guard practice.side == nil || practice.side == side else {
            message = "Continue with your \(practice.side!.rawValue.lowercased()) hand. Train the other hand in another round."
            return
        }
        guard practice.record(point: point, target: CGPoint(x: rect.midX, y: rect.midY), cell: aimCell) else {
            message = "That pinch was outside the target. Your earlier samples are kept. Aim inside the yellow ring and pinch again."
            return
        }
        practice.side = side
        let fit = practice.fit
        if practice.hasFullRound, fit.isReady {
            calibration = nil
            profile.aim[side.rawValue] = fit.model
            saveProfile()
            message = "\(side.rawValue) hand trained from \(fit.consistentTargets.count) consistent pinches. Aiming compensation is ready."
            refreshSuggestions()
        } else {
            practice.refine()
            calibration = practice
            let nextLabel = layout.keys.first(where: { $0.id == practice.key })?.label ?? practice.key
            if practice.isRefining {
                message = "Your samples are kept. Let’s refine \(nextLabel): open your fingers, aim inside its yellow ring, then pinch."
            } else {
                message = "Pinch captured. Open your fingers, then aim inside the yellow ring on \(nextLabel)."
            }
        }
    }

    var canLearnCurrentWord: Bool { currentWordForLearning != nil && profile.enabled && calibration == nil && benchmark == nil && !isDecoding }
    private var currentWordForLearning: (word: String, previous: String?)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = TextEditing.trailingWordRange(in: trimmed), let word = LearnedLanguage.validWord(String(trimmed[range])) else { return nil }
        return (word, LearnedLanguage.previousWord(in: String(trimmed[..<range.lowerBound]), completingPartial: false))
    }

    func learnCurrentWord() {
        guard canLearnCurrentWord, let current = currentWordForLearning else { return }
        learn(word: current.word, previous: current.previous, example: swipeReplacement?.example, attachToUndo: false)
        message = "Learned “\(current.word)” for \(language.title). It can now appear in suggestions and swipe results."
        refreshSuggestions()
    }

    private func learn(word: String, previous: String?, example: SwipeExample?, attachToUndo: Bool) {
        guard profile.enabled, benchmark == nil else { return }
        guard let receipt = profile.languages[language.rawValue, default: LearnedLanguage()].learn(
            word: word, previous: previous, path: example?.points, panel: example?.panel
        ) else { return }
        if attachToUndo, !undoHistory.isEmpty { undoHistory[undoHistory.count - 1].learning = (language, receipt) }
        saveProfile()
    }

    func setLearningEnabled(_ enabled: Bool) {
        cancelInput()
        profile.enabled = enabled
        saveProfile()
        refreshSuggestions()
    }

    func resetLearning() {
        cancelInput()
        profile = PersonalProfile(enabled: profile.enabled)
        // Undo must never resurrect data that the user explicitly reset.
        for index in undoHistory.indices { undoHistory[index].learning = nil; undoHistory[index].intent = nil }
        saveProfile()
        message = "Personal words, swipe examples, aim training, and resting-hand learning have been reset."
        refreshSuggestions()
    }

    private func saveProfile() {
        profileStore.save(profile) { [weak self] saved in
            guard !saved else { return }
            Task { @MainActor in self?.message = "Learning works for this session, but the personal profile could not be saved." }
        }
    }

    func startBenchmark(pinchThreshold: Double = 0.4) {
        guard benchmark == nil, !isDecoding, inputTask == nil else { return }
        cancelInput()
        benchmarkDraft = (text, undoHistory, caps, layout.symbols)
        text = ""; undoHistory = []; canUndo = false; caps = false; layout.symbols = false
        benchmarkResult = nil
        benchmark = TypingBenchmark(language: language, swipe: swipeMode, protection: restingHandProtection,
                                    learning: profile.enabled, pinchThreshold: pinchThreshold)
        message = "Copy the practice phrase. Timing starts with your first input. Finish after making any corrections."
        refreshSuggestions()
    }

    var canFinishBenchmark: Bool {
        benchmark?.started != nil && inputTask == nil && sessions.isEmpty
    }

    func finishBenchmark() {
        guard canFinishBenchmark, let result = benchmark?.finish(text: text, at: clock()) else { return }
        benchmarkResult = result
        cancelBenchmark()
        message = "Test complete. Your original text is restored. Copy the result to compare future runs."
    }

    func cancelBenchmark() {
        guard benchmark != nil else { return }
        benchmark = nil
        cancelInput()
        if let draft = benchmarkDraft {
            text = draft.text; undoHistory = draft.undo; caps = draft.caps; layout.symbols = draft.symbols
            canUndo = !undoHistory.isEmpty
        }
        benchmarkDraft = nil
        refreshSuggestions()
        message = "Typing test closed. Your original text is restored."
    }

    func reportMissedPinch() {
        guard benchmark?.started != nil else { return }
        benchmark?.reportedMisses += 1
    }

    func setBenchmarkFatigue(_ value: String) { benchmarkResult?.fatigue = value }
    func dismissBenchmarkResult() { benchmarkResult = nil }

    /// A new destination/caret starts a new local context; never rewrite another field.
    func resetExternalComposition() {
        cancelInput()
        text = ""; undoHistory = []; canUndo = false
        refreshSuggestions()
    }

    /// Used by integration tests to await actual processing, without sleeps or camera hardware.
    func waitForProfileSave() async { await profileStore.flush() }
    func waitForPendingInput() async { await inputTask?.value }
    func waitForSuggestions() async { await suggestionTask?.value }
}
