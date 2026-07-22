import Combine
import Foundation
import OSLog
import SoloShotContracts

enum AppFlowState: Equatable {
    case launch
    case taskImport
    case importing
    case referenceSummary(ImportedTask)
    case setup(ImportedTask)
    case cameraPreparing(ImportedTask)
    case aligning(ImportedTask)
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

private enum CountdownInvalidation: String {
    case alignmentLost = "alignment_lost"
    case cameraInterrupted = "camera_interrupted"
    case cameraFailure = "camera_failure"
    case criticalPressure = "critical_pressure"
}

@MainActor
final class AppFlowModel: ObservableObject {
    @Published private(set) var state: AppFlowState = .launch
    @Published var codeInput = ""
    @Published private(set) var preview: HandoffTask?
    @Published private(set) var alignmentSession: AlignmentSessionModel?
    @Published private(set) var availableTasks: [ImportedTask] = []
    @Published private(set) var serverAvailableHandoffs: [HandoffTask] = []
    @Published private(set) var isRefreshingHandoffs = false
    @Published private(set) var handoffDiscoveryMessage: String?

    private let api: HandoffAPI
    private let secrets: KeychainStore
    private let tasks: ImportedTaskStore
    private let cameraAuthorization: any CameraAuthorizationProviding
    private let captureStore: CaptureWorkStore
    private let captureOutbox: CaptureOutbox
    private let networkMonitor: any NetworkRecoveryMonitoring
    private let captureCues = CaptureCueFeedbackController()
    private let logger = Logger(subsystem: "ai.soloshot.app", category: "auto-capture")
    private var operation: Task<Void, Never>?
    private var referenceCacheTask: Task<Void, Never>?
    private var discoveryTask: Task<Void, Never>?
    private var pendingCaptureMethod: LocalCaptureMethod?
    private var countdownCancellationCount = 0

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
        let baseURL = URL(string: configured ?? "https://shotapi.socialdog.cn")!
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
        referenceCacheTask?.cancel()
        discoveryTask?.cancel()
        networkMonitor.cancel()
    }

    func start() async {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-W4SeedTask") {
            try? await captureStore.clear()
            let task = Self.fixtureImportedTask()
            try? await tasks.save(task)
            await refreshAvailableTasks()
            state = .referenceSummary(task)
            return
        }
#endif
        await refreshAvailableTasks()
        state = .taskImport
        refreshAvailableHandoffs()
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
                await refreshAvailableTasks()
                serverAvailableHandoffs.removeAll { $0.code == code }

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
                    await refreshAvailableTasks()
                    state = .referenceSummary(imported)
                } catch {
                    // The durable task remains usable offline. Launch recovery retries complete.
                }

                if let access = claim.referenceAccess,
                   let url = URL(string: access.downloadUrl)
                {
                    referenceCacheTask?.cancel()
                    referenceCacheTask = Task { [weak self] in
                        await self?.cacheReference(url: url, task: imported)
                    }
                }
            } catch is CancellationError {
                if !isAtHome { state = .taskImport }
            } catch {
                if let clientError = error as? HandoffClientError {
                    switch clientError {
                    case .alreadyClaimed, .expired, .revoked:
                        serverAvailableHandoffs.removeAll { $0.code == codeInput }
                        preview = nil
                        codeInput = ""
                        state = .taskImport
                        refreshAvailableHandoffs()
                        return
                    default:
                        break
                    }
                }
                if !isAtHome { show(error) }
            }
        }
    }

    func cancelImport() {
        operation?.cancel()
        operation = nil
        state = .taskImport
        refreshAvailableHandoffs()
    }

    func showHome() {
        operation?.cancel()
        operation = nil
        captureCues.stop()
        let session = alignmentSession
        alignmentSession = nil
        pendingCaptureMethod = nil
        preview = nil
        codeInput = ""
        state = .taskImport
        refreshAvailableHandoffs()
        Task { [weak self] in
            await session?.stop()
            await self?.refreshAvailableTasks()
        }
    }

    func claimAvailableHandoff(_ handoff: HandoffTask) {
        guard handoff.status == .created, handoff.expiresAt > Date() else {
            serverAvailableHandoffs.removeAll { $0.code == handoff.code }
            refreshAvailableHandoffs()
            return
        }
        codeInput = handoff.code
        preview = handoff
        confirmClaim()
    }

    func refreshAvailableHandoffs() {
        discoveryTask?.cancel()
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-W4FixtureHandoffDiscovery") {
            serverAvailableHandoffs = [Self.fixtureAvailableHandoff()]
            handoffDiscoveryMessage = nil
            isRefreshingHandoffs = false
            return
        }
