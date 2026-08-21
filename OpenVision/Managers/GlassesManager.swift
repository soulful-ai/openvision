// OpenVision - GlassesManager.swift
// Singleton manager for Meta Ray-Ban glasses via DAT SDK

import Foundation
import SwiftUI
import CoreMedia
import MWDATCore
import MWDATCamera

/// Manages Meta Ray-Ban glasses registration, connection, and camera streaming
@MainActor
final class GlassesManager: ObservableObject {
    // MARK: - Singleton

    static let shared = GlassesManager()

    // MARK: - Published Properties

    /// Whether the app is registered with Meta AI
    @Published var isRegistered: Bool = false

    /// Currently connected device identifier
    @Published var connectedDevice: DeviceIdentifier?

    /// Number of connected devices
    @Published var connectedDeviceCount: Int = 0

    /// Whether camera streaming is active
    @Published var isStreaming: Bool = false

    /// The stream session's REAL state (AUR-783). `isStreaming` flips true when `session.start()`
    /// returns, which can be BEFORE the media pipeline is live (`.starting`) — and the SDK silently
    /// drops a photo-capture request sent in that window ("Not started so photo request won't be
    /// made"). Native capture waits for `.streaming` on this property first.
    @Published private(set) var streamState: StreamSessionState = .stopped

    /// Last captured video frame
    @Published var lastFrame: UIImage?

    /// When `lastFrame` was received. Lets the live loop tell a fresh frame from a stale one when
    /// the Bluetooth stream throttles under head motion (so it doesn't describe an old view).
    private(set) var lastFrameTime: Date = .distantPast

    /// Last captured photo data
    @Published var lastPhotoData: Data?

    /// Error message for UI display
    @Published var errorMessage: String?

    // MARK: - Private Properties

    /// AUR-845: accessed lazily, never stored. `Wearables.shared` **fatalErrors** when
    /// `Wearables.configure()` did not succeed — and on the SIMULATOR it never does
    /// (`WearablesError(rawValue: 0)`), so a stored property here crashed the unit-test host app
    /// before the test bundle could even connect. Glasses are device-only anyway.
    private var wearables: any WearablesInterface { Wearables.shared }
    private var streamSession: StreamSession?

    // Listener tokens (retained to keep subscriptions active)
    private var registrationTask: Task<Void, Never>?
    private var devicesTask: Task<Void, Never>?
    private var stateListenerToken: (any AnyListenerToken)?

    /// One-shot waiter for a native photo (AUR-783). Resolved by the photoDataPublisher listener,
    /// or with nil by the timeout / stopStreaming. Generation counter guards a stale timeout task
    /// from resolving a LATER capture's continuation.
    private var nativePhotoContinuation: CheckedContinuation<Data?, Never>?
    private var nativePhotoGeneration = 0
    private var videoFrameListenerToken: (any AnyListenerToken)?
    private var photoDataListenerToken: (any AnyListenerToken)?
    private var errorListenerToken: (any AnyListenerToken)?

    // MARK: - Callbacks

    /// Called when a video frame is received
    var onVideoFrame: ((UIImage) -> Void)?

    /// Called with the raw sample buffer for every video frame — used by SessionRecorder to mux
    /// the glasses POV into a movie file without going through UIImage. Independent of `onVideoFrame`.
    var onVideoSampleBuffer: ((CMSampleBuffer) -> Void)?

    /// Called when a photo is captured
    var onPhotoCaptured: ((Data) -> Void)?

    // MARK: - Initialization

    private init() {
        print("[GlassesManager] Initializing")
#if targetEnvironment(simulator)
        // No DAT SDK on the simulator: touching `Wearables.shared` here is a hard crash. The
        // manager stays inert (no glasses to register) so `xcodebuild test` has a host that boots.
        print("[GlassesManager] simulator — Wearables listeners not armed")
#else
        setupRegistrationListener()
        setupDevicesListener()
#endif
    }

    // MARK: - Registration

    /// Register app with Meta AI
    func register() async throws {
        print("[GlassesManager] Starting registration")

        // Check if already registered
        for await state in wearables.registrationStateStream() {
            if case .registered = state {
                print("[GlassesManager] Already registered")
                isRegistered = true
                return
            }
            break
        }

        // Start registration flow
        try await wearables.startRegistration()
        print("[GlassesManager] Registration initiated, waiting for Meta AI callback")
    }

    /// Unregister app from Meta AI
    func unregister() async {
        print("[GlassesManager] Starting unregistration")

        // Stop streaming first if active
        if isStreaming {
            await stopStreaming()
        }

        do {
            try await wearables.startUnregistration()
            isRegistered = false
            connectedDevice = nil
            connectedDeviceCount = 0
            errorMessage = nil
            print("[GlassesManager] Unregistration successful")
        } catch {
            errorMessage = "Unregister failed: \(error.localizedDescription)"
            print("[GlassesManager] Unregistration error: \(error)")
        }
    }

