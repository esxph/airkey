import XCTest
@testable import airKey

final class LayoutAndLanguageTests: XCTestCase {
    func testAllKeyCentersHitTheirRenderedKeysAtSupportedWindowSizes() {
        for size in [CGSize(width: 980, height: 740), CGSize(width: 1100, height: 800), CGSize(width: 1600, height: 1000)] {
            for symbols in [false, true] {
                let layout = KeyboardLayout(symbols: symbols)
                let panel = layout.panelFrame(in: size)
                let frames = layout.keyFrames(in: size)
                XCTAssertEqual(Set(layout.keys.map(\.id)).count, layout.keys.count)
                for (key, rect) in frames {
                    XCTAssertTrue(panel.contains(rect), "\(key) outside keyboard")
                    XCTAssertGreaterThan(rect.width, 35)
                    XCTAssertEqual(layout.hitKey(at: CGPoint(x: rect.midX, y: rect.midY), in: size), key)
                    for (other, otherRect) in frames where key != other { XCTAssertFalse(rect.intersects(otherRect)) }
                }
            }
        }
    }

    func testSpaceAndDeleteGravityAttractNearbyPointsWithoutStealingDirectLetterHits() {
        let layout = KeyboardLayout(), size = CGSize(width: 1100, height: 800)
        let frames = layout.keyFrames(in: size)
        let space = frames["space"]!, delete = frames["delete"]!
        XCTAssertEqual(layout.hitKey(at: CGPoint(x: space.midX, y: space.maxY + 30), in: size), "space")
        XCTAssertEqual(layout.hitKey(at: CGPoint(x: space.minX - 5, y: space.midY), in: size), "space")
        XCTAssertEqual(layout.hitKey(at: CGPoint(x: space.minX - 30, y: space.midY), in: size), "symbols")
        XCTAssertEqual(layout.hitKey(at: CGPoint(x: delete.maxX + 28, y: delete.midY), in: size), "delete")
        XCTAssertEqual(layout.hitKey(at: CGPoint(x: delete.midX, y: delete.minY - 20), in: size), "delete")
        let p = frames["char_P"]!
        XCTAssertEqual(layout.hitKey(at: CGPoint(x: p.maxX - 2, y: p.midY), in: size), "char_P")
        XCTAssertNil(layout.hitKey(at: CGPoint(x: space.midX, y: space.maxY + 50), in: size))
    }

    func testSuggestionsStayAboveKeyboardWithNoOverlap() {
        let layout = KeyboardLayout(), size = CGSize(width: 980, height: 740)
        for count in 1...4 {
            let frames = layout.suggestionFrames(in: size, count: count)
            XCTAssertEqual(frames.count, count)
            for rect in frames { XCTAssertLessThan(rect.maxY, layout.panelFrame(in: size).minY) }
            for (a, b) in zip(frames, frames.dropFirst()) { XCTAssertFalse(a.intersects(b)) }
        }
        XCTAssertEqual(layout.suggestionFrames(in: size, count: 0), [])
    }

    func testProjectionMirrorsTheInsetCameraRegionWithoutMovingItsCenter() {
        let projection = CameraProjection(imageSize: CGSize(width: 640, height: 480), viewSize: CGSize(width: 1000, height: 500))
        XCTAssertEqual(projection.project(CGPoint(x: 0.5, y: 0.5)), CGPoint(x: 500, y: 250))
        XCTAssertEqual(projection.project(CGPoint(x: 0.88, y: 0.5)).x, 0, accuracy: 0.000001)
        XCTAssertEqual(projection.project(CGPoint(x: 0.12, y: 0.5)).x, 1000, accuracy: 0.000001)
        XCTAssertEqual(projection.project(CGPoint(x: 0.12, y: 0.88)).y, -125, accuracy: 0.000001)
        XCTAssertEqual(projection.imageRect.width, 1000 / 0.76, accuracy: 0.000001)
    }

    func testSuggestionDoesNotReplacePreviousWordAfterWhitespaceOrPunctuation() {
        XCTAssertEqual(TextEditing.accepting("world", in: "hello ", caps: false), "hello world ")
        XCTAssertEqual(TextEditing.accepting("hello", in: "one\n", caps: false), "one\nhello ")
        XCTAssertEqual(TextEditing.accepting("mundo", in: "hola,", caps: false), "hola, mundo ")
        XCTAssertEqual(TextEditing.accepting("mañana", in: "👋 ma", caps: false), "👋 mañana ")
        XCTAssertEqual(TextEditing.accepting("hello", in: "He", caps: false), "Hello ")
        XCTAssertEqual(TextEditing.accepting("hola", in: "ho", caps: true), "HOLA ")
    }

