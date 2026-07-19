import Foundation

enum CoarseArmRule: Equatable, Sendable {
    case none
    case oneWristAboveHip
    case oneArmExtended
}

struct AlignmentConfiguration: Equatable, Sendable {
    let jointConfidence: Double
    let crediblePersonConfidence: Double
    let horizontalEnterTolerance: Double
    let horizontalExitTolerance: Double
    let heightEnterTolerance: Double
    let heightExitTolerance: Double
    let instructionConfirmationSamples: Int
    let readyMinimumSamples: Int
    let readyMinimumDuration: TimeInterval
    let manualFallbackDelay: TimeInterval
    let speechMinimumInterval: TimeInterval
    let nominalSampleInterval: TimeInterval
    let degradedSampleInterval: TimeInterval
    let armRules: [String: CoarseArmRule]

    static let production = AlignmentConfiguration(
        jointConfidence: 0.30,
        crediblePersonConfidence: 0.25,
        horizontalEnterTolerance: 0.06,
        horizontalExitTolerance: 0.12,
        heightEnterTolerance: 0.10,
        heightExitTolerance: 0.18,
        instructionConfirmationSamples: 3,
        readyMinimumSamples: 3,
        readyMinimumDuration: 1.2,
        manualFallbackDelay: 5,
        speechMinimumInterval: 2,
        nominalSampleInterval: 0.10,
        degradedSampleInterval: 0.20,
        armRules: [
            "doorway_crossed_legs": .none,
            "walking_turn": .none,
            "standing_turn": .none,
            "wall_lean_three_quarter": .none,
            "seated_forward_lean": .none,
            "standing_coffee_full_body": .oneWristAboveHip,
            "profile_bottle_closeup": .oneWristAboveHip,
            "seated_drink": .oneWristAboveHip,
            "umbrella_half_body": .oneWristAboveHip,
            "foreground_receipt_reach": .oneArmExtended,
        ]
    )
}

