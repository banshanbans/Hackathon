import Foundation
import XCTest
@testable import SoloShot

private struct StubCameraAuthorization: CameraAuthorizationProviding {
    let state: CameraPermissionState
    let requestResult: Bool

    func currentState() -> CameraPermissionState { state }
    func requestAccess() async -> Bool { requestResult }
}

@MainActor
final class AppFlowW4Tests: XCTestCase {
    func testSummaryMovesToSetupAndDeniedPermissionIsRecoverable() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "soloshot-flow-\(UUID().uuidString)", directoryHint: .isDirectory)
        let flow = AppFlowModel(
            tasks: ImportedTaskStore(directory: directory),
            cameraAuthorization: StubCameraAuthorization(state: .denied, requestResult: false)
        )
        let task = makeW4ImportedTask(now: Date())
        flow.openSetup(task)
        XCTAssertEqual(flow.state, .setup(task))
        flow.beginAlignment(for: task, voiceEnabled: false, hapticsEnabled: false)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(flow.state, .cameraError(task, .permissionDenied))
        flow.returnToSetup(task)
        XCTAssertEqual(flow.state, .setup(task))
    }

    func testLegacyTaskCannotEnterSetup() {
        var task = makeW4ImportedTask(now: Date())
        task = ImportedTask(
            schemaVersion: "1.0",
            code: task.code,
            sessionID: task.sessionID,
            planID: task.planID,
            mode: task.mode,
            cameraHeight: task.cameraHeight,
            cameraAngle: task.cameraAngle,
            lens: task.lens,
            captureMode: nil,
            setupInstruction: task.setupInstruction,
            actions: task.actions,
            safetyNotes: task.safetyNotes,
            referenceID: task.referenceID,
            presetThumbnailName: task.presetThumbnailName,
            targetLayout: nil,
            iosAlignmentSupported: nil,
            localReferenceFilename: nil,
            importedAt: task.importedAt,
            expiresAt: task.expiresAt,
            completionConfirmed: task.completionConfirmed
        )
        let flow = AppFlowModel()
        flow.openSetup(task)
        XCTAssertEqual(flow.state, .launch)
    }
}

