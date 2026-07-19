import Foundation
import XCTest
@testable import SoloShot

final class CaptureWorkStoreTests: XCTestCase {
    func testAtomicallyPersistsRoundsAndSelectedJPEG() async throws {
        let directory = temporaryDirectory()
        let store = CaptureWorkStore(directory: directory)
        let task = makeW4ImportedTask(now: Date())
        let filename = try await store.saveCandidateJPEG(
            jpegFixture,
            roundIndex: 1,
            frameID: "frame_store"
        )
        var work = CaptureWork.empty(task: task)
        work.rounds.append(round(filename: filename))
        try await store.save(work)

        let restored = try await store.load(sessionID: task.sessionID)
        XCTAssertEqual(restored, work)
        let selected = try await store.selectedFrameData(work.rounds[0])
        XCTAssertEqual(selected, jpegFixture)
    }

    func testUnselectedAndSourceFilesAreRemovedWithoutDeletingSelectedFrame() async throws {
        let store = CaptureWorkStore(directory: temporaryDirectory())
        let selected = try await store.saveCandidateJPEG(jpegFixture, roundIndex: 1, frameID: "frame_selected")
        let other = try await store.saveCandidateJPEG(jpegFixture, roundIndex: 1, frameID: "frame_other")
        var value = round(filename: selected)
        value.candidates.append(CaptureCandidate(
            id: "frame_other",
            timestampMilliseconds: 400,
            localFilename: other,
            metrics: metrics,
            localScore: 0.4,
            reasons: ["候选"]
        ))
        try await store.removeUnselected(round: value)
        let selectedData = try await store.selectedFrameData(value)
        XCTAssertEqual(selectedData, jpegFixture)
        let otherURL = await store.candidateURL(filename: other)
        XCTAssertFalse(FileManager.default.fileExists(atPath: otherURL.path))
    }

    func testExpiredWorkIsCleaned() async throws {
        let store = CaptureWorkStore(directory: temporaryDirectory())
        let task = makeW4ImportedTask(now: Date())
        var work = CaptureWork.empty(task: task)
        work.rounds = []
        try await store.save(work)
        let expired = try await store.load(
            sessionID: task.sessionID,
            now: task.expiresAt.addingTimeInterval(1)
        )
        XCTAssertNil(expired)
    }

    private var jpegFixture: Data { Data([0xFF, 0xD8, 0x01, 0x02, 0xFF, 0xD9]) }
    private var metrics: FrameQualityMetrics {
        FrameQualityMetrics(
            completeFraming: 1,
            targetPositionMatch: 1,
            personScaleMatch: 1,
            sharpness: 1,
            supportedPoseMatch: 1
        )
    }

    private func round(filename: String) -> CaptureRoundWork {
        CaptureRoundWork(
            roundIndex: 1,
            captureMethod: .photo,
            alignmentMode: .verified,
            candidates: [CaptureCandidate(
                id: "frame_store",
                timestampMilliseconds: 0,
                localFilename: filename,
                metrics: metrics,
                localScore: 1,
                reasons: ["本地推荐"]
            )],
            selectedFrameID: "frame_store",
            selectionSource: .localRecommended,
            sourceFilename: nil,
            networkStep: .consent,
            mediaAssetID: nil,
            captureID: nil,
            evaluation: nil,
            uploadAttemptID: "upload-test",
            captureIdempotencyKey: "capture-test",
            evaluationIdempotencyKey: "evaluation-test"
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "soloshot-capture-store-\(UUID().uuidString)", directoryHint: .isDirectory)
    }
}
