import Foundation

/// One pending UI delivery, regardless of camera rate. Fresh motion replaces old
/// motion; gesture edges remain ordered unless a stall makes them unsafe to replay.
final class FrameMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: HandFrame?
    private var latestArrival: TimeInterval = 0
    private var oldestEdgeArrival: TimeInterval?

    /// Returns true only when the caller must schedule a main-thread delivery.
    func offer(_ frame: HandFrame, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let needsDelivery = pending == nil
        latestArrival = time
        if oldestEdgeArrival == nil, !frame.events.isEmpty { oldestEdgeArrival = time }
        var latest = frame
        if let pending {
            latest.events = pending.events + frame.events
            if pending.imageSize != frame.imageSize || latest.events.count > 64 {
                latest.events = cancellations(in: frame)
            }
        }
        pending = latest
        return needsDelivery
    }

    func take(at time: TimeInterval) -> HandFrame? {
        lock.lock()
        defer { lock.unlock() }
        guard var frame = pending else { return nil }
        pending = nil
        // Measure UI queue delay, not inference time. Slower Vision processing
        // must not make every otherwise valid press fail this backlog guard.
        if oldestEdgeArrival.map({ time - $0 > 0.15 }) == true || time - latestArrival > 0.15 {
            frame.events = cancellations(in: frame)
        }
        oldestEdgeArrival = nil
        return frame
    }

    private func cancellations(in frame: HandFrame) -> [HandEvent] {
        HandSide.allCases.map { HandEvent(side: $0, kind: .cancelled,
            pointer: frame.cursors[$0] ?? .zero, timestamp: frame.timestamp) }
    }
}
