@preconcurrency import AVFoundation
import Combine
import Foundation
import OSLog
import UIKit

struct AlignmentCompletion: Equatable, Sendable {
    let mode: AlignmentCompletionMode
    let completedAt: Date
    let isFixture: Bool
}

@MainActor
final class AlignmentSessionModel: ObservableObject {
    @Published private(set) var decision: AlignmentDecision?
    @Published private(set) var imageSize = CGSize(width: 720, height: 1_280)
    @Published private(set) var pressure: CameraPressureLevel = .nominal
    @Published private(set) var isInterrupted = false
    @Published private(set) var interruptionEnded = false
    @Published private(set) var failure: CameraFailure?
    @Published private(set) var visionLatencyMilliseconds = 0.0
    @Published private(set) var observedFramesPerSecond = 0.0
    @Published private(set) var manualOverrideAvailable = false

    let task: ImportedTask
    let target: ImportedTargetLayout
    let isFixture: Bool
    let cameraSession: AVCaptureSession?

    private let camera: CameraEngine?
    private let feedback = CoachFeedbackController()
    private let logger = Logger(subsystem: "ai.soloshot.app", category: "alignment")
    private var engine: AlignmentEngine
    private var streamTask: Task<Void, Never>?
    private var fixtureTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var completionDelivered = false
    private var observationCount = 0
    private var observationWindowStarted = Date()
    private var voiceEnabled: Bool
    private var hapticsEnabled: Bool
    private let onReady: @MainActor (AlignmentCompletion) -> Void
    private let onExpired: @MainActor () -> Void

    init(
        task: ImportedTask,
        target: ImportedTargetLayout,
        isFixture: Bool,
        voiceEnabled: Bool,
        hapticsEnabled: Bool,
        onReady: @escaping @MainActor (AlignmentCompletion) -> Void,
        onExpired: @escaping @MainActor () -> Void
    ) {
        self.task = task
        self.target = target
        self.isFixture = isFixture
        self.voiceEnabled = voiceEnabled
        self.hapticsEnabled = hapticsEnabled
        self.onReady = onReady
        self.onExpired = onExpired
        engine = AlignmentEngine(target: target)
        if isFixture {
            camera = nil
            cameraSession = nil
        } else {
            let camera = CameraEngine()
            self.camera = camera
            cameraSession = camera.session
        }
    }

    deinit {
        streamTask?.cancel()
        fixtureTask?.cancel()
        expiryTask?.cancel()
    }

