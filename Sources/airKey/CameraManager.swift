import AVFoundation
import Combine
import Foundation

@MainActor
final class HandFrameStore: ObservableObject {
    @Published var frame = HandFrame()
}

@MainActor
final class CameraManager: ObservableObject {
    let frames = HandFrameStore()
    var frame: HandFrame {
        get { frames.frame }
        set { frames.frame = newValue }
    }
    @Published private(set) var status = "Camera stopped"
    @Published private(set) var isRunning = false
    @Published private(set) var permissionDenied = false
    @Published private(set) var cameraGhostEnabled = true
    @Published private(set) var pinchThreshold: Double = 0.40
    @Published private(set) var trackingReport = "AirKey 0.3.2 — start the camera for a tracking report."
    private let pipeline = CameraPipeline()
    private var runID = UUID()
    private var wantsCamera = false
    private var watchdog: Task<Void, Never>?
    private var lastFrameAt = Date.distantPast
    private var hasTrackedHand = false

    func setCameraGhostEnabled(_ enabled: Bool) {
        cameraGhostEnabled = enabled
        pipeline.setCameraGhostEnabled(enabled)
        if !enabled { frames.frame.cameraImage = nil }
    }

    func setPinchThreshold(_ value: Double) {
        pinchThreshold = min(0.60, max(0.25, value))
        pipeline.setPinchThreshold(pinchThreshold)
        frame = HandFrame(timestamp: ProcessInfo.processInfo.systemUptime)
    }


    func start() {
        guard !wantsCamera else { return }
        wantsCamera = true
        runID = UUID()
        let token = runID
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: beginCapture(token: token)
        case .notDetermined:
            status = "Waiting for camera permission…"
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    guard let self, self.wantsCamera, self.runID == token else { return }
                    if granted { self.beginCapture(token: token) } else { self.denyPermission() }
                }
            }
        default: denyPermission()
        }
    }

    private func denyPermission() {
        permissionDenied = true
        wantsCamera = false
        status = "Allow Camera in System Settings → Privacy & Security, then retry."
    }

    private func beginCapture(token: UUID) {
        permissionDenied = false
        status = "Starting camera…"
        lastFrameAt = Date()
        hasTrackedHand = false
        let mailbox = FrameMailbox()
        pipeline.start { [weak self] update in
            // Do not enqueue every camera snapshot behind a busy UI thread.
            if case .frame(let frame) = update, !mailbox.offer(frame) { return }
            DispatchQueue.main.async {
                guard let self, self.wantsCamera, self.runID == token else { return }
                switch update {
                case .frame:
                    guard var frame = mailbox.take(at: ProcessInfo.processInfo.systemUptime) else { return }
                    if !self.cameraGhostEnabled { frame.cameraImage = nil }
                    self.lastFrameAt = Date()
                    self.frame = frame // one atomic snapshot; every gesture edge is delivered
                    if !self.isRunning { self.isRunning = true }
                    let handCount = frame.visibleHands.count
                    if !frame.aiming.union(frame.tracked).isEmpty { self.hasTrackedHand = true }
                    let status = handCount == 0
                        ? (self.hasTrackedHand ? "Tracking interrupted — input paused" : "Show an open hand to begin")
                        : "Tracking \(handCount) hand(s)"
                    if self.status != status { self.status = status }
                case .report(let report): self.trackingReport = report
                case .status(let status, let running):
                    self.status = status
                    self.isRunning = running
                    if !running { self.wantsCamera = false }
                }
            }
        }
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self, self.wantsCamera, self.runID == token else { return }
                if Date().timeIntervalSince(self.lastFrameAt) > 0.5 {
                    // No frames (disconnect/interruption) must also cancel a held gesture.
                    self.frame = HandFrame(timestamp: ProcessInfo.processInfo.systemUptime)
                    self.status = "Camera paused. Reconnect it or stop and retry."
                    self.isRunning = false
                }
            }
        }
    }

    func stop() {
        wantsCamera = false
        runID = UUID() // ignore callbacks queued by the previous session
        watchdog?.cancel()
        pipeline.stop()
        frame = HandFrame(timestamp: ProcessInfo.processInfo.systemUptime)
        isRunning = false
        status = "Camera stopped"
    }
}

