// OpenVision - PhoneCameraService.swift
// AUR-723b: the iPhone's own rear camera as the live-mode eye when no glasses are paired.
//
// Live mode used to get frames ONLY from `GlassesManager.onVideoFrame`, so on a phone-only rig
// the brain received zero `input_image` items — the wearer asks "what do you see" and she has
// never been shown anything (found on the phone-only rig 2026-08-17: talk-over worked, vision
// was silent). This service feeds the SAME path the glasses use: a UIImage per frame → the
// ViewModel JPEGs it at q0.6 → `sendVideoFrame` → `conversation.item.create {input_image}`.
//
// Deliberately small: 640x480 capture preset (≈640 px long side), ~1 fps, late frames discarded.
// It never touches the audio session (`automaticallyConfiguresApplicationAudioSession = false`) —
// the full-duplex `.playAndRecord` + VPIO session set up by AudioSessionManager must survive the
// camera coming and going.

import AVFoundation
import UIKit

/// Converts capture buffers to UIImages off the main actor, at a capped frame rate.
/// The delegate callback runs on the capture queue — nothing here hops to the main actor except
/// the finished frame.
private final class PhoneCameraFrameProxy: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    /// Minimum seconds between delivered frames.
    var minInterval: TimeInterval = 1.0
    /// Called on the capture queue with a converted frame.
    var onFrame: ((UIImage) -> Void)?

    private var lastDelivered: CFTimeInterval = 0
    private let context = CIContext(options: [.useSoftwareRenderer: false])

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        guard now - lastDelivered >= minInterval else { return }
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ci = CIImage(cvPixelBuffer: pixels)
        guard let cg = context.createCGImage(ci, from: ci.extent) else { return }
        lastDelivered = now
        onFrame?(UIImage(cgImage: cg))
    }
}

/// The iPhone rear camera, as a frame source for live mode.
@MainActor
final class PhoneCameraService: ObservableObject {
    static let shared = PhoneCameraService()

    // MARK: - State

    @Published private(set) var isRunning = false
    /// Last frame sent — lets the UI show what she is actually being shown.
    @Published private(set) var lastFrame: UIImage?
    private(set) var lastFrameTime: Date = .distantPast

    /// Delivered on the main actor, ~`framesPerSecond` times a second.
    var onFrame: ((UIImage) -> Void)?

    /// Frame rate handed upstream (the realtime service throttles again on its own setting).
    var framesPerSecond: Double = 1.0

    // MARK: - Capture graph

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "app.soulless.openvision.phone-camera", qos: .userInitiated)
    private let proxy = PhoneCameraFrameProxy()
    private var configured = false

    enum StartResult: Equatable {
        case started
        /// The user said no to the camera prompt (or it is restricted).
        case denied
        /// No usable rear camera / the graph could not be built.
        case unavailable(String)
    }

    private init() {}

    // MARK: - Lifecycle

    /// Ask for permission if needed, build the graph once, and start delivering frames.
    func start() async -> StartResult {
        guard !isRunning else { return .started }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard granted else { return .denied }
        case .denied, .restricted:
            return .denied
        @unknown default:
            return .denied
        }

        if !configured {
            do { try configure() } catch {
                return .unavailable(error.localizedDescription)
            }
            configured = true
        }

        isRunning = true
        // startRunning blocks; keep it off the main actor. The proxy's callback + interval are
        // written on the CAPTURE queue (the only thread that reads them) — assigning them from
        // the main actor while a buffer is being handled would be a data race on the closure.
        let session = self.session
        let proxy = self.proxy
        let interval = 1.0 / max(0.2, framesPerSecond)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async { [weak self] in
                proxy.minInterval = interval
                proxy.onFrame = { image in
                    Task { @MainActor in
                        guard let self, self.isRunning else { return }
                        self.lastFrame = image
                        self.lastFrameTime = Date()
                        self.onFrame?(image)
                    }
                }
                if !session.isRunning { session.startRunning() }
                cont.resume()
            }
        }
        ovLog("[PhoneCamera] Started (\(Int(framesPerSecond)) fps, 640x480 rear)")
        return .started
    }

    func stop() {
        guard isRunning || session.isRunning else { return }
        isRunning = false
        onFrame = nil
        lastFrame = nil
        lastFrameTime = .distantPast
        let session = self.session
        let proxy = self.proxy
        queue.async {
            proxy.onFrame = nil
            if session.isRunning { session.stopRunning() }
        }
        ovLog("[PhoneCamera] Stopped")
    }

    /// True when the user has already refused the camera (so the app says it once, not per frame).
    var isPermissionDenied: Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        return status == .denied || status == .restricted
    }

    // MARK: - Graph

    private func configure() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // NEVER let the capture session touch our audio session: live mode is mid-conversation on
        // a `.playAndRecord` + voice-processing route and a reconfigure would kill the duplex.
        session.automaticallyConfiguresApplicationAudioSession = false
        session.usesApplicationAudioSession = true

        // 640x480 is plenty for "what am I looking at" and keeps the JPEG (q0.6) a few tens of kB.
        session.sessionPreset = session.canSetSessionPreset(.vga640x480) ? .vga640x480 : .low

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(for: .video) else {
            throw PhoneCameraError.noCamera
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw PhoneCameraError.cannotAddInput }
        session.addInput(input)

        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(proxy, queue: queue)
        guard session.canAddOutput(output) else { throw PhoneCameraError.cannotAddOutput }
        session.addOutput(output)

        // Portrait-up frames: the raw buffer is landscape, and a sideways photo makes the model
        // describe a sideways world.
        if let connection = output.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
        }
    }
}

enum PhoneCameraError: LocalizedError {
    case noCamera
    case cannotAddInput
    case cannotAddOutput

    var errorDescription: String? {
        switch self {
        case .noCamera: return "No rear camera available"
        case .cannotAddInput: return "Could not attach the camera input"
        case .cannotAddOutput: return "Could not attach the camera output"
        }
    }
}