    // MARK: - Streaming

    /// Start camera streaming from glasses
    func startStreaming() async {
        guard isRegistered else {
            errorMessage = "Not registered with Meta AI"
            print("[GlassesManager] Cannot start streaming - not registered")
            return
        }

        guard !isStreaming else {
            print("[GlassesManager] Already streaming")
            return
        }

        // Check for connected device
        guard let deviceId = connectedDevice else {
            errorMessage = "No glasses connected"
            print("[GlassesManager] Cannot start streaming - no device connected")
            return
        }

        print("[GlassesManager] Starting camera stream for device: \(deviceId)")

        // Request camera permission first (like xmeta does)
        do {
            var status = try await wearables.checkPermissionStatus(.camera)
            print("[GlassesManager] Camera permission status: \(status)")

            if status != .granted {
                print("[GlassesManager] Requesting camera permission...")
                status = try await wearables.requestPermission(.camera)
                print("[GlassesManager] After request, status: \(status)")
            }

            guard status == .granted else {
                errorMessage = "Camera permission denied"
                print("[GlassesManager] Camera permission not granted")
                return
            }
        } catch {
            errorMessage = "Permission error: \(error.localizedDescription)"
            print("[GlassesManager] Permission error: \(error)")
            return
        }

        // Use SpecificDeviceSelector like xmeta does (more reliable than AutoDeviceSelector)
        let specificSelector = SpecificDeviceSelector(device: deviceId)

        // Configure stream session. Resolution: .high = 720×1280 — the SDK's ceiling (the enum is
        // high/medium/low = 720×1280 / 504×896 / 360×640; verified against MWDATCamera 0.4.0).
        // AUR-783: was .medium (the ~500×900 stills/videos of Anton's field report); high doubles
        // the pixel count for the stream-frame photo fallback AND the POV recorder. ABR adapts the
        // bitrate under a weak link, so a stall falls back in quality, not in frames.
        let config = StreamSessionConfig(
            videoCodec: .raw,
            resolution: .high,
            frameRate: 30
        )

        streamSession = StreamSession(
            streamSessionConfig: config,
            deviceSelector: specificSelector
        )

        guard let session = streamSession else {
            errorMessage = "Failed to create stream session"
            print("[GlassesManager] Failed to create stream session")
            return
        }

        // Set up listeners
        setupStreamListeners(session: session)

        // Start streaming
        print("[GlassesManager] Starting stream session...")
        await session.start()
        isStreaming = true
        print("[GlassesManager] Streaming started successfully")
    }

    /// Stop camera streaming
    func stopStreaming() async {
        guard isStreaming, let session = streamSession else { return }

        print("[GlassesManager] Stopping camera stream")

        await session.stop()

        // A native photo still in flight will never arrive now.
        resolveNativePhoto(nil)

        cleanupStreamListeners()
        streamSession = nil
        isStreaming = false
        streamState = .stopped
        lastFrame = nil
        lastFrameTime = .distantPast

        print("[GlassesManager] Streaming stopped")
    }

    /// Fire-and-forget photo request (legacy path — result arrives via `onPhotoCaptured` /
    /// `lastPhotoData`). Prefer `captureNativePhoto(timeout:)`, which owns the wait + timeout.
    func capturePhoto() async {
        guard isStreaming, let session = streamSession else {
            errorMessage = "Streaming must be active to capture photos"
            return
        }
        print("[GlassesManager] Capturing photo (fire-and-forget)")
        if !session.capturePhoto(format: .jpeg) {
            errorMessage = "Photo capture request not accepted"
            print("[GlassesManager] Photo capture request refused (pipeline not started / capture already pending)")
        }
    }

