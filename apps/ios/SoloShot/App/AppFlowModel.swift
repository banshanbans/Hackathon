import Combine
import Foundation
import SoloShotContracts

enum AppFlowState: Equatable {
    case launch
    case taskImport
    case importing
    case referenceSummary(ImportedTask)
    case setup(ImportedTask)
    case cameraPreparing(ImportedTask)
    case aligning(ImportedTask)
    case ready(ImportedTask, AlignmentCompletion)
    case actionBrief(ImportedTask, AlignmentCompletion, LocalCaptureMethod)
    case countdown(ImportedTask, AlignmentCompletion, LocalCaptureMethod, seconds: Int)
    case recording(ImportedTask, LocalCaptureMethod, roundIndex: Int)
    case processingFrames(ImportedTask, roundIndex: Int)
    case selectingFrame(ImportedTask, CaptureWork)
    case consent(ImportedTask, CaptureWork)
    case uploadPending(ImportedTask, CaptureWork)
    case uploading(ImportedTask, CaptureWork)
    case comparing(ImportedTask, CaptureWork)
    case coaching(ImportedTask, CaptureWork)
    case finalResult(ImportedTask, CaptureWork)
    case offlinePending(ImportedTask, CaptureWork, message: String)
    case captureError(ImportedTask, message: String, canUsePhotoFallback: Bool)
    case cameraError(ImportedTask, CameraFailure)
    case recoverableError(message: String, code: String)
}

@MainActor
final class AppFlowModel: ObservableObject {
    @Published private(set) var state: AppFlowState = .launch
    @Published var codeInput = ""
    @Published private(set) var preview: HandoffTask?
    @Published private(set) var alignmentSession: AlignmentSessionModel?

    private let api: HandoffAPI
    private let secrets: KeychainStore
    private let tasks: ImportedTaskStore
    private let cameraAuthorization: any CameraAuthorizationProviding
    private let captureStore: CaptureWorkStore
    private let captureOutbox: CaptureOutbox
    private let networkMonitor: any NetworkRecoveryMonitoring
    private let captureCues = CaptureCueFeedbackController()
    private var operation: Task<Void, Never>?

    init(
        api: HandoffAPI? = nil,
        secrets: KeychainStore = KeychainStore(),
        tasks: ImportedTaskStore = ImportedTaskStore(),
        cameraAuthorization: any CameraAuthorizationProviding = SystemCameraAuthorizationProvider(),
        captureStore: CaptureWorkStore = CaptureWorkStore(),
        captureClient: (any CaptureSubmissionClient)? = nil,
        networkMonitor: any NetworkRecoveryMonitoring = SystemNetworkRecoveryMonitor()
    ) {
        let configured = Bundle.main.object(forInfoDictionaryKey: "SoloShotAPIBaseURL") as? String
        let baseURL = URL(string: configured ?? "http://127.0.0.1:8000")!
        self.api = api ?? HandoffAPI(baseURL: baseURL)
        self.secrets = secrets
        self.tasks = tasks
        self.cameraAuthorization = cameraAuthorization
        self.captureStore = captureStore
        self.networkMonitor = networkMonitor
        let resolvedClient = captureClient ?? CaptureAPI(baseURL: baseURL)
        captureOutbox = CaptureOutbox(client: resolvedClient, store: captureStore)
        networkMonitor.start { [weak self] in
            Task { @MainActor [weak self] in
                self?.resumePendingNetworkWork()
            }
        }
    }

    deinit {
        operation?.cancel()
        networkMonitor.cancel()
    }