    func testAccentMappingPreservesEnye() {
        XCTAssertEqual(WordEntry.keyboardForm("MAÑANA"), "mañana")
        XCTAssertEqual(WordEntry.keyboardForm("adiós"), "adios")
        XCTAssertNotEqual(WordEntry.keyboardForm("año"), WordEntry.keyboardForm("ano"))
        XCTAssertEqual(WordEntry.keyboardForm("don't"), "dont")
    }

    func testEnglishAndSpanishCompletionsCorrectionsAndContext() async {
        let engine = LanguageEngine()
        let english = await engine.suggestions(for: "hel", language: .english)
        XCTAssertTrue(english.contains("hello"), "\(english)")
        let spanish = await engine.suggestions(for: "maña", language: .spanish)
        XCTAssertTrue(spanish.contains("mañana"), "\(spanish)")
        let correction = await engine.suggestions(for: "hellp", language: .english)
        XCTAssertTrue(correction.contains("hello"), "\(correction)")
        let next = await engine.suggestions(for: "muchas ", language: .spanish)
        XCTAssertEqual(next.first, "gracias")
        XCTAssertEqual(LanguageEngine.editDistance(Array("teh"), Array("the")), 1)
        let entries = await engine.entries(for: .english)
        XCTAssertGreaterThan(entries.count, 40000)
    }

    func testResamplingRetainsEndpointsIncludingRepeatedLetters() {
        let points = [CGPoint(x: 1, y: 2), CGPoint(x: 1, y: 2), CGPoint(x: 80, y: 20), CGPoint(x: 130, y: 90)]
        let result = SwipeDecoder.resample(points, count: 32)
        XCTAssertEqual(result.first, points.first)
        XCTAssertEqual(result.last, points.last)
        XCTAssertEqual(result.count, 32)
        XCTAssertTrue(result.allSatisfy(\.isFinite))
    }

    func testNoisyVariableSpeedSwipesRankIntendedWordsInBothLanguages() async {
        let engine = LanguageEngine()
        let layout = KeyboardLayout(), size = CGSize(width: 1100, height: 800)
        let centers = layout.letterCenters(in: size)
        let width = layout.keyFrames(in: size)["char_A"]!.width
        for (language, words) in [(TypingLanguage.english, ["hello", "world", "keyboard", "good", "coffee", "reliability", "thanks"]),
                                  (.spanish, ["hola", "mundo", "mañana", "gracias", "teclado", "llamar", "adiós"])] {
            for word in words {
                let ideal = WordEntry.keyboardForm(word).compactMap { centers[$0] }
                let sampled = SwipeDecoder.resample(ideal, count: 65)
                var noisy: [CGPoint] = []
                for (index, point) in sampled.enumerated() {
                    let point = CGPoint(x: point.x + sin(Double(index) * 1.7) * 4,
                                        y: point.y + cos(Double(index) * 0.8) * 4)
                    noisy.append(point)
                    if index % 3 == 0 { noisy.append(point) } // variable dwell / speed
                }
                let candidates = await engine.decode(path: noisy, language: language, centers: centers, keyWidth: width, text: "")
                XCTAssertTrue(candidates.prefix(3).map(\.word).contains(word), "\(word): \(candidates.map(\.word))")
                XCTAssertLessThan(candidates.first?.geometryScore ?? 10, 0.58)
            }
        }
    }

    func testRejectsEmptyStationaryInvalidAndOffKeyboardSwipes() async {
        let engine = LanguageEngine()
        let layout = KeyboardLayout(), size = CGSize(width: 1100, height: 800)
        for path in [[], Array(repeating: CGPoint(x: 400, y: 400), count: 40),
                     [CGPoint(x: -500, y: -500), CGPoint(x: -300, y: -100), CGPoint(x: -100, y: -400)],
                     [CGPoint(x: CGFloat.nan, y: 10), CGPoint(x: 10, y: 20), CGPoint(x: 20, y: 40)]] {
            let candidates = await engine.decode(path: path, language: .english, centers: layout.letterCenters(in: size), keyWidth: 70, text: "")
            XCTAssertTrue(candidates.isEmpty)
        }
    }
}
