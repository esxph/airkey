import Foundation

/// Aggregate counters only: no images, landmark positions, or typed text.
struct TrackingDiagnostics {
    private var started: TimeInterval?
    private var lastReport: TimeInterval = -.infinity
    private var frames = 0
    private var emptyDetections = 0
    private var rejectedHands = 0
    private var uncertainLabels = 0
    private var aimOnlyFrames = 0
    private var inferenceTotal: Double = 0
    private var inferenceMax: Double = 0

    mutating func record(at time: TimeInterval, inference: TimeInterval, rawHands: Int,
                         rejected: Int, uncertainSides: Int, aimOnly: Bool) -> String? {
        if started == nil { started = time }
        frames += 1
        if rawHands == 0 { emptyDetections += 1 }
        rejectedHands += rejected
        uncertainLabels += uncertainSides
        if aimOnly { aimOnlyFrames += 1 }
        inferenceTotal += inference
        inferenceMax = max(inferenceMax, inference)
        guard time - lastReport >= 1 else { return nil }
        lastReport = time
        let elapsed = max(0.001, time - (started ?? time))
        return String(format: "AirKey 0.3.2 tracking report\nProcessed frames: %d (%.1f fps average)\nVision time: %.1f ms average / %.1f ms maximum\nFrames with no Vision hand detection: %d\nRejected hand observations: %d\nUncertain left/right labels: %d\nFrames with uncertain fingertips: %d\nNo camera images or typed text are included.",
                      frames, Double(max(0, frames - 1)) / elapsed,
                      inferenceTotal * 1000 / Double(frames), inferenceMax * 1000,
                      emptyDetections, rejectedHands, uncertainLabels, aimOnlyFrames)
    }
}