    func start() async {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-W4SeedTask") {
            try? await captureStore.clear()
            let task = Self.fixtureImportedTask()
            try? await tasks.save(task)
            state = .referenceSummary(task)
            return
        }
#endif
        if let cached = try? await tasks.loadUnchecked(), cached.expiresAt <= Date() {
            try? await tasks.clear()
            try? await secrets.removeClaimToken(code: cached.code)
            state = .taskImport
        } else if let cached = try? await tasks.load() {
            if let work = try? await captureStore.load(sessionID: cached.sessionID),
               let round = work.currentRound
            {
                if round.networkStep == .finished {
                    routeCompletedWork(task: cached, work: work)
                } else if round.selectedFrameID == nil {
                    state = .selectingFrame(cached, work)
                } else {
                    state = .offlinePending(cached, work, message: "旅拍进度已找回，联网后可以继续复盘。")
                    submit(task: cached, work: work)
                }
            } else {
                state = .referenceSummary(cached)
            }
            if !cached.completionConfirmed {
                retryCompletion(for: cached)
            }
        } else {
            state = .taskImport
        }
    }

    func receive(_ url: URL) {
        do {
            codeInput = try DeepLinkParser.parse(url)
            loadPreview()
        } catch {
            state = .recoverableError(
                message: HandoffClientError.invalidCode.localizedDescription,
                code: HandoffClientError.invalidCode.code
            )
        }
    }

    func loadPreview() {
        operation?.cancel()
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let code = try DeepLinkParser.normalizeCode(codeInput)
                let safePreview = try await api.preview(code: code)
                try Task.checkCancellation()
                preview = safePreview
                codeInput = code
                state = .taskImport
            } catch is CancellationError {
                return
            } catch {
                show(error)
            }
        }
    }

    func confirmClaim() {
        guard preview?.status == .created else {
            show(HandoffClientError.invalidCode)
            return
        }
        operation?.cancel()
        state = .importing
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let code = try DeepLinkParser.normalizeCode(codeInput)
                let clientID = try await secrets.clientInstanceID()
                let claim = try await api.claim(code: code, clientInstanceID: clientID)
                var imported = try ImportedTask.from(claim)
                try await secrets.saveClaimToken(claim.claimToken, code: code)
                try await tasks.save(imported)

                // The summary becomes visible immediately after the app-owned JSON is durable.
                state = .referenceSummary(imported)
                do {
                    _ = try await api.complete(
                        code: code,
                        clientInstanceID: clientID,
                        claimToken: claim.claimToken
                    )
                    imported.completionConfirmed = true
                    try await tasks.save(imported)
                    state = .referenceSummary(imported)
                } catch {
                    // The durable task remains usable offline. Launch recovery retries complete.
                }

                if let access = claim.referenceAccess,
                   let url = URL(string: access.downloadUrl)
                {
                    await cacheReference(url: url, task: imported)
                }
            } catch is CancellationError {
                state = .taskImport
            } catch {
                show(error)
            }
        }
    }

    func cancelImport() {
        operation?.cancel()
        operation = nil
        state = .taskImport
    }

    func openSetup(_ task: ImportedTask) {
        guard task.expiresAt > Date() else {
            Task { await expireCurrentTask(task) }
            return
        }
        guard task.canStartAlignment else { return }
        state = .setup(task)
    }

    func beginAlignment(
        for task: ImportedTask,
        voiceEnabled: Bool,
        hapticsEnabled: Bool
    ) {
        operation?.cancel()
        state = .cameraPreparing(task)
        operation = Task { [weak self] in
            guard let self else { return }
            if task.expiresAt <= Date() {
                await expireCurrentTask(task)
                return
            }
            let fixture = fixtureCameraRequested
            if !fixture {
                let permission = cameraAuthorization.currentState()
                let allowed: Bool
                switch permission {
                case .authorized:
                    allowed = true
                case .notDetermined:
                    allowed = await cameraAuthorization.requestAccess()
                case .denied:
                    state = .cameraError(task, .permissionDenied)
                    return
                case .restricted:
                    state = .cameraError(task, .permissionRestricted)
                    return
                }
                guard allowed else {
                    state = .cameraError(task, .permissionDenied)
                    return
                }
            }
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-W4FixturePermissionDenied") {
                state = .cameraError(task, .permissionDenied)
                return
            }
#endif
            guard let target = task.targetLayout else {
                state = .cameraError(task, .configurationFailed)
                return
            }
            let session = AlignmentSessionModel(
                task: task,
                target: target,
                isFixture: fixture,
                voiceEnabled: voiceEnabled,
                hapticsEnabled: hapticsEnabled,
                onReady: { [weak self] completion in
                    self?.finishAlignment(task: task, completion: completion)
                },
                onExpired: { [weak self] in
                    guard let self else { return }
                    Task { await self.expireCurrentTask(task) }
                }
            )
            alignmentSession = session
            do {
                try await session.start()
                try Task.checkCancellation()
                state = .aligning(task)
            } catch is CancellationError {
                await session.stop()
                alignmentSession = nil
            } catch let failure as CameraFailure {
                await session.stop()
                alignmentSession = nil
                state = .cameraError(task, failure)
            } catch {
                await session.stop()
                alignmentSession = nil
                state = .cameraError(task, .configurationFailed)
            }
        }
    }

    func exitAlignment(toSummary task: ImportedTask) {
        operation?.cancel()
        captureCues.stop()
        let session = alignmentSession
        alignmentSession = nil
        state = .referenceSummary(task)
        Task { await session?.stop() }
    }

    func openActionBrief(_ task: ImportedTask, completion: AlignmentCompletion) {
        let planned = LocalCaptureMethod.planned(task.captureMode)
        state = .actionBrief(task, completion, planned)
    }

    func beginCountdown(
        task: ImportedTask,
        completion: AlignmentCompletion,
        method: LocalCaptureMethod
    ) {
        operation?.cancel()
        operation = Task { [weak self] in
            guard let self else { return }
            captureCues.emit(.prepareAction)
            for seconds in stride(from: 3, through: 1, by: -1) {
                guard alignmentStillValid(completion) else {
                    alignmentSession?.resumeAlignment()
                    state = .aligning(task)
                    return
                }
                state = .countdown(task, completion, method, seconds: seconds)
                captureCues.emit(.countdown(seconds))
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
            }
            guard alignmentStillValid(completion) else {
                alignmentSession?.resumeAlignment()
                state = .aligning(task)
                return
            }
            await performCapture(task: task, completion: completion, method: method)
        }
    }

    func selectCandidate(task: ImportedTask, work initialWork: CaptureWork, frameID: String) {
        operation?.cancel()
        captureCues.stop()
        operation = Task { [weak self] in
            guard let self, var round = initialWork.currentRound else { return }
            var work = initialWork
            guard round.candidates.contains(where: { $0.id == frameID }) else { return }
            round.selectedFrameID = frameID
            round.selectionSource = round.candidates.first?.id == frameID
                ? .localRecommended
                : .userSelected
            replace(round, in: &work)
            do {
                try await captureStore.removeUnselected(round: round)
                try await captureStore.save(work)
                state = work.captureConsentRecorded ? .uploadPending(task, work) : .consent(task, work)
            } catch {
                state = .captureError(task, message: error.localizedDescription, canUsePhotoFallback: false)
            }
        }
    }

    func confirmCaptureConsent(task: ImportedTask, work: CaptureWork, externalAIConsent: Bool) {
        guard task.usesFixtureEvaluation || externalAIConsent else { return }
        submit(task: task, work: work)
    }

    func submit(task: ImportedTask, work: CaptureWork) {
        operation?.cancel()
        state = .uploading(task, work)
        operation = Task { [weak self] in
            guard let self else { return }
#if DEBUG
            if fixtureW5Requested {
                state = .comparing(task, work)
                try? await Task.sleep(for: .milliseconds(450))
                let completed = fixtureEvaluation(work: work)
                try? await captureStore.save(completed)
                routeCompletedWork(task: task, work: completed)
                return
            }
#endif
            do {
                guard let token = try await secrets.claimToken(code: task.code) else {
                    throw CaptureClientError.invalidToken
                }
                state = .comparing(task, work)
                let completed = try await captureOutbox.resume(
                    task: task,
                    work: work,
                    claimToken: token
                )
                routeCompletedWork(task: task, work: completed)
            } catch is CancellationError {
                state = .uploadPending(task, work)
            } catch {
                state = .offlinePending(task, work, message: error.localizedDescription)
            }
        }
    }

    func retryPending(task: ImportedTask, work: CaptureWork) {
        submit(task: task, work: work)
    }

    func startRetake(task: ImportedTask) {
        returnToSetup(task)
    }

    func usePhotoFallback(task: ImportedTask) {
        guard let session = alignmentSession else {
            state = .setup(task)
            return
        }
        let completion = AlignmentCompletion(mode: .compositionOnly, completedAt: Date(), isFixture: session.isFixture)
        state = .actionBrief(task, completion, .photoFallback)
    }

    func returnToSetup(_ task: ImportedTask) {
        operation?.cancel()
        captureCues.stop()
        let session = alignmentSession
        alignmentSession = nil
        state = .setup(task)
        Task { await session?.stop() }
    }

    func handleSceneBecameInactive() {
        switch state {
        case let .aligning(task), let .countdown(task, _, _, _), let .recording(task, _, _):
            returnToSetup(task)
        default:
            return
        }
    }

    func handleSceneBecameActive() {
        resumePendingNetworkWork()
    }

    func retry() {
        preview = nil
        state = .taskImport
        if !codeInput.isEmpty {
            loadPreview()
        }
    }

    private func finishAlignment(task: ImportedTask, completion: AlignmentCompletion) {
        guard case .aligning = state else { return }
        state = .ready(task, completion)
    }

    private func resumePendingNetworkWork() {
        switch state {
        case let .offlinePending(task, work, _), let .uploadPending(task, work):
            submit(task: task, work: work)
        default:
            return
        }
    }

    private func expireCurrentTask(_ task: ImportedTask) async {
        operation?.cancel()
        let session = alignmentSession
        alignmentSession = nil
        await session?.stop()
        try? await captureStore.clear()
        try? await tasks.clear()
        try? await secrets.removeClaimToken(code: task.code)
        state = .taskImport
    }

    private var fixtureCameraRequested: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("-W4FixtureCamera")
