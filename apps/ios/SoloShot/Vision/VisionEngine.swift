import CoreGraphics
import CoreImage
import Foundation
import ImageIO
@preconcurrency import Vision

struct VisionJointSample: Equatable, Sendable {
    let joint: BodyJoint
    let visionPoint: NormalizedPoint
    let confidence: Double
}

final class VisionEngine {
    private let request = VNDetectHumanBodyPoseRequest()
    private let minimumConfidence: Float

    init(configuration: AlignmentConfiguration = .production) {
        minimumConfidence = Float(configuration.jointConfidence)
    }

    func observations(
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        observedAt: Date
    ) throws -> [PersonObservation] {
        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: orientation,
            options: [:]
        )
        try handler.perform([request])
        return try map(request.results ?? [], observedAt: observedAt)
    }

    func observations(
        cgImage: CGImage,
        orientation: CGImagePropertyOrientation = .up,
        observedAt: Date
    ) throws -> [PersonObservation] {
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
        try handler.perform([request])
        return try map(request.results ?? [], observedAt: observedAt)
    }

    private func map(
        _ observations: [VNHumanBodyPoseObservation],
        observedAt: Date
    ) throws -> [PersonObservation] {
        try observations.compactMap { observation in
            let points = try observation.recognizedPoints(.all)
            let samples: [VisionJointSample] = Self.jointMap.compactMap { entry in
                let (visionName, domainName) = entry
                guard let point = points[visionName] else { return nil }
                return VisionJointSample(
                    joint: domainName,
                    visionPoint: NormalizedPoint(x: point.location.x, y: point.location.y),
                    confidence: Double(point.confidence)
                )
            }
            return map(samples, id: observation.uuid, observedAt: observedAt)
        }
    }

    func map(
        _ samples: [VisionJointSample],
        id: UUID = UUID(),
        observedAt: Date
    ) -> PersonObservation? {
        var joints: [BodyJoint: PoseJoint] = [:]
        for sample in samples where sample.confidence >= Double(minimumConfidence) {
            joints[sample.joint] = PoseJoint(
                point: CoordinateMapper.visionPointToTopLeft(sample.visionPoint),
                confidence: sample.confidence
            )
        }
        guard !joints.isEmpty else { return nil }
        let values = joints.values.map(\.point)
        guard let minX = values.map(\.x).min(), let maxX = values.map(\.x).max(),
              let minY = values.map(\.y).min(), let maxY = values.map(\.y).max()
        else { return nil }
        let width = max(maxX - minX, 0.01)
        let height = max(maxY - minY, 0.01)
        let horizontalPadding = width * 0.12
        let verticalPadding = height * 0.03
        let box = NormalizedRect(
            x: minX - horizontalPadding,
            y: minY - verticalPadding,
            width: width + horizontalPadding * 2,
            height: height + verticalPadding * 2
        )
        let confidence = joints.values.map(\.confidence).reduce(0, +) / Double(joints.count)
        return PersonObservation(
            id: id,
            joints: joints,
            boundingBox: box,
            confidence: confidence,
            observedAt: observedAt
        )
    }

    private static let jointMap: [VNHumanBodyPoseObservation.JointName: BodyJoint] = [
        .nose: .nose,
        .neck: .neck,
        .leftShoulder: .leftShoulder,
        .rightShoulder: .rightShoulder,
        .leftElbow: .leftElbow,
        .rightElbow: .rightElbow,
        .leftWrist: .leftWrist,
        .rightWrist: .rightWrist,
        .root: .root,
        .leftHip: .leftHip,
        .rightHip: .rightHip,
        .leftKnee: .leftKnee,
        .rightKnee: .rightKnee,
        .leftAnkle: .leftAnkle,
        .rightAnkle: .rightAnkle,
    ]
}
