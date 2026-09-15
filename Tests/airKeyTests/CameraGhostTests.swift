import AppKit
import CoreVideo
import SwiftUI
import XCTest
@testable import airKey

@MainActor
final class CameraGhostTests: XCTestCase {
    /// A four-tone calibration chart, not a simulated camera or hand image.
    private func chart() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 640, 480, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let result = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(result, [])
        defer { CVPixelBufferUnlockBaseAddress(result, []) }
        let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(result)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(result)
        for y in 0..<480 {
            for x in 0..<640 {
                let gray: UInt8 = y < 240 ? (x < 320 ? 32 : 224) : (x < 320 ? 80 : 160)
                let offset = y * stride + x * 4
                bytes[offset] = gray; bytes[offset + 1] = gray; bytes[offset + 2] = gray; bytes[offset + 3] = 255
            }
        }
        return result
    }

    private func opaqueMask() throws -> CGImage {
        let data = Data(repeating: 255, count: 640 * 480)
        return try XCTUnwrap(CGImage(width: 640, height: 480, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 640,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
            provider: try XCTUnwrap(CGDataProvider(data: data as CFData)), decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    func testRealPixelDetailIsPreservedWithBlueTint() throws {
        let renderer = CameraGhostRenderer()
        let image = try XCTUnwrap(renderer.composite(try chart(), mask: try opaqueMask()))
        XCTAssertEqual(image.width, 640)
        XCTAssertEqual(image.height, 480)
        let pixels = NSBitmapImageRep(cgImage: image)
        let dark = try XCTUnwrap(pixels.colorAt(x: 160, y: 120)?.usingColorSpace(.deviceRGB))
        let light = try XCTUnwrap(pixels.colorAt(x: 480, y: 120)?.usingColorSpace(.deviceRGB))
        let lowerLeft = try XCTUnwrap(pixels.colorAt(x: 160, y: 360)?.usingColorSpace(.deviceRGB))
        XCTAssertLessThan(light.redComponent, light.greenComponent)
        XCTAssertLessThan(light.greenComponent, light.blueComponent)
        XCTAssertGreaterThan(light.blueComponent, dark.blueComponent + 0.4)
        XCTAssertGreaterThan(lowerLeft.blueComponent, dark.blueComponent)
        XCTAssertEqual(light.alphaComponent, 1, accuracy: 0.01)
    }

    private func snapshot<V: View>(_ view: V, size: CGSize) throws -> NSBitmapImageRep {
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        hosting.appearance = NSAppearance(named: .darkAqua)
        let bounds = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.frame = bounds
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: bounds))
        hosting.cacheDisplay(in: bounds, to: bitmap)
        return bitmap
    }

    func testVideoMirrorsAndCropsWithCursorCoordinatesAndStaysInsidePanel() throws {
        let frames = HandFrameStore()
        frames.frame.cameraImage = try XCTUnwrap(CameraGhostRenderer().composite(try chart(), mask: try opaqueMask()))
        let size = CGSize(width: 640, height: 360)
        let panel = CGRect(x: 20, y: 20, width: 600, height: 320)
        let view = ZStack {
            Color.black
            CameraGhostView(frames: frames, size: size, panel: panel)
        }
        let bitmap = try snapshot(view, size: size)
        // Cache display may use a Retina backing store.
        let scale = CGFloat(bitmap.pixelsWide) / size.width
        func blue(_ point: CGPoint) throws -> CGFloat {
            try XCTUnwrap(bitmap.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?.usingColorSpace(.deviceRGB)).blueComponent
        }
        let projection = CameraProjection(imageSize: frames.frame.imageSize, viewSize: size)
        let bright = projection.project(CGPoint(x: 0.75, y: 0.75))
        let dark = projection.project(CGPoint(x: 0.25, y: 0.75))
        let lower = projection.project(CGPoint(x: 0.25, y: 0.25))
        XCTAssertLessThan(bright.x, dark.x, "Camera and Vision coordinates must mirror together")
        XCTAssertGreaterThan(try blue(bright), try blue(dark) + 0.08)
        XCTAssertGreaterThan(try blue(lower), try blue(dark) + 0.01)
        XCTAssertEqual(try blue(CGPoint(x: 5, y: 120)), 0, accuracy: 0.01)
        XCTAssertEqual(try blue(CGPoint(x: 160, y: 5)), 0, accuracy: 0.01)
    }

    func testLatestVideoSurvivesTrackingGapButStopsAndToggleClearIt() throws {
        let image = try XCTUnwrap(CameraGhostRenderer().composite(try chart(), mask: try opaqueMask()))
        var continuity = PointerContinuity()
        var tracked = HandFrame(timestamp: 1, cameraImage: image)
        tracked.aiming = [.right]; tracked.cursors[.right] = CGPoint(x: 0.5, y: 0.5)
        _ = continuity.apply(to: tracked)
        XCTAssertNil(continuity.apply(to: HandFrame(timestamp: 1.04)).cameraImage, "A held cursor must not resurrect an old camera image")
        let live = continuity.apply(to: HandFrame(timestamp: 1.08, cameraImage: image))
        XCTAssertTrue(live.cameraImage === image, "Real video must survive missing Vision observations")
        let camera = CameraManager()
        camera.frame = live
        camera.setCameraGhostEnabled(false)
        XCTAssertNil(camera.frame.cameraImage)
        XCTAssertFalse(camera.cameraGhostEnabled)
        camera.setCameraGhostEnabled(true)
        XCTAssertNil(camera.frame.cameraImage, "Wait for a fresh frame when enabled again")
        camera.frame = live
        camera.stop()
        XCTAssertNil(camera.frame.cameraImage)
    }

    func testPendingFramesKeepOnlyLatestVideo() throws {
        let renderer = CameraGhostRenderer(), buffer = try chart()
        let first = try XCTUnwrap(renderer.composite(buffer, mask: try opaqueMask())), latest = try XCTUnwrap(renderer.composite(buffer, mask: try opaqueMask()))
        let mailbox = FrameMailbox()
        XCTAssertTrue(mailbox.offer(HandFrame(timestamp: 1, cameraImage: first), at: 1))
        XCTAssertFalse(mailbox.offer(HandFrame(timestamp: 1.03, cameraImage: latest), at: 1.03))
        XCTAssertTrue(mailbox.take(at: 1.04)?.cameraImage === latest)
        XCTAssertNil(mailbox.take(at: 1.05))
    }

    /// Optional full UI review using a synthetic calibration fixture, never live video.
    func testRenderHandHologramPreviewAndMeasureEffectWhenRequested() async throws {
        guard let directory = ProcessInfo.processInfo.environment["AIRKEY_PREVIEW_DIR"] else { return }
        let renderer = CameraGhostRenderer(), buffer = HandMaskFixture.buffer()
        let poses = [HandMaskFixture.pose]
        _ = renderer.render(buffer, poses: poses)
        var timings: [Double] = []
        for _ in 0..<100 {
            let start = ProcessInfo.processInfo.systemUptime
            _ = renderer.render(buffer, poses: poses)
            timings.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
        timings.sort()
        print(String(format: "Hand mask + hologram: %.2f ms median / %.2f ms p95 (100 warm samples; excludes Vision and display)", timings[50], timings[95]))
        let camera = CameraManager(), keyboard = TypingController(), output = SystemTypingDriver()
        let size = CGSize(width: 1100, height: 600)
        keyboard.useFullSizeKeys(); keyboard.setSceneSize(size)
        camera.frames.frame.cameraImage = renderer.render(buffer, poses: poses)
        await keyboard.waitForSuggestions()
        let view = ContentView(camera: camera, keyboard: keyboard, output: output).environment(\.colorScheme, .dark)
        let bitmap = try snapshot(view, size: size)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("hand-hologram-calibration.png"))
    }
}
