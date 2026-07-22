import Foundation
import SoloShotContracts

struct ImportedAction: Codable, Equatable, Sendable, Identifiable {
    let sequence: Int
    let instruction: String
    let durationSeconds: Double

    var id: Int { sequence }
}

struct ImportedTargetLayout: Codable, Equatable, Sendable {
    let centerX: Double
    let centerY: Double
    let width: Double
    let height: Double
    let headPoint: NormalizedPoint
    let footLineY: Double
    let bodyDirection: String
    let poseTemplate: String

    var rect: NormalizedRect {
        NormalizedRect(
            x: centerX - width / 2,
            y: centerY - height / 2,
            width: width,
            height: height
        )
    }
}

struct ImportedTask: Codable, Equatable, Sendable {
    let schemaVersion: String
    let code: String
    let sessionID: String
    let planID: String
    let mode: String
    let cameraHeight: String
    let cameraAngle: String
    let lens: String
    let captureMode: String?
    let setupInstruction: String
    let actions: [ImportedAction]
    let safetyNotes: [String]
    let referenceID: String?
    let presetThumbnailName: String?
    var referenceSelectedBox: NormalizedRect? = nil
    let targetLayout: ImportedTargetLayout?
    let iosAlignmentSupported: Bool?
    var localReferenceFilename: String?
    var referenceSilhouetteFilename: String? = nil
    var referenceSilhouetteStatus: ReferenceSilhouetteStatus? = nil
    let importedAt: Date
    let expiresAt: Date
    var completionConfirmed: Bool

    var canStartAlignment: Bool {
        targetLayout != nil && iosAlignmentSupported == true
    }

    static func from(_ claim: HandoffClaimResult, now: Date = Date()) throws -> ImportedTask {
        guard let plan = claim.session.shotPlan else {
            throw HandoffClientError.invalidResponse
        }
        let referenceID = claim.session.referenceAsset?.referenceId
        let presetName: String? = switch referenceID {
        case "ref_doorway_coffee_fullbody": "doorway_coffee_fullbody-thumb"
        case "ref_cafe_seated_drink": "cafe_seated_drink-thumb"
        case "ref_stone_village_lean": "stone_village_lean-thumb"
        case "ref_storefront_profile": "storefront_profile-thumb"
        default: nil
        }
        let layout = plan.targetLayout
        return ImportedTask(
            schemaVersion: "3.0",
            code: claim.handoff.code,
            sessionID: claim.session.sessionId,
            planID: plan.planId,
            mode: claim.session.mode.rawValue,
            cameraHeight: plan.cameraHeight.rawValue,
            cameraAngle: plan.cameraAngle.rawValue,
            lens: plan.lens.rawValue,
            captureMode: plan.captureMode.rawValue,
            setupInstruction: plan.phoneSetupInstruction,
            actions: plan.actionScript.map {
                ImportedAction(
                    sequence: $0.sequence,
                    instruction: $0.instruction,
                    durationSeconds: $0.durationSeconds
                )
            },
            safetyNotes: plan.safetyNotes,
            referenceID: referenceID,
            presetThumbnailName: presetName,
            referenceSelectedBox: claim.session.referenceAsset.map {
                NormalizedRect(
                    x: $0.selectedBox.x,
                    y: $0.selectedBox.y,
                    width: $0.selectedBox.width,
                    height: $0.selectedBox.height
                )
            },
            targetLayout: ImportedTargetLayout(
                centerX: layout.centerX,
                centerY: layout.centerY,
                width: layout.width,
                height: layout.height,
                headPoint: NormalizedPoint(x: layout.headPoint.x, y: layout.headPoint.y),
                footLineY: layout.footLineY,
                bodyDirection: layout.bodyDirection.rawValue,
                poseTemplate: layout.poseTemplate
            ),
            iosAlignmentSupported: plan.iosExecution.supported,
            localReferenceFilename: nil,
            importedAt: now,
            expiresAt: now.addingTimeInterval(86_400),
            completionConfirmed: false
        )
    }
}
