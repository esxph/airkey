import XCTest
@testable import airKey

final class SwipePerformanceTests: XCTestCase {
    func testWarmDecoderLatencyOnRepresentativeWords() async {
        let engine = LanguageEngine(), layout = KeyboardLayout()
        let size = CGSize(width: 1100, height: 800)
        let centers = layout.letterCenters(in: size)
        let width = layout.keyFrames(in: size)["char_A"]!.width
        let words = ["hello", "world", "coffee", "keyboard", "thanks", "please", "good", "morning", "today", "tomorrow"]
        var times: [Double] = []
        let coldStart = ProcessInfo.processInfo.systemUptime
        _ = await engine.decode(path: SwipeDecoder.resample("hello".compactMap { centers[$0] }, count: 45),
                                language: .english, centers: centers, keyWidth: width, text: "")
        let cold = (ProcessInfo.processInfo.systemUptime - coldStart) * 1000
        for word in words {
            let path = SwipeDecoder.resample(word.compactMap { centers[$0] }, count: 45)
            let start = ProcessInfo.processInfo.systemUptime
            let result = await engine.decode(path: path, language: .english, centers: centers, keyWidth: width, text: "")
            times.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            XCTAssertTrue(result.prefix(3).map(\.word).contains(word), "\(word): \(result.map(\.word))")
        }
        times.sort()
        print(String(format: "Swipe benchmark: cold %.1f ms; warm median %.1f ms; max %.1f ms (10 words)", cold, times[5], times[9]))
        #if !DEBUG
        XCTAssertLessThan(times[9], 150, "Warm swipe decoding should stay interactive on this machine")
        #endif
    }
}
