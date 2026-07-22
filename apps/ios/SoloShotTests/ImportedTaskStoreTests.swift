import Foundation
import XCTest
@testable import SoloShot

final class ImportedTaskStoreTests: XCTestCase {
    private func task(
        now: Date = Date(),
        code: String = "294816",
        sessionID: String = "ss_test"
    ) -> ImportedTask {
        ImportedTask(
            schemaVersion: "1.0",
            code: code,
            sessionID: sessionID,
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

    func testVersionThreeTaskRetainsAlignmentTarget() async throws {
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

    func testVersionTwoCacheWithoutSilhouetteFieldsStillDecodes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "soloshot-v2-store-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = ImportedTaskStore(directory: directory)
        try await store.save(makeW4ImportedTask())
        let cacheURL = await store.cacheURL
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as? [String: Any]
        )
        object["schemaVersion"] = "2.0"
        object.removeValue(forKey: "referenceSelectedBox")
        object.removeValue(forKey: "referenceSilhouetteFilename")
        object.removeValue(forKey: "referenceSilhouetteStatus")
        try JSONSerialization.data(withJSONObject: object).write(to: cacheURL)

        let restored = try await store.loadUnchecked()
        XCTAssertEqual(restored?.schemaVersion, "2.0")
        XCTAssertNil(restored?.referenceSelectedBox)
        XCTAssertNil(restored?.referenceSilhouetteFilename)
        XCTAssertNil(restored?.referenceSilhouetteStatus)
        XCTAssertNotNil(restored?.targetLayout)
    }

    func testVersionThreePersistsAndDeletesDerivedSilhouette() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "soloshot-silhouette-store-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = ImportedTaskStore(directory: directory)
        let asset = ReferenceSilhouetteAsset(
            schemaVersion: "1.0",
            algorithmVersion: ReferenceSilhouetteAsset.algorithmVersion,
            sourceSHA256: "abc123",
            status: .ready,
            contour: .fixturePerson,
            extractedAt: Date(timeIntervalSince1970: 1_750_000_000)
        )
        let filename = try await store.saveSilhouette(asset, code: "294816")
        let restored = try await store.loadSilhouette(filename: filename)
        XCTAssertEqual(restored, asset)
        try await store.clear()
        let silhouetteURL = await store.referenceURL(filename: filename)
        XCTAssertFalse(FileManager.default.fileExists(atPath: silhouetteURL.path))
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

    func testListsMultipleUnexpiredTasksAndClearsOnlySelectedTask() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "soloshot-task-list-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = ImportedTaskStore(directory: directory)
        let now = Date(timeIntervalSince1970: 1_752_796_800)
        let older = task(now: now, code: "111111", sessionID: "ss_older")
        let newer = task(now: now.addingTimeInterval(120), code: "222222", sessionID: "ss_newer")
        let expired = task(now: now.addingTimeInterval(-90_000), code: "333333", sessionID: "ss_expired")
        try await store.save(older)
        try await store.save(newer)
        try await store.save(expired)

        let listed = try await store.loadAll(now: now.addingTimeInterval(180))
        XCTAssertEqual(listed.map(\.code), ["222222", "111111"])

        try await store.clear(code: newer.code)
        let remaining = try await store.loadAll(now: now.addingTimeInterval(180))
        XCTAssertEqual(remaining.map(\.code), ["111111"])
    }
}