#else
        false
#endif
    }

    private var fixtureW5Requested: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("-W5FixtureNetwork")
#else
        false
#endif
    }

#if DEBUG
    private static func fixtureImportedTask(now: Date = Date()) -> ImportedTask {
        ImportedTask(
            schemaVersion: "2.0",
            code: "ABC234",
            sessionID: "ss_w4_fixture",
            planID: "sp_w4_fixture",
            mode: "original_replication",
            cameraHeight: "waist",
            cameraAngle: "level",
            lens: "1x",
            captureMode: ProcessInfo.processInfo.arguments.contains("-W5FixtureShortVideo")
                ? "short_video"
                : "photo",
            setupInstruction: "手机竖直固定在腰部高度，保持后置 1× 镜头水平。",
            actions: [ImportedAction(sequence: 1, instruction: "站在轮廓中并保持自然姿势。", durationSeconds: 3)],
            safetyNotes: ["先固定手机并检查脚下环境。"],
            referenceID: "ref_doorway_coffee_fullbody",
            presetThumbnailName: "doorway_coffee_fullbody-thumb",
            targetLayout: ImportedTargetLayout(
                centerX: 0.5,
                centerY: 0.56,
                width: 0.32,
                height: 0.62,
                headPoint: NormalizedPoint(x: 0.5, y: 0.25),
                footLineY: 0.87,
                bodyDirection: "front",
                poseTemplate: "doorway_crossed_legs"
            ),
            iosAlignmentSupported: true,
            localReferenceFilename: nil,
            importedAt: now,
            expiresAt: now.addingTimeInterval(86_400),
            completionConfirmed: true
        )
    }
