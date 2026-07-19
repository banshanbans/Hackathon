import Foundation
import XCTest
@testable import SoloShot

final class ImportedTaskStoreTests: XCTestCase {
    private func task(now: Date = Date()) -> ImportedTask {
        ImportedTask(
            schemaVersion: "1.0",
            code: "ABC234",
            sessionID: "ss_test",
            planID: "sp_test",
            mode: "original_replication",
            cameraHeight: "waist",
            cameraAngle: "level",
            lens: "1x",
            captureMode: nil,
            setupInstruction: "固定手机。",
            actions: [ImportedAction(sequence: 1, instruction: "站好。", durationSeconds: 2)],
            safetyNotes: ["检查脚下。"],
            referenceID: nil,
            presetThumbnailName: nil,
            targetLayout: nil,
            iosAlignmentSupported: nil,
            localReferenceFilename: nil,
            importedAt: now,
            expiresAt: now.addingTimeInterval(86_400),
            completionConfirmed: false
        )
    }

    func testAtomicallyCachesAndRestoresOfflineTask() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "soloshot-store-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = ImportedTaskStore(directory: directory)
        let importedAt = Date(timeIntervalSince1970: 1_752_796_800)
        let expected = task(now: importedAt)
        try await store.save(expected)
        let restored = try await store.load(now: importedAt.addingTimeInterval(60))
        XCTAssertEqual(restored, expected)
        XCTAssertFalse(restored?.canStartAlignment ?? true)
        try await store.clear()
        let cleared = try await store.load(now: importedAt.addingTimeInterval(60))
        XCTAssertNil(cleared)
    }

    func testVersionTwoTaskRetainsAlignmentTarget() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "soloshot-store-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = ImportedTaskStore(directory: directory)
        let expected = makeW4ImportedTask()
        try await store.save(expected)
        let restored = try await store.load(now: expected.importedAt.addingTimeInterval(60))
        XCTAssertEqual(restored, expected)
        XCTAssertTrue(restored?.canStartAlignment == true)
        XCTAssertEqual(restored?.targetLayout?.poseTemplate, "doorway_crossed_legs")
    }

    func testExpiredAndCorruptCachesAreRemoved() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "soloshot-store-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = ImportedTaskStore(directory: directory)
        let now = Date()
        try await store.save(task(now: now.addingTimeInterval(-90_000)))
        let expired = try await store.load(now: now)
        XCTAssertNil(expired)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cacheURL = await store.cacheURL
        try Data("not-json".utf8).write(to: cacheURL)
        let corrupt = try await store.load(now: now)
        XCTAssertNil(corrupt)
    }
}
