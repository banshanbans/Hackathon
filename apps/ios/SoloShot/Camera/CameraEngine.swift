@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import ImageIO

enum CameraPressureLevel: Equatable, Sendable {
    case nominal
    case degraded
    case critical
}

enum CameraPressurePolicy {
    static func effective(
        device: CameraPressureLevel,
        thermal: CameraPressureLevel
    ) -> CameraPressureLevel {
        if device == .critical || thermal == .critical { return .critical }
        if device == .degraded || thermal == .degraded { return .degraded }
        return .nominal
    }

    static func thermalLevel(_ state: ProcessInfo.ThermalState) -> CameraPressureLevel {
        switch state {
        case .nominal, .fair: .nominal
        case .serious: .degraded
        case .critical: .critical
        @unknown default: .degraded
        }
    }
}

enum CameraEvent: Sendable {
    case observations(
        [PersonObservation],
        silhouette: SilhouetteObservation?,
        imageSize: CGSize,
        visionLatencyMilliseconds: Double
    )
    case interrupted
    case interruptionEnded
    case pressure(CameraPressureLevel)
    case failed(CameraFailure)
}

struct CaptureRecordingResult: Equatable, Sendable {
    let url: URL
    let durationSeconds: Double
}

final class CameraEngine: NSObject, @unchecked Sendable {
    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "ai.soloshot.camera.session")
    private let outputQueue = DispatchQueue(label: "ai.soloshot.camera.vision", qos: .userInitiated)
    private let vision: VisionEngine
    private let silhouetteEngine = LiveSilhouetteEngine()
    private let configuration: AlignmentConfiguration
    private let photoOutput = AVCapturePhotoOutput()
    private var continuation: AsyncStream<CameraEvent>.Continuation?
    private var inputDevice: AVCaptureDevice?
    private var pressureObservation: NSKeyValueObservation?
    private var notificationTokens: [NSObjectProtocol] = []
    private var lastSampleUptime = 0.0
    private var currentSampleInterval: TimeInterval
    private var devicePressure: CameraPressureLevel = .nominal
    private var thermalPressure: CameraPressureLevel = .nominal
    private var visionOrientation = CGImagePropertyOrientation.up
    private var isConfigured = false
    private var recorder: SampleBufferMovieRecorder?
    private let photoDelegateLock = NSLock()
    private var photoDelegates: [Int64: PhotoCaptureDelegate] = [:]

    init(configuration: AlignmentConfiguration = .production) {
        self.configuration = configuration
        vision = VisionEngine(configuration: configuration)
        currentSampleInterval = configuration.nominalSampleInterval
        super.init()
    }

    deinit {
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        pressureObservation?.invalidate()
        continuation?.finish()
    }

    func events() -> AsyncStream<CameraEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(2)) { continuation in
            self.continuation = continuation
        }
    }

    func configure() async throws {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async { [self] in
                do {
                    try configureOnSessionQueue()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func start() async {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [self] in
                if isConfigured, !session.isRunning {
                    session.startRunning()
                }
                continuation.resume()
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [self] in
                if session.isRunning {
                    session.stopRunning()
                }
                continuation.resume()
            }
        }
    }

    func capturePhotoBurst(count: Int = 3, intervalMilliseconds: Int = 180) async throws -> [Data] {
        guard isConfigured, session.isRunning else { throw CameraFailure.unavailable }
        var results: [Data] = []
        for index in 0 ..< min(max(count, 1), 3) {
            try Task.checkCancellation()
            results.append(try await capturePhoto())
            if index < count - 1 {
                try await Task.sleep(for: .milliseconds(intervalMilliseconds))
            }
        }
        return results
    }

    func startShortVideo(to url: URL) async throws {
        guard isConfigured, session.isRunning else { throw CameraFailure.unavailable }
        let free = ((try? FileManager.default.attributesOfFileSystem(forPath: url.deletingLastPathComponent().path)[.systemFreeSize]) as? NSNumber)?.int64Value ?? 0
        guard free >= 100 * 1_024 * 1_024 else { throw CameraFailure.insufficientStorage }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            outputQueue.async { [self] in
                guard recorder == nil else {
                    continuation.resume(throwing: CameraFailure.recordingFailed)
                    return
                }
                guard CameraPressurePolicy.effective(device: devicePressure, thermal: thermalPressure) != .critical else {
                    continuation.resume(throwing: CameraFailure.criticalPressure)
                    return
                }
                do {
                    recorder = try SampleBufferMovieRecorder(url: url)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: CameraFailure.recordingFailed)
                }
            }
        }
    }

    func stopShortVideo() async throws -> CaptureRecordingResult {
        try await withCheckedThrowingContinuation { continuation in
            outputQueue.async { [self] in
                guard let active = recorder else {
                    continuation.resume(throwing: CameraFailure.recordingFailed)
                    return
                }
                recorder = nil
                active.finish { result in
                    continuation.resume(with: result)
                }
            }
        }
    }

    func cancelShortVideo() async {
        await withCheckedContinuation { continuation in
            outputQueue.async { [self] in
                recorder?.cancel()
                recorder = nil
                continuation.resume()
            }
        }
    }

    private func configureOnSessionQueue() throws {
        guard !isConfigured else { return }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw CameraFailure.unavailable
        }
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw CameraFailure.configurationFailed
        }
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ]
        output.setSampleBufferDelegate(self, queue: outputQueue)

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .hd1280x720
        guard session.canAddInput(input), session.canAddOutput(output), session.canAddOutput(photoOutput) else {
            throw CameraFailure.configurationFailed
        }
        session.addInput(input)
        session.addOutput(output)
        session.addOutput(photoOutput)
        if let connection = output.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
                visionOrientation = .up
            } else {
                visionOrientation = .right
            }
            connection.isVideoMirrored = false
        }
        if let connection = photoOutput.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = 1
            device.unlockForConfiguration()
        } catch {
            throw CameraFailure.configurationFailed
        }
        inputDevice = device
        installObservers(device: device)
        isConfigured = true
    }

    private func capturePhoto() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async { [self] in
                let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                settings.photoQualityPrioritization = .speed
                let identifier = settings.uniqueID
                let delegate = PhotoCaptureDelegate { [weak self] result in
                    self?.photoDelegateLock.lock()
                    self?.photoDelegates.removeValue(forKey: identifier)
                    self?.photoDelegateLock.unlock()
                    continuation.resume(with: result)
                }
                photoDelegateLock.lock()
                photoDelegates[identifier] = delegate
                photoDelegateLock.unlock()
                photoOutput.capturePhoto(with: settings, delegate: delegate)
            }
        }
    }

    private func installObservers(device: AVCaptureDevice) {
        pressureObservation = device.observe(\.systemPressureState, options: [.initial, .new]) { [weak self] _, change in
            guard let self, let state = change.newValue else { return }
            let pressure: CameraPressureLevel = switch state.level {
            case .nominal, .fair:
                .nominal
            case .serious:
                .degraded
            case .critical, .shutdown:
                .critical
            default:
                .degraded
            }
            outputQueue.async { [weak self] in
                self?.devicePressure = pressure
                self?.publishEffectivePressure()
            }
        }
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: ProcessInfo.processInfo,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            let pressure = CameraPressurePolicy.thermalLevel(ProcessInfo.processInfo.thermalState)
            outputQueue.async { [weak self] in
                self?.thermalPressure = pressure
                self?.publishEffectivePressure()
            }
        })
        outputQueue.async { [weak self] in
            guard let self else { return }
            thermalPressure = CameraPressurePolicy.thermalLevel(ProcessInfo.processInfo.thermalState)
            publishEffectivePressure()
        }
        notificationTokens.append(center.addObserver(
            forName: .AVCaptureSessionWasInterrupted,
            object: session,
            queue: nil
        ) { [weak self] _ in
            self?.continuation?.yield(.interrupted)
        })
        notificationTokens.append(center.addObserver(
            forName: .AVCaptureSessionInterruptionEnded,
            object: session,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            sessionQueue.async { [weak self] in
                guard let self else { return }
                if session.isRunning {
                    session.stopRunning()
                }
                continuation?.yield(.interruptionEnded)
            }
        })
        notificationTokens.append(center.addObserver(
            forName: .AVCaptureSessionRuntimeError,
            object: session,
            queue: nil
        ) { [weak self] notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError
            let failure: CameraFailure = error?.code == .mediaServicesWereReset
                ? .mediaServicesReset
                : .runtimeError
            self?.continuation?.yield(.failed(failure))
        })
    }

    private func publishEffectivePressure() {
        let effective = CameraPressurePolicy.effective(
            device: devicePressure,
            thermal: thermalPressure
        )
        switch effective {
        case .nominal:
            currentSampleInterval = configuration.nominalSampleInterval
        case .degraded:
            currentSampleInterval = configuration.degradedSampleInterval
        case .critical:
            currentSampleInterval = .infinity
        }
        continuation?.yield(.pressure(effective))
    }
}

extension CameraEngine: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        recorder?.append(sampleBuffer)
        let uptime = ProcessInfo.processInfo.systemUptime
        guard uptime - lastSampleUptime >= currentSampleInterval else { return }
        lastSampleUptime = uptime
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let started = ProcessInfo.processInfo.systemUptime
        do {
            let observedAt = Date()
            let observations = try vision.observations(
                pixelBuffer: pixelBuffer,
                orientation: visionOrientation,
                observedAt: observedAt
            )
            let credible = observations.filter {
                $0.confidence >= configuration.crediblePersonConfidence
            }
            let silhouette: SilhouetteObservation?
            if credible.count == 1 {
                silhouette = try? silhouetteEngine.observation(
                    pixelBuffer: pixelBuffer,
                    orientation: visionOrientation,
                    person: credible[0],
                    observedAt: observedAt
                )
            } else {
                silhouette = nil
            }
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            continuation?.yield(.observations(
                observations,
                silhouette: silhouette,
                imageSize: CGSize(width: width, height: height),
                visionLatencyMilliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1_000
            ))
        } catch {
            continuation?.yield(.failed(.runtimeError))
        }
    }
}
