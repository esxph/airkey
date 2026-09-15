import AVFoundation
import CoreGraphics
import Vision

/// Accessed only by CameraPipeline's serial capture queue.
final class HandPoseDetector {
    private let request = VNDetectHumanHandPoseRequest()
    private let sequenceHandler = VNSequenceRequestHandler()
    private var identity = HandIdentityTracker()
    private(set) var rawHandCount = 0
    private(set) var rejectedHandCount = 0
    private(set) var uncertainSideCount = 0
    private static let maskJoints: [(HandMaskPose.Joint, VNHumanHandPoseObservation.JointName)] = [
        (.wrist, .wrist), (.thumbCMC, .thumbCMC), (.thumbMP, .thumbMP), (.thumbIP, .thumbIP), (.thumbTip, .thumbTip),
        (.indexMCP, .indexMCP), (.indexPIP, .indexPIP), (.indexDIP, .indexDIP), (.indexTip, .indexTip),
        (.middleMCP, .middleMCP), (.middlePIP, .middlePIP), (.middleDIP, .middleDIP), (.middleTip, .middleTip),
        (.ringMCP, .ringMCP), (.ringPIP, .ringPIP), (.ringDIP, .ringDIP), (.ringTip, .ringTip),
        (.littleMCP, .littleMCP), (.littlePIP, .littlePIP), (.littleDIP, .littleDIP), (.littleTip, .littleTip)
    ]
    init() { request.maximumHandCount = 2 }
    func reset() { identity = HandIdentityTracker() }

    func detect(from sampleBuffer: CMSampleBuffer) -> [HandObservation] {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return [] }
        do { try sequenceHandler.perform([request], on: buffer, orientation: .up) }
        catch { rawHandCount = 0; rejectedHandCount = 0; uncertainSideCount = 0; return [] }
        let aspect = Double(CVPixelBufferGetWidth(buffer)) / Double(max(1, CVPixelBufferGetHeight(buffer)))
        func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
            hypot((a.x - b.x) * aspect, a.y - b.y)
        }
        rawHandCount = request.results?.count ?? 0
        uncertainSideCount = 0
        let candidates: [HandCandidate] = (request.results ?? []).compactMap { observation in
            let side: HandSide?
            switch observation.chirality {
            case .left: side = .left
            case .right: side = .right
            default: side = nil; uncertainSideCount += 1
            }
            guard let points = try? observation.recognizedPoints(.all),
                  let index = points[.indexTip], let thumb = points[.thumbTip],
                  let indexBase = points[.indexMCP],
                  indexBase.confidence >= 0.25 else { return nil }
            let pinchReliable = min(index.confidence, thumb.confidence) >= 0.25
            let palm: Double
            if let littleBase = points[.littleMCP], littleBase.confidence >= 0.25 {
                palm = distance(indexBase.location, littleBase.location)
            } else if let wrist = points[.wrist], wrist.confidence >= 0.25 {
                palm = distance(indexBase.location, wrist.location) * 0.8
            } else { return nil }
            guard palm > 0.02 else { return nil }
            let indexLength = distance(index.location, indexBase.location)
            let thumbLength = points[.thumbCMC].flatMap { point in
                point.confidence >= 0.25 ? distance(thumb.location, point.location) : nil
            } ?? palm * 0.9
            // Preserve the prototype's hand-specific L-to-pinch scale and midpoint aim.
            let scale = max((indexLength + thumbLength) * 0.5, palm * 0.62)
            let wrist = points[.wrist].flatMap { $0.confidence >= 0.25 ? $0.location : nil }
            let pointer = CGPoint(x: (index.location.x + thumb.location.x) * 0.5,
                                  y: (index.location.y + thumb.location.y) * 0.5)
            let reference = wrist.map { CGPoint(x: (indexBase.location.x + $0.x) / 2,
                                                y: (indexBase.location.y + $0.y) / 2) }
            // Palm landmarks can preserve identity during fingertip occlusion;
            // the engine pauses input until a reliable midpoint is available.
            guard pinchReliable || reference != nil else { return nil }
            let maskPoints = Dictionary(uniqueKeysWithValues: Self.maskJoints.compactMap { joint, name -> (HandMaskPose.Joint, CGPoint)? in
                guard let point = points[name], point.confidence >= 0.25, point.location.isFinite else { return nil }
                return (joint, point.location)
            })
            let hand = HandObservation(side: side ?? .left, pointer: pointer, indexTip: index.location,
                                   thumbTip: thumb.location, wrist: wrist, clawOpenScore: 0,
                                   pinchDistanceScore: distance(index.location, thumb.location) / scale,
                                   confidence: pinchReliable ? min(index.confidence, thumb.confidence, indexBase.confidence)
                                       : min(indexBase.confidence, points[.wrist]?.confidence ?? 0),
                                   aimReference: reference, pinchIsReliable: pinchReliable,
                                   maskPose: HandMaskPose(points: maskPoints))
            return HandCandidate(observation: hand, reportedSide: side)
        }
        let hands = identity.assign(candidates, at: ProcessInfo.processInfo.systemUptime)
        rejectedHandCount = rawHandCount - hands.count
        return hands
    }
}
