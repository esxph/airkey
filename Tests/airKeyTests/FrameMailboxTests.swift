import XCTest
@testable import airKey

final class FrameMailboxTests: XCTestCase {
    func testMotionBacklogUsesOneDeliveryAndNewestPosition() throws {
        let mailbox = FrameMailbox()
        var scheduled = 0
        for index in 0..<1000 {
            var frame = HandFrame(timestamp: Double(index) / 30)
            frame.cursors[.left] = CGPoint(x: Double(index), y: 0)
            if mailbox.offer(frame, at: Double(index) / 30) { scheduled += 1 }
        }
        XCTAssertEqual(scheduled, 1)
        let newest = try XCTUnwrap(mailbox.take(at: 999.0 / 30))
        XCTAssertEqual(newest.cursors[.left]?.x, 999)
        XCTAssertNil(mailbox.take(at: 34))
        XCTAssertTrue(mailbox.offer(HandFrame(timestamp: 34)))
    }

    func testFastPinchEdgesRemainOrderedWhenMotionIsCoalesced() throws {
        let mailbox = FrameMailbox()
        for (time, kind) in [(1.0, HandEvent.Kind.began), (1.04, .ended), (1.08, .began)] {
            var frame = HandFrame(timestamp: time)
            frame.events = [HandEvent(side: .left, kind: kind, pointer: .zero, timestamp: time)]
            _ = mailbox.offer(frame, at: time)
        }
        let frame = try XCTUnwrap(mailbox.take(at: 1.09))
        XCTAssertEqual(frame.events.map(\.kind), [.began, .ended, .began])
    }

    func testBlockedUIThreadCancelsInsteadOfBurstTypingStalePresses() throws {
        let mailbox = FrameMailbox()
        var press = HandFrame(timestamp: 1)
        press.events = [HandEvent(side: .left, kind: .began, pointer: .zero, timestamp: 1)]
        _ = mailbox.offer(press, at: 1)
        _ = mailbox.offer(HandFrame(timestamp: 1.4), at: 1.4)
        let frame = try XCTUnwrap(mailbox.take(at: 1.41))
        XCTAssertEqual(frame.events.map(\.kind), [.cancelled, .cancelled])
        XCTAssertEqual(frame.timestamp, 1.4)
    }

    func testInferenceTimeIsNotMistakenForAUIBacklog() throws {
        let mailbox = FrameMailbox()
        var press = HandFrame(timestamp: 1)
        press.events = [HandEvent(side: .left, kind: .began, pointer: .zero, timestamp: 1)]
        _ = mailbox.offer(press, at: 1.3)
        XCTAssertEqual(try XCTUnwrap(mailbox.take(at: 1.31)).events.map(\.kind), [.began])
    }
}