    /// One-shot NATIVE photo from the glasses' own capture pipeline (AUR-783) — the path Meta AI
    /// uses for its full-quality stills, far above the 720p stream frames. Contract observed in
    /// MWDATCamera 0.4.0:
    ///   • needs the stream session's media pipeline fully live (state `.streaming`) — earlier
    ///     requests are silently dropped, which is exactly the guaranteed 5 s timeout AUR-776 hit
    ///     (`isStreaming` turns true before the pipeline does);
    ///   • `capturePhoto(format:)` returns Bool = "request accepted", the JPEG lands later on
    ///     `photoDataPublisher`;
    ///   • the device PAUSES the video stream for the capture (state `.paused`) and resumes it
    ///     itself — the session survives, our state listener keeps `isStreaming` true through it.
    /// Returns nil on refusal/timeout — callers fall back to a stream frame.
    func captureNativePhoto(timeout: TimeInterval = 10.0) async -> Data? {
        guard isStreaming, let session = streamSession else {
            print("[GlassesManager] Native photo: no active stream session")
            return nil
        }
        guard nativePhotoContinuation == nil else {
            print("[GlassesManager] Native photo: a capture is already in flight")
            return nil
        }
        // Wait out the `.starting` window — the silent-drop zone.
        guard await waitForStreamState(.streaming, timeout: 4.0) else {
            print("[GlassesManager] Native photo: stream never reached .streaming (state=\(streamState)) — skipping")
            return nil
        }

        nativePhotoGeneration += 1
        let gen = nativePhotoGeneration
        let t0 = Date()
        let data = await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            nativePhotoContinuation = cont
            // Arm BEFORE requesting — the photo can land fast.
            if !session.capturePhoto(format: .jpeg) {
                print("[GlassesManager] Native photo: request refused, retrying once in 400 ms")
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    guard let self, self.nativePhotoGeneration == gen,
                          self.nativePhotoContinuation != nil else { return }
                    if let s = self.streamSession, s.capturePhoto(format: .jpeg) { return }
                    print("[GlassesManager] Native photo: retry refused too")
                    self.resolveNativePhoto(nil)
                }
            }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self, self.nativePhotoGeneration == gen,
                      self.nativePhotoContinuation != nil else { return }
                print("[GlassesManager] Native photo: timed out after \(timeout)s")
                self.resolveNativePhoto(nil)
            }
        }
        if let data {
            print("[GlassesManager] Native photo: \(data.count) bytes in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
        }
        return data
    }

    private func resolveNativePhoto(_ data: Data?) {
        nativePhotoContinuation?.resume(returning: data)
        nativePhotoContinuation = nil
    }

    /// Poll the published stream state (main-actor) until it hits `target` or the timeout passes.
    private func waitForStreamState(_ target: StreamSessionState, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while streamState != target {
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return true
    }

    // MARK: - Private Methods

    private func setupRegistrationListener() {
        registrationTask = Task {
            for await state in wearables.registrationStateStream() {
                await MainActor.run {
                    if case .registered = state {
                        self.isRegistered = true
                        print("[GlassesManager] Registration state: registered")
                    } else {
                        self.isRegistered = false
                        print("[GlassesManager] Registration state: \(state)")
                    }
                }
            }
        }
    }

    private func setupDevicesListener() {
        devicesTask = Task {
            for await devices in wearables.devicesStream() {
                await MainActor.run {
                    self.connectedDeviceCount = devices.count
                    self.connectedDevice = devices.first
                    print("[GlassesManager] Devices updated: \(devices.count) connected")
                }
            }
        }
    }

    private func setupStreamListeners(session: StreamSession) {
        // State listener
        stateListenerToken = session.statePublisher.listen { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                self.streamState = state
                switch state {
                case .streaming:
                    self.isStreaming = true
                case .stopped:
                    self.isStreaming = false
                default:
                    // .paused = a native photo capture is in flight (the device pauses video for
                    // the still and resumes on its own) — the session is alive, keep isStreaming.
                    break
                }
            }
        }

        // Video frame listener
        videoFrameListenerToken = session.videoFramePublisher.listen { [weak self] frame in
            Task { @MainActor in
                // Hand the raw sample buffer to the recorder (if any). SessionRecorder immediately
                // hops it onto its own writer queue, so this stays cheap even at 30fps.
                self?.onVideoSampleBuffer?(frame.sampleBuffer)
                if let image = frame.makeUIImage() {
                    self?.lastFrame = image
                    self?.lastFrameTime = Date()
                    self?.onVideoFrame?(image)
                }
            }
        }

        // Photo data listener
        photoDataListenerToken = session.photoDataPublisher.listen { [weak self] photoData in
            Task { @MainActor in
                guard let self else { return }
                let data = photoData.data
                self.lastPhotoData = data
                self.onPhotoCaptured?(data)
                self.resolveNativePhoto(data)
                print("[GlassesManager] Photo captured: \(data.count) bytes")
            }
        }

        // Error listener
        errorListenerToken = session.errorPublisher.listen { [weak self] error in
            Task { @MainActor in
                self?.errorMessage = error.localizedDescription
                print("[GlassesManager] Stream error: \(error)")
            }
        }
    }

    private func cleanupStreamListeners() {
        stateListenerToken = nil
        videoFrameListenerToken = nil
        photoDataListenerToken = nil
        errorListenerToken = nil
    }
}