#endif

    private func retryCompletion(for task: ImportedTask) {
        operation = Task { [weak self] in
            guard let self,
                  let token = try? await secrets.claimToken(code: task.code)
            else { return }
            do {
                let clientID = try await secrets.clientInstanceID()
                _ = try await api.complete(
                    code: task.code,
                    clientInstanceID: clientID,
                    claimToken: token
                )
                var updated = task
                updated.completionConfirmed = true
                try await tasks.save(updated)
                state = .referenceSummary(updated)
            } catch {
                // Offline cached summary remains the source of truth.
            }
        }
    }

    private func cacheReference(url: URL, task: ImportedTask) async {
        do {
            let data = try await api.downloadReference(from: url)
            let filename = try await tasks.saveReference(data, code: task.code)
            var updated = task
            updated.localReferenceFilename = filename
            try await tasks.save(updated)
            state = .referenceSummary(updated)
        } catch {
            // Explicit placeholder in the summary; the ShotPlan remains available.
        }
    }

    private func show(_ error: Error) {
        let mapped = error as? HandoffClientError ?? .network
        state = .recoverableError(
            message: mapped.localizedDescription,
            code: mapped.code
        )
    }

    private func alignmentStillValid(_ completion: AlignmentCompletion) -> Bool {
        if completion.mode == .manual || completion.isFixture { return true }
        return alignmentSession?.decision?.alignment.readyToCapture == true
    }

    private func performCapture(
        task: ImportedTask,
        completion: AlignmentCompletion,
        method: LocalCaptureMethod
    ) async {
        guard let session = alignmentSession else {
            state = .captureError(task, message: "相机已经停下，请重新回到画面中。", canUsePhotoFallback: false)
            return
        }
        let existing = (try? await captureStore.load(sessionID: task.sessionID)) ?? CaptureWork.empty(task: task)
        let roundIndex = existing.rounds.count + 1
        guard roundIndex <= 2 else {
            state = .finalResult(task, existing)
            return
        }
        state = .recording(task, method, roundIndex: roundIndex)
        captureCues.emit(.start)
        if method == .shortVideo {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self?.captureCues.emit(.hold)
            }
        }
        do {
            let result = try await session.captureCandidates(
                method: method,
                roundIndex: roundIndex,
                store: captureStore
            )
            state = .processingFrames(task, roundIndex: roundIndex)
            guard !result.candidates.isEmpty else { throw CaptureEngineError.processingFailed }
            captureCues.emit(.completed)
            var work = existing
            work.rounds.append(CaptureRoundWork(
                roundIndex: roundIndex,
                captureMethod: result.method,
                alignmentMode: completion.mode,
                candidates: result.candidates,
                selectedFrameID: nil,
                selectionSource: nil,
                sourceFilename: result.sourceFilename,
                networkStep: work.captureConsentRecorded ? .upload : .consent,
                mediaAssetID: nil,
                captureID: nil,
                evaluation: nil,
                uploadAttemptID: "ios-upload-r\(roundIndex)-\(UUID().uuidString)",
                captureIdempotencyKey: "ios-capture-r\(roundIndex)-\(UUID().uuidString)",
                evaluationIdempotencyKey: "ios-evaluation-r\(roundIndex)-\(UUID().uuidString)"
            ))
            try await captureStore.save(work)
            state = .selectingFrame(task, work)
        } catch is CancellationError {
            state = .setup(task)
        } catch {
            state = .captureError(
                task,
                message: error.localizedDescription,
                canUsePhotoFallback: method == .shortVideo
            )
        }
    }

    private func routeCompletedWork(task: ImportedTask, work: CaptureWork) {
        guard let evaluation = work.currentRound?.evaluation else {
            state = .offlinePending(task, work, message: "这一拍还没有复盘完成，可以稍后继续。")
            return
        }
        if work.rounds.count >= 2 || evaluation.goalSatisfied {
            let session = alignmentSession
            alignmentSession = nil
            state = .finalResult(task, work)
            Task { await session?.stop() }
        } else {
            let session = alignmentSession
            alignmentSession = nil
            state = .coaching(task, work)
            Task { await session?.stop() }
        }
    }

    private func replace(_ round: CaptureRoundWork, in work: inout CaptureWork) {
        guard let index = work.rounds.firstIndex(where: { $0.roundIndex == round.roundIndex }) else { return }
        work.rounds[index] = round
    }

#if DEBUG
    private func fixtureEvaluation(work initialWork: CaptureWork) -> CaptureWork {
        var work = initialWork
        guard var round = work.currentRound else { return work }
        let satisfied = round.roundIndex == 2
            || ProcessInfo.processInfo.arguments.contains("-W5FixtureRoundOneSatisfied")
        round.mediaAssetID = "media_fixture_ios_r\(round.roundIndex)"
        round.captureID = "cap_fixture_ios_r\(round.roundIndex)"
        round.evaluation = CaptureEvaluation(
            evaluationID: "eval_fixture_ios_r\(round.roundIndex)",
            captureID: round.captureID ?? "cap_fixture_ios",
            issueCode: satisfied ? nil : "person_too_left",
            topIssue: satisfied ? nil : "人物位置略偏左",
            nextInstruction: satisfied ? nil : "向右移动半步",
            needsRetake: !satisfied,
            goalSatisfied: satisfied,
            publishReadiness: satisfied ? 0.88 : 0.62,
            confidence: 0.95,
            executionMode: "fixture"
        )
        round.networkStep = .finished
        replace(round, in: &work)
        work.captureConsentRecorded = true
        return work
    }
#endif
}
