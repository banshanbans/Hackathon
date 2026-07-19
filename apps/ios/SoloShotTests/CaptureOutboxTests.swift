import Foundation
import SoloShotContracts
import XCTest
@testable import SoloShot

private actor MockCaptureClient: CaptureSubmissionClient {
    private(set) var calls: [String] = []
    private var expiredUploadCount: Int

    init(expiredUploadCount: Int = 0) {
        self.expiredUploadCount = expiredUploadCount
    }

    func recordConsent(
        sessionID: String,
        externalAIConsent: Bool,
        claimToken: String,
        idempotencyKey: String
    ) async throws -> CaptureConsentReceipt {
        calls.append("consent:\(externalAIConsent)")
        return CaptureConsentReceipt(
            schemaVersion: ._10,
            sessionId: sessionID,
            captureUploadConsentAt: Date(),
            externalAiConsentAt: externalAIConsent ? Date() : nil
        )
    }

    func createUpload(
        sessionID: String,
        byteSize: Int,
        sha256: String,
        claimToken: String,
        idempotencyKey: String
    ) async throws -> MediaUploadTicket {
        calls.append("ticket")
        return MediaUploadTicket(
            schemaVersion: ._10,
            asset: media(sessionID: sessionID, status: .pendingUpload),
            uploadUrl: "https://upload.example.test/frame",
            uploadHeaders: ["Content-Type": "image/jpeg"],
            uploadExpiresAt: Date().addingTimeInterval(600)
        )
    }

    func putJPEG(_ data: Data, ticket: MediaUploadTicket) async throws {
        calls.append("put")
        if expiredUploadCount > 0 {
            expiredUploadCount -= 1
            throw CaptureClientError.uploadURLExpired
        }
    }

    func completeUpload(
        sessionID: String,
        mediaAssetID: String,
        claimToken: String,
        idempotencyKey: String
    ) async throws -> MediaAsset {
        calls.append("complete")
        return media(sessionID: sessionID, status: .ready)
    }

    func createCapture(
        sessionID: String,
        round: CaptureRoundWork,
        mediaAssetID: String,
        claimToken: String
    ) async throws -> Capture {
        calls.append("capture")
        return Capture(
            schemaVersion: ._10,
            captureId: "cap_ios_test",
            sessionId: sessionID,
            roundIndex: round.roundIndex,
            mediaAssetId: mediaAssetID,
            status: .ready,
            sourceClient: .ios,
            captureMethod: .photo,
            selectedFrameId: round.selectedFrameID,
            selectedFrameTimestampMs: 0,
            selectionSource: .localRecommended,
            createdAt: Date()
        )
    }

    func evaluate(
        sessionID: String,
        captureID: String,
        claimToken: String,
        idempotencyKey: String
    ) async throws -> ResultEvaluation {
        calls.append("evaluate")
        return ResultEvaluation(
            schemaVersion: "1.0",
            evaluationId: "eval_ios_test",
            captureId: captureID,
            needsRetake: false,
            goalSatisfied: true,
            publishReadiness: 0.9,
            confidence: 0.8,
            executionMode: .live
        )
    }

    func snapshot() -> [String] { calls }

    private func media(sessionID: String, status: MediaAsset.Status) -> MediaAsset {
        MediaAsset(
            schemaVersion: ._10,
            mediaAssetId: "media_ios_test",
            sessionId: sessionID,
            purpose: .capture,
            contentType: .imageSlashJpeg,
            byteSize: 6,
            sha256: String(repeating: "a", count: 64),
            status: status,
            width: 1,
            height: 1,
            expiresAt: Date().addingTimeInterval(86_400),
            createdAt: Date()
        )
    }
}

final class CaptureOutboxTests: XCTestCase {
    func testRunsSensitiveNetworkStepsInOrderAndPersistsFinishedState() async throws {
        let client = MockCaptureClient()
        let (task, work, store) = try await fixtureWork()
        let result = try await CaptureOutbox(client: client, store: store).resume(
            task: task,
            work: work,
            claimToken: "claim-token-not-logged"
        )
        let calls = await client.snapshot()
        XCTAssertEqual(calls, [
            "consent:true", "ticket", "put", "complete", "capture", "evaluate",
        ])
        XCTAssertEqual(result.currentRound?.networkStep, .finished)
        XCTAssertEqual(result.currentRound?.evaluation?.executionMode, "live")
        let restored = try await store.load(sessionID: task.sessionID)
        XCTAssertEqual(restored, result)
    }

    func testExpiredSignedURLCreatesFreshUploadAttemptWithoutDuplicatingCapture() async throws {
        let client = MockCaptureClient(expiredUploadCount: 1)
        let (task, work, store) = try await fixtureWork()
        _ = try await CaptureOutbox(client: client, store: store).resume(
            task: task,
            work: work,
            claimToken: "claim-token"
        )
        let calls = await client.snapshot()
        XCTAssertEqual(calls.filter { $0 == "ticket" }.count, 2)
        XCTAssertEqual(calls.filter { $0 == "capture" }.count, 1)
        XCTAssertEqual(calls.filter { $0 == "evaluate" }.count, 1)
    }

    private func fixtureWork() async throws -> (ImportedTask, CaptureWork, CaptureWorkStore) {
        let task = makeW4ImportedTask(now: Date())
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "soloshot-outbox-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = CaptureWorkStore(directory: directory)
        let filename = try await store.saveCandidateJPEG(
            Data([0xFF, 0xD8, 0x01, 0x02, 0xFF, 0xD9]),
            roundIndex: 1,
            frameID: "frame_outbox"
        )
        var work = CaptureWork.empty(task: task)
        work.rounds.append(CaptureRoundWork(
            roundIndex: 1,
            captureMethod: .photo,
            alignmentMode: .verified,
            candidates: [CaptureCandidate(
                id: "frame_outbox",
                timestampMilliseconds: 0,
                localFilename: filename,
                metrics: FrameQualityMetrics(
                    completeFraming: 1,
                    targetPositionMatch: 1,
                    personScaleMatch: 1,
                    sharpness: 1,
                    supportedPoseMatch: 1
                ),
                localScore: 1,
                reasons: ["本地推荐"]
            )],
            selectedFrameID: "frame_outbox",
            selectionSource: .localRecommended,
            sourceFilename: nil,
            networkStep: .consent,
            mediaAssetID: nil,
            captureID: nil,
            evaluation: nil,
            uploadAttemptID: "upload-key",
            captureIdempotencyKey: "capture-key",
            evaluationIdempotencyKey: "evaluation-key"
        ))
        try await store.save(work)
        return (task, work, store)
    }
}