    func start() async throws {
        scheduleExpiry()
        if isFixture {
            startFixture()
            return
        }
        guard let camera else { throw CameraFailure.unavailable }
        let events = camera.events()
        streamTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                await self?.handle(event)
            }
        }
        do {
            try await camera.configure()
            await camera.start()
        } catch let failure as CameraFailure {
            self.failure = failure
            throw failure
        } catch {
            failure = .configurationFailed
            throw CameraFailure.configurationFailed
        }
    }

    func stop() async {
        streamTask?.cancel()
        fixtureTask?.cancel()
        expiryTask?.cancel()
        feedback.stop()
        if let camera {
            await camera.stop()
        }
    }

    func resumeAfterInterruption() async {
        guard interruptionEnded else { return }
        isInterrupted = false
        interruptionEnded = false
        if let camera {
            await camera.start()
        }
    }

    func updateFeedback(voiceEnabled: Bool, hapticsEnabled: Bool) {
        self.voiceEnabled = voiceEnabled
        self.hapticsEnabled = hapticsEnabled
    }

    func confirmManualReady() {
        guard manualOverrideAvailable || decision?.manualReadyAvailable == true else { return }
        deliver(engine.manualCompletion())
    }

    func resumeAlignment() {
        completionDelivered = false
        engine = AlignmentEngine(target: target)
    }

    func captureCandidates(
        method requestedMethod: LocalCaptureMethod,
        roundIndex: Int,
        store: CaptureWorkStore
    ) async throws -> (method: LocalCaptureMethod, candidates: [CaptureCandidate], sourceFilename: String?) {
        if isFixture {
#if DEBUG
            if requestedMethod == .shortVideo,
               ProcessInfo.processInfo.arguments.contains("-W5FixtureVideoFailure")
            {
                throw CameraFailure.recordingFailed
            }
#endif
            return try await fixtureCandidates(
                method: requestedMethod,
                roundIndex: roundIndex,
                store: store
            )
        }
        guard let camera else { throw CameraFailure.unavailable }
        let capture = CaptureEngine(camera: camera)
        let frames: [RawCapturedFrame]
        let sourceFilename: String?
        switch requestedMethod {
        case .photo, .photoFallback:
            frames = try await capture.capturePhotos()
            sourceFilename = nil
        case .shortVideo:
            let directory = store.directory
            let result = try await capture.captureShortVideo(directory: directory)
            frames = result.frames
            sourceFilename = result.sourceURL.lastPathComponent
        }
        var inputs: [CandidateInput] = []
        for frame in frames {
            let processed = try await CandidateFrameProcessor.process(jpeg: frame.jpeg, target: target)
            let frameID = "frame_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
            let filename = try await store.saveCandidateJPEG(
                processed.jpeg,
                roundIndex: roundIndex,
                frameID: frameID
            )
            inputs.append(CandidateInput(
                frameID: frameID,
                timestampMilliseconds: frame.timestampMilliseconds,
                localFilename: filename,
                metrics: processed.metrics
            ))
        }
        if requestedMethod == .shortVideo {
            inputs = FrameSelectionEngine.temporallySpaced(inputs)
        }
        return (requestedMethod, FrameSelectionEngine.rank(inputs), sourceFilename)
    }

    private func handle(_ event: CameraEvent) async {
        switch event {
        case let .observations(observations, size, latency):
            imageSize = size
            visionLatencyMilliseconds = latency
            updateFPS()
            deliver(engine.process(observations: observations))
        case .interrupted:
            isInterrupted = true
            interruptionEnded = false
            logger.warning("camera interrupted")
        case .interruptionEnded:
            interruptionEnded = true
            logger.info("camera interruption ended; waiting for user")
        case let .pressure(level):
            pressure = level
            if level == .critical {
                manualOverrideAvailable = true
                logger.warning("vision paused for critical system pressure")
            }
        case let .failed(failure):
            self.failure = failure
            logger.error("camera failure: \(failure.rawValue, privacy: .public)")
        }
    }

    private func deliver(_ result: AlignmentDecision) {
        decision = result
        manualOverrideAvailable = manualOverrideAvailable || result.manualReadyAvailable
        feedback.handle(
            decision: result,
            voiceEnabled: voiceEnabled,
            hapticsEnabled: hapticsEnabled
        )
        logger.debug("instruction=\(result.alignment.instructionCode.rawValue, privacy: .public) latency_ms=\(result.latencyMilliseconds, privacy: .public)")
        if let mode = result.completionMode, !completionDelivered {
            completionDelivered = true
            onReady(AlignmentCompletion(mode: mode, completedAt: Date(), isFixture: isFixture))
        }
    }

    private func updateFPS() {
        observationCount += 1
        let elapsed = Date().timeIntervalSince(observationWindowStarted)
        if elapsed >= 1 {
            observedFramesPerSecond = Double(observationCount) / elapsed
            observationCount = 0
            observationWindowStarted = Date()
        }
    }

    private func startFixture() {
        let scenario = Self.argumentValue(after: "-W4FixtureScenario") ?? "ready"
        fixtureTask = Task { [weak self] in
            guard let self else { return }
            var index = 0
            while !Task.isCancelled {
                let observations = fixtureObservations(index: index, scenario: scenario)
                deliver(engine.process(observations: observations))
                index += 1
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    private func scheduleExpiry() {
        let delay = task.expiresAt.timeIntervalSinceNow
        guard delay > 0 else {
            onExpired()
            return
        }
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.onExpired()
        }
    }

    private func fixtureObservations(index: Int, scenario: String) -> [PersonObservation] {
        guard scenario != "manual" else { return [] }
        if index < 3 { return [] }
        if index < 6 {
            return [fixturePerson(rect: target.rect), fixturePerson(rect: shiftedTargetRect(by: 0.22))]
        }
        if index < 9 { return [fixturePerson(rect: shiftedTargetRect(by: -0.18))] }
        return [fixturePerson(rect: target.rect)]
    }

    private func shiftedTargetRect(by offset: Double) -> NormalizedRect {
        NormalizedRect(
            x: target.rect.x + offset,
            y: target.rect.y,
            width: target.rect.width,
            height: target.rect.height
        )
    }

    private func fixturePerson(rect: NormalizedRect) -> PersonObservation {
        let centerX = rect.center.x
        var joints: [BodyJoint: PoseJoint] = [
            .nose: fixtureJoint(x: centerX, y: rect.y + 0.04),
            .neck: fixtureJoint(x: centerX, y: rect.y + 0.12),
            .leftShoulder: fixtureJoint(x: centerX - rect.width * 0.20, y: rect.y + rect.height * 0.22),
            .rightShoulder: fixtureJoint(x: centerX + rect.width * 0.20, y: rect.y + rect.height * 0.22),
            .leftElbow: fixtureJoint(x: centerX - rect.width * 0.23, y: rect.y + rect.height * 0.38),
            .rightElbow: fixtureJoint(x: centerX + rect.width * 0.23, y: rect.y + rect.height * 0.38),
            .leftWrist: fixtureJoint(x: centerX - rect.width * 0.25, y: rect.y + rect.height * 0.50),
            .rightWrist: fixtureJoint(x: centerX + rect.width * 0.25, y: rect.y + rect.height * 0.50),
            .leftHip: fixtureJoint(x: centerX - rect.width * 0.13, y: rect.y + rect.height * 0.52),
            .rightHip: fixtureJoint(x: centerX + rect.width * 0.13, y: rect.y + rect.height * 0.52),
            .leftKnee: fixtureJoint(x: centerX - rect.width * 0.13, y: rect.y + rect.height * 0.72),
            .rightKnee: fixtureJoint(x: centerX + rect.width * 0.13, y: rect.y + rect.height * 0.72),
            .leftAnkle: fixtureJoint(x: centerX - rect.width * 0.13, y: rect.maxY - 0.01),
            .rightAnkle: fixtureJoint(x: centerX + rect.width * 0.13, y: rect.maxY - 0.01),
        ]
        joints[.root] = fixtureJoint(x: centerX, y: rect.y + rect.height * 0.52)
        return PersonObservation(
            joints: joints,
            boundingBox: rect,
            confidence: 0.92,
            observedAt: Date()
        )
    }

    private func fixtureJoint(x: Double, y: Double) -> PoseJoint {
        PoseJoint(point: NormalizedPoint(x: x, y: y), confidence: 0.95)
    }

    private func fixtureCandidates(
        method: LocalCaptureMethod,
        roundIndex: Int,
        store: CaptureWorkStore
    ) async throws -> (method: LocalCaptureMethod, candidates: [CaptureCandidate], sourceFilename: String?) {
        let count = method == .shortVideo ? 6 : 3
        var inputs: [CandidateInput] = []
        for index in 0 ..< count {
            let frameID = "frame_fixture_r\(roundIndex)_\(index)"
            let data = Self.fixtureJPEG(index: index, roundIndex: roundIndex)
            let filename = try await store.saveCandidateJPEG(
                data,
                roundIndex: roundIndex,
                frameID: frameID
            )
            let quality = Double(index + 1) / Double(count)
            inputs.append(CandidateInput(
                frameID: frameID,
                timestampMilliseconds: method == .shortVideo ? index * 1_000 : index * 180,
                localFilename: filename,
                metrics: FrameQualityMetrics(
                    completeFraming: index == 0 ? 0.55 : 1,
                    targetPositionMatch: 0.58 + quality * 0.38,
                    personScaleMatch: 0.62 + quality * 0.32,
                    sharpness: 0.50 + quality * 0.46,
                    supportedPoseMatch: target.poseTemplate == "unknown" ? nil : 0.65 + quality * 0.30,
                    personCount: 1,
                    headAndFeetVisible: index != 0,
                    averageConfidence: 0.90
                )
            ))
        }
        return (method, FrameSelectionEngine.rank(inputs), nil)
    }

    private static func fixtureJPEG(index: Int, roundIndex: Int) -> Data {
        let size = CGSize(width: 720, height: 1_280)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor(red: 0.04, green: 0.09, blue: 0.14, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.orange.withAlphaComponent(0.45 + CGFloat(index) * 0.08).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 282, y: 220, width: 156, height: 156))
            context.cgContext.fill(CGRect(x: 250, y: 370, width: 220, height: 520))
            let label = "演示画面 · \(ProductCopy.round(roundIndex)) · 候选 \(index + 1)"
            label.draw(
                at: CGPoint(x: 40, y: 1_160),
                withAttributes: [
                    .font: UIFont.boldSystemFont(ofSize: 28),
                    .foregroundColor: UIColor.white,
                ]
            )
        }
        return image.jpegData(compressionQuality: 0.85) ?? Data([0xFF, 0xD8, 0xFF, 0xD9])
    }

    private static func argumentValue(after key: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: key), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}
