import Foundation
import SoloShotContracts

struct NormalizedPoint: Codable, Equatable, Sendable {
    let x: Double
    let y: Double

    init(x: Double, y: Double) {
        self.x = min(max(x, 0), 1)
        self.y = min(max(y, 0), 1)
    }
}

struct NormalizedRect: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        let safeX = min(max(x, 0), 1)
        let safeY = min(max(y, 0), 1)
        self.x = safeX
        self.y = safeY
        self.width = min(max(width, 0), 1 - safeX)
        self.height = min(max(height, 0), 1 - safeY)
    }

    var center: NormalizedPoint {
        NormalizedPoint(x: x + width / 2, y: y + height / 2)
    }

    var maxX: Double { x + width }
    var maxY: Double { y + height }

    func intersectionOverUnion(with other: NormalizedRect) -> Double {
        let intersectionWidth = max(0, min(maxX, other.maxX) - max(x, other.x))
        let intersectionHeight = max(0, min(maxY, other.maxY) - max(y, other.y))
        let intersection = intersectionWidth * intersectionHeight
        let union = width * height + other.width * other.height - intersection
        return union > 0 ? intersection / union : 0
    }
}

enum BodyJoint: String, Codable, CaseIterable, Sendable {
    case nose
    case neck
    case leftShoulder
    case rightShoulder
    case leftElbow
    case rightElbow
    case leftWrist
    case rightWrist
    case root
    case leftHip
    case rightHip
    case leftKnee
    case rightKnee
    case leftAnkle
    case rightAnkle
}

struct PoseJoint: Codable, Equatable, Sendable {
    let point: NormalizedPoint
    let confidence: Double
}

struct PersonObservation: Equatable, Sendable, Identifiable {
    let id: UUID
    let joints: [BodyJoint: PoseJoint]
    let boundingBox: NormalizedRect
    let confidence: Double
    let observedAt: Date

    init(
        id: UUID = UUID(),
        joints: [BodyJoint: PoseJoint],
        boundingBox: NormalizedRect,
        confidence: Double,
        observedAt: Date
    ) {
        self.id = id
        self.joints = joints
        self.boundingBox = boundingBox
        self.confidence = min(max(confidence, 0), 1)
        self.observedAt = observedAt
    }

    func joint(_ name: BodyJoint, minimumConfidence: Double) -> PoseJoint? {
        guard let value = joints[name], value.confidence >= minimumConfidence else {
            return nil
        }
        return value
    }
}

enum AlignmentCompletionMode: String, Codable, Equatable, Sendable {
    case verified
    case compositionOnly = "composition_only"
    case manual
}

struct AlignmentDecision: Equatable, Sendable {
    let alignment: CurrentAlignment
    let selectedPerson: PersonObservation?
    let completionMode: AlignmentCompletionMode?
    let manualReadyAvailable: Bool
    let poseCheckSupported: Bool
    let instructionConfirmed: Bool
    let latencyMilliseconds: Double
}

