import CoreGraphics
import Foundation

enum HandSide: String, CaseIterable, Sendable {
    case left = "Left"
    case right = "Right"
}

enum HandPhase: String, Sendable {
    case open = "OPEN"
    case closed = "CLOSED"
}

struct HandObservation: Sendable {
    var side: HandSide
    let pointer: CGPoint
    let indexTip: CGPoint
    let thumbTip: CGPoint
    let wrist: CGPoint?
    let clawOpenScore: CGFloat
    let pinchDistanceScore: CGFloat
    let confidence: Float
    /// Palm reference for identity association; never used to offset the cursor.
    var aimReference: CGPoint? = nil
    /// Palm tracking can remain valid when touching fingertips occlude each other.
    var pinchIsReliable = true
    /// Live-camera segmentation evidence only; never affects cursor or gestures.
    var maskPose: HandMaskPose? = nil
}

struct HandFeedbackVisual: Sendable {
    let side: HandSide
    let indexTip: CGPoint
    let thumbTip: CGPoint
    let wrist: CGPoint?
    let confidence: Float
}

struct HandEvent: Sendable {
    enum Kind: Sendable { case began, ended, cancelled }
    let side: HandSide
    let kind: Kind
    let pointer: CGPoint
    let timestamp: TimeInterval
}

struct HandFrame: Sendable {
    var timestamp: TimeInterval = 0
    var events: [HandEvent] = []
    var cursors: [HandSide: CGPoint] = [:]
    var phases: [HandSide: HandPhase] = [:]
    var tracked: Set<HandSide> = []
    var pinchScores: [HandSide: CGFloat] = [:]
    var visuals: [HandSide: HandFeedbackVisual] = [:]
    var imageSize = CGSize(width: 640, height: 480)
    /// Latest real camera pixels, tinted for display; never persisted or learned.
    var cameraImage: CGImage? = nil
    var releaseThreshold: CGFloat = 0.64
    /// Same fingertip midpoint for taps and swipes.
    var tapCursors: [HandSide: CGPoint] = [:]
    /// A closed hand briefly occluded by its own fingers. No input while suspended.
    var suspended: Set<HandSide> = []
    var aiming: Set<HandSide> = []
    /// Display continuity only. These hands cannot generate input.
    var heldPointers: Set<HandSide> = []
    var visibleHands: Set<HandSide> { aiming.union(tracked).union(heldPointers) }
}

extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat { hypot(x - other.x, y - other.y) }
    var isFinite: Bool { x.isFinite && y.isFinite }
    func interpolated(to other: CGPoint, fraction: CGFloat) -> CGPoint {
        CGPoint(x: x + (other.x - x) * fraction, y: y + (other.y - y) * fraction)
    }
}

/// Matches a mirrored AVCaptureVideoPreviewLayer using resizeAspectFill.
struct CameraProjection {
    let imageSize: CGSize
    let viewSize: CGSize

    var imageRect: CGRect {
        let scale = max(viewSize.width / max(1, imageSize.width), viewSize.height / max(1, imageSize.height))
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        return CGRect(x: (viewSize.width - width) / 2, y: (viewSize.height - height) / 2,
                      width: width, height: height)
    }

    func project(_ normalized: CGPoint) -> CGPoint {
        let rect = imageRect
        return CGPoint(x: (1 - normalized.x) * rect.width + rect.minX,
                       y: (1 - normalized.y) * rect.height + rect.minY)
    }
}
