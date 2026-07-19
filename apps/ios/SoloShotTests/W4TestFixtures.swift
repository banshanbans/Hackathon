import Foundation
@testable import SoloShot

func makeW4ImportedTask(now: Date = Date(timeIntervalSince1970: 1_750_000_000)) -> ImportedTask {
    ImportedTask(
        schemaVersion: "2.0",
        code: "ABC234",
        sessionID: "ss_w4_test",
        planID: "sp_w4_test",
        mode: "original_replication",
        cameraHeight: "waist",
        cameraAngle: "level",
        lens: "1x",
        captureMode: "photo",
        setupInstruction: "固定手机。",
        actions: [ImportedAction(sequence: 1, instruction: "站好。", durationSeconds: 2)],
        safetyNotes: ["检查脚下。"],
        referenceID: nil,
        presetThumbnailName: nil,
        targetLayout: ImportedTargetLayout(
            centerX: 0.5,
            centerY: 0.55,
            width: 0.3,
            height: 0.6,
            headPoint: NormalizedPoint(x: 0.5, y: 0.25),
            footLineY: 0.85,
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