#endif
        isRefreshingHandoffs = true
        handoffDiscoveryMessage = nil
        discoveryTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await api.listAvailable(limit: 20)
                try Task.checkCancellation()
                serverAvailableHandoffs = result.items.filter {
                    $0.status == .created && $0.expiresAt > Date()
                }
                handoffDiscoveryMessage = serverAvailableHandoffs.isEmpty
                    ? "暂时没有等待认领的现场任务。"
                    : nil
            } catch is CancellationError {
                return
            } catch {
                serverAvailableHandoffs = []
                handoffDiscoveryMessage = "现场任务列表暂不可用，仍可输入六位任务码。"
            }
            isRefreshingHandoffs = false
        }
    }

    func openSavedTask(_ task: ImportedTask) {
        operation?.cancel()
        operation = Task { [weak self] in
            guard let self else { return }
            guard task.expiresAt > Date() else {
                await expireCurrentTask(task)
                return
            }
            do {
                try await tasks.save(task)
                codeInput = task.code
                preview = nil
                if let work = try await captureStore.load(sessionID: task.sessionID),
                   let round = work.currentRound
                {
                    if round.networkStep == .finished {
                        routeCompletedWork(task: task, work: work)
                    } else if round.selectedFrameID == nil {
                        state = .selectingFrame(task, work)
                    } else {
                        state = .offlinePending(task, work, message: "旅拍进度已找回，联网后可以继续复盘。")
                    }
                } else {
                    state = .referenceSummary(task)
                }
                if !task.completionConfirmed {
                    retryCompletion(for: task)
                }
            } catch {
                show(error)
            }
        }
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
        pendingCaptureMethod = .planned(task.captureMode)
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
                guard !Task.isCancelled, !isAtHome else { return }
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
            let preparedTask = await waitForReferencePreparation(task, timeout: 3)
            guard !Task.isCancelled, !isAtHome else { return }
            guard let target = preparedTask.targetLayout else {
                state = .cameraError(task, .configurationFailed)
                return
            }
            let referenceSilhouette: ReferenceSilhouetteAsset?
            if let filename = preparedTask.referenceSilhouetteFilename {
                referenceSilhouette = try? await tasks.loadSilhouette(filename: filename)
            } else if fixture {
                if ProcessInfo.processInfo.arguments.contains("-W4FixtureReferenceFailure") {
                    referenceSilhouette = .unavailable(
                        .extractionFailed,
                        sourceSHA256: "fixture-failure"
                    )
                } else {
                    referenceSilhouette = ReferenceSilhouetteAsset(
                        schemaVersion: "1.0",
                        algorithmVersion: ReferenceSilhouetteAsset.algorithmVersion,
                        sourceSHA256: "fixture",
                        status: .ready,
                        contour: .fixturePerson,
                        extractedAt: Date()
                    )
                }
            } else {
                referenceSilhouette = nil
            }
            let session = AlignmentSessionModel(
                task: preparedTask,
                target: target,
                referenceSilhouette: referenceSilhouette,
                isFixture: fixture,
                voiceEnabled: voiceEnabled,
                hapticsEnabled: hapticsEnabled,
                onReady: { [weak self] completion in
                    self?.finishAlignment(task: preparedTask, completion: completion)
                },
                onExpired: { [weak self] in
                    guard let self else { return }
                    Task { await self.expireCurrentTask(preparedTask) }
                }
            )
            alignmentSession = session
            do {
                try await session.start()
                try Task.checkCancellation()
                state = .aligning(preparedTask)
            } catch is CancellationError {
                await session.stop()
                alignmentSession = nil
            } catch let failure as CameraFailure {
                await session.stop()
                alignmentSession = nil
                if !isAtHome { state = .cameraError(task, failure) }
            } catch {
                await session.stop()
                alignmentSession = nil
                if !isAtHome { state = .cameraError(task, .configurationFailed) }
            }
        }
    }

    func exitAlignment(toSummary task: ImportedTask) {
        operation?.cancel()
        captureCues.stop()
        let session = alignmentSession
        alignmentSession = nil
        pendingCaptureMethod = nil
        state = .referenceSummary(task)
        Task { await session?.stop() }
    }

    func beginCountdown(
        task: ImportedTask,
        completion: AlignmentCompletion,
        method: LocalCaptureMethod
    ) {
        operation?.cancel()
        alignmentSession?.stopAlignmentFeedback()
        logger.info("auto_capture_triggered method=\(method.rawValue, privacy: .public) overlap=\(completion.overlapRatio, privacy: .public) stable_ms=\(completion.stableDuration * 1_000, privacy: .public)")
        operation = Task { [weak self] in
            guard let self else { return }
            let countdownStartedAt = ProcessInfo.processInfo.systemUptime
            var displayedSeconds = 3
            state = .countdown(task, completion, method, seconds: displayedSeconds)
            captureCues.emit(.autoReady)
            captureCues.emit(.countdown(displayedSeconds))

            while ProcessInfo.processInfo.systemUptime - countdownStartedAt < 3 {
                if let reason = countdownInvalidation(for: completion) {
                    cancelCountdown(task: task, reason: reason)
                    return
                }
                let elapsed = ProcessInfo.processInfo.systemUptime - countdownStartedAt
                let remaining = max(1, 3 - Int(elapsed))
                if remaining != displayedSeconds {
                    displayedSeconds = remaining
                    state = .countdown(task, completion, method, seconds: remaining)
                    captureCues.emit(.countdown(remaining))
                }
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    return
                }
            }
            if let reason = countdownInvalidation(for: completion) {
                cancelCountdown(task: task, reason: reason)
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
                if !isAtHome {
                    state = .captureError(task, message: error.localizedDescription, canUsePhotoFallback: false)
                }
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
                do {
                    try await Task.sleep(for: .milliseconds(450))
                } catch {
                    return
                }
                guard !isAtHome else { return }
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
                if !isAtHome { state = .uploadPending(task, work) }
            } catch {
                if !isAtHome {
                    state = .offlinePending(task, work, message: error.localizedDescription)
                }
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
        operation?.cancel()
        captureCues.stop()
        pendingCaptureMethod = .photoFallback
        session.resumeAlignment()
        logger.info("auto_capture_fallback_requested method=photo_fallback")
        state = .aligning(task)
    }

    func returnToSetup(_ task: ImportedTask) {
        operation?.cancel()
        captureCues.stop()
        let session = alignmentSession
        alignmentSession = nil
        pendingCaptureMethod = nil
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
        beginCountdown(
            task: task,
            completion: completion,
            method: pendingCaptureMethod ?? .planned(task.captureMode)
        )
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
        try? await tasks.clear(code: task.code)
        try? await secrets.removeClaimToken(code: task.code)
        await refreshAvailableTasks()
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
    private static func fixtureAvailableHandoff(now: Date = Date()) -> HandoffTask {
        HandoffTask(
            schemaVersion: ._10,
            handoffId: "handoff_onsite_fixture",
            code: "731204",
            status: .created,
            mode: .originalReplication,
            createdAt: now,
            expiresAt: now.addingTimeInterval(600),
            claimedAt: nil,
            completedAt: nil
        )
    }

    private static func fixtureImportedTask(now: Date = Date()) -> ImportedTask {
        ImportedTask(
            schemaVersion: "2.0",
            code: "294816",
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
                await refreshAvailableTasks()
                publishPreparedTaskIfVisible(updated)
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
            updated.referenceSilhouetteStatus = .pending
            try await tasks.save(updated)
            await refreshAvailableTasks()
            publishPreparedTaskIfVisible(updated)

            guard let selectedBox = updated.referenceSelectedBox else {
                updated.referenceSilhouetteStatus = .extractionFailed
                try await tasks.save(updated)
                await refreshAvailableTasks()
                publishPreparedTaskIfVisible(updated)
                return
            }
            let asset = await Task.detached(priority: .userInitiated) {
                ReferenceSilhouetteExtractor().extract(data: data, selectedBox: selectedBox)
            }.value
            try Task.checkCancellation()
            let silhouetteFilename = try await tasks.saveSilhouette(asset, code: task.code)
            updated.referenceSilhouetteFilename = silhouetteFilename
            updated.referenceSilhouetteStatus = asset.status
            try await tasks.save(updated)
            await refreshAvailableTasks()
            publishPreparedTaskIfVisible(updated)
        } catch {
            // Explicit placeholder in the summary; the ShotPlan remains available.
        }
    }

    private func waitForReferencePreparation(
        _ task: ImportedTask,
        timeout: TimeInterval
    ) async -> ImportedTask {
        guard task.referenceSelectedBox != nil else { return task }
        let deadline = Date().addingTimeInterval(timeout)
        var latest = (try? await tasks.load()) ?? task
        while (latest.referenceSilhouetteStatus == nil || latest.referenceSilhouetteStatus == .pending),
              referenceCacheTask != nil,
              Date() < deadline
        {
            try? await Task.sleep(for: .milliseconds(100))
            if Task.isCancelled { return latest }
            latest = (try? await tasks.load()) ?? latest
        }
        if latest.referenceSilhouetteStatus == nil || latest.referenceSilhouetteStatus == .pending {
            latest.referenceSilhouetteStatus = .extractionFailed
        }
        return latest
    }

    private func publishPreparedTaskIfVisible(_ task: ImportedTask) {
        switch state {
        case let .referenceSummary(current) where current.sessionID == task.sessionID:
            state = .referenceSummary(task)
        case let .setup(current) where current.sessionID == task.sessionID:
            state = .setup(task)
        default:
            break
        }
    }

    private func show(_ error: Error) {
        let mapped = error as? HandoffClientError ?? .network
        state = .recoverableError(
            message: mapped.localizedDescription,
            code: mapped.code
        )
    }

    private func countdownInvalidation(for completion: AlignmentCompletion) -> CountdownInvalidation? {
        guard let session = alignmentSession else { return .cameraFailure }
        if session.failure != nil { return .cameraFailure }
        if session.isInterrupted { return .cameraInterrupted }
        if session.pressure == .critical { return .criticalPressure }
        if completion.mode != .manual, session.decision?.countdownStillValid != true {
            return .alignmentLost
        }
        return nil
    }

    private func cancelCountdown(task: ImportedTask, reason: CountdownInvalidation) {
        countdownCancellationCount += 1
        let overlap = alignmentSession?.decision?.overlapRatio ?? 0
        logger.info("auto_capture_cancelled reason=\(reason.rawValue, privacy: .public) overlap=\(overlap, privacy: .public) cancellation_count=\(self.countdownCancellationCount, privacy: .public)")
        captureCues.stop()
        if reason == .alignmentLost {
            captureCues.emit(.alignmentLost)
        }
        alignmentSession?.resumeAlignment()
        state = .aligning(task)
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
            if !isAtHome { state = .setup(task) }
        } catch {
            if !isAtHome {
                state = .captureError(
                    task,
                    message: error.localizedDescription,
                    canUsePhotoFallback: method == .shortVideo
                )
            }
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

    private var isAtHome: Bool {
        if case .taskImport = state { return true }
        return false
    }

    private func refreshAvailableTasks() async {
        availableTasks = (try? await tasks.loadAll()) ?? []
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
