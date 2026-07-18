import Foundation
import SoloShotContracts

struct ImportedAction: Codable, Equatable, Sendable, Identifiable {
    let sequence: Int
    let instruction: String
    let durationSeconds: Double

    var id: Int { sequence }
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
    let setupInstruction: String
    let actions: [ImportedAction]
    let safetyNotes: [String]
    let referenceID: String?
    let presetThumbnailName: String?
    var localReferenceFilename: String?
    let importedAt: Date
    let expiresAt: Date
    var completionConfirmed: Bool

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
        return ImportedTask(
            schemaVersion: "1.0",
            code: claim.handoff.code,
            sessionID: claim.session.sessionId,
            planID: plan.planId,
            mode: claim.session.mode.rawValue,
            cameraHeight: plan.cameraHeight.rawValue,
            cameraAngle: plan.cameraAngle.rawValue,
            lens: plan.lens.rawValue,
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
            localReferenceFilename: nil,
            importedAt: now,
            expiresAt: now.addingTimeInterval(86_400),
            completionConfirmed: false
        )
    }
}