/// AVCaptureSession, Vision and gesture state are all confined to `queue`.
/// The unchecked conformance allows handing the worker to that queue; no mutable
/// capture state is read from the main actor.
private final class CameraPipeline: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    enum Update: Sendable {
        case frame(HandFrame)
        case status(String, Bool)
        case report(String)
    }
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "airkey.capture", qos: .userInitiated)
    private let output = AVCaptureVideoDataOutput()
    private let detector = HandPoseDetector()
    private let engine = GestureEngine()
    private var callback: (@Sendable (Update) -> Void)?
    private var pacer = FramePacer()
    private var continuity = PointerContinuity()
    private var diagnostics = TrackingDiagnostics()
    private var cameraGhostEnabled = true
    private lazy var ghostRenderer = CameraGhostRenderer()

    func start(callback: @escaping @Sendable (Update) -> Void) {
        queue.async { [self] in
            self.callback = callback
            engine.reset()
            detector.reset()
            continuity = PointerContinuity()
            diagnostics = TrackingDiagnostics()
            pacer = FramePacer()
            do {
                try configureIfNeeded()
                if !session.isRunning { session.startRunning() }
                callback(.status(session.isRunning ? "Show an open hand to begin" : "Camera could not start. Retry.", session.isRunning))
            } catch {
                callback(.status(error.localizedDescription, false))
            }
        }
    }

    func stop() {
        queue.async { [self] in
            callback = nil
            if session.isRunning { session.stopRunning() }
            engine.reset()
        }
    }

    func setPinchThreshold(_ threshold: Double) {
        queue.async { [self] in engine.setCloseThreshold(threshold); continuity = PointerContinuity() }
    }

    func setCameraGhostEnabled(_ enabled: Bool) {
        queue.async { [self] in cameraGhostEnabled = enabled }
    }


    private func configureIfNeeded() throws {
        guard session.inputs.isEmpty else { return }
        guard let device = AVCaptureDevice.default(for: .video) else { throw CameraError.unavailable }
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .vga640x480
        guard session.canAddInput(input) else { throw CameraError.input }
        session.addInput(input)
        // Avoid capturing 60 fps only to discard half of it, where the device permits.
        if device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }) {
            if (try? device.lockForConfiguration()) != nil {
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
                device.unlockForConfiguration()
            }
        }
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            session.removeInput(input)
            throw CameraError.output
        }
        session.addOutput(output)
        if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let callback else { return }
        autoreleasepool {
            // Monotonic arrival time is shared with the interruption watchdog.
            let timestamp = ProcessInfo.processInfo.systemUptime
            guard pacer.shouldProcess(at: timestamp) else { return }
            let observations = detector.detect(from: sampleBuffer)
            let inferenceTime = ProcessInfo.processInfo.systemUptime - timestamp
            pacer.observedHands(!observations.isEmpty, at: timestamp)
            var frame = engine.process(observations: observations, timestamp: timestamp)
            if let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                frame.imageSize = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
                // Missing hand evidence yields transparency, never room video.
                if cameraGhostEnabled { frame.cameraImage = ghostRenderer.render(buffer, poses: observations.compactMap(\.maskPose)) }
            }
            callback(.frame(continuity.apply(to: frame)))
            if let report = diagnostics.record(at: timestamp, inference: inferenceTime,
                rawHands: detector.rawHandCount, rejected: detector.rejectedHandCount,
                uncertainSides: detector.uncertainSideCount, aimOnly: observations.contains(where: { !$0.pinchIsReliable })) {
                callback(.report(report))
            }
        }
    }

    private enum CameraError: LocalizedError {
        case unavailable, input, output
        var errorDescription: String? {
            switch self {
            case .unavailable: "No camera found. Connect a camera and retry."
            case .input: "Cannot attach the camera input. Close other camera apps and retry."
            case .output: "Cannot configure camera frames. Stop and retry."
            }
        }
    }
}
