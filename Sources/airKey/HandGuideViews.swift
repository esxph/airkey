import SwiftUI

enum HandGuidePalette {
    static func cursor(_ side: HandSide) -> Color {
        side == .left ? Color(red: 0.58, green: 0.81, blue: 0.86) : Color(red: 0.66, green: 0.77, blue: 0.92)
    }
}

/// Real, isolated camera hands underneath the translucent key faces. Use the
/// same full-scene crop and mirror as the fingertip projection, then clip to the
/// panel; fitting the video to the panel itself would offset it from the cursor.
struct CameraGhostView: View {
    @ObservedObject var frames: HandFrameStore
    let size: CGSize
    let panel: CGRect

    var body: some View {
        let frame = frames.frame
        let projection = CameraProjection(imageSize: frame.imageSize, viewSize: size)
        Canvas { context, _ in
            guard let image = frame.cameraImage else { return }
            context.clip(to: Path(roundedRect: panel, cornerRadius: 22))
            context.opacity = 0.58
            context.draw(Image(decorative: image, scale: 1, orientation: .upMirrored), in: projection.imageRect)
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct PinchCursorView: View {
    let index: CGPoint?
    let thumb: CGPoint?
    let center: CGPoint
    let closed: Bool
    let side: HandSide

    var body: some View {
        let color = HandGuidePalette.cursor(side)
        ZStack {
            if let index, let thumb {
                Path { path in path.move(to: thumb); path.addLine(to: index) }
                    .stroke(color.opacity(0.85), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                Circle().fill(color).frame(width: 10, height: 10).position(thumb)
                Circle().fill(color).frame(width: 10, height: 10).position(index)
            }
            Circle()
                .fill(closed ? color : Color(red: 0.16, green: 0.22, blue: 0.28))
                .overlay(Circle().stroke(color, lineWidth: 2.5))
                .frame(width: 32, height: 32)
                .position(center)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Only this overlay receives camera snapshots; the keyboard is not redrawn for
/// every movement. The line and dots are integral parts of the pinch cursor.
struct HandOverlayView: View {
    @ObservedObject var frames: HandFrameStore
    @ObservedObject var keyboard: TypingController
    let size: CGSize

    var body: some View {
        let projection = CameraProjection(imageSize: frames.frame.imageSize, viewSize: size)
        ForEach(HandSide.allCases, id: \.self) { side in
            if let trace = keyboard.traces[side], trace.count > 1 {
                Path { $0.addLines(trace) }
                    .stroke(HandGuidePalette.cursor(side).opacity(0.7), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }
            if keyboard.showPointers, frames.frame.visibleHands.contains(side), let point = keyboard.displayedCursor(for: side) {
                let visual = frames.frame.visuals[side]
                PinchCursorView(index: visual.map { projection.project($0.indexTip) },
                    thumb: visual.map { projection.project($0.thumbTip) }, center: point,
                    closed: frames.frame.phases[side] == .closed, side: side)
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }
}
