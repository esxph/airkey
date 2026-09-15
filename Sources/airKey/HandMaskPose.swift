import CoreGraphics

/// Display-only landmarks, in unmirrored Vision coordinates. They locate pixels
/// to segment; they are never rendered as a replacement hand or used for input.
struct HandMaskPose: Sendable {
    enum Joint: CaseIterable, Sendable {
        case wrist, thumbCMC, thumbMP, thumbIP, thumbTip
        case indexMCP, indexPIP, indexDIP, indexTip
        case middleMCP, middlePIP, middleDIP, middleTip
        case ringMCP, ringPIP, ringDIP, ringTip
        case littleMCP, littlePIP, littleDIP, littleTip
    }
    let points: [Joint: CGPoint]
    static let fingers: [[Joint]] = [
        [.thumbCMC, .thumbMP, .thumbIP, .thumbTip],
        [.indexMCP, .indexPIP, .indexDIP, .indexTip],
        [.middleMCP, .middlePIP, .middleDIP, .middleTip],
        [.ringMCP, .ringPIP, .ringDIP, .ringTip],
        [.littleMCP, .littlePIP, .littleDIP, .littleTip]
    ]
}
