import CoreGraphics
import Foundation
import UIKit
import Vision

struct ProcessedCandidateFrame: Sendable {
    let jpeg: Data
    let metrics: FrameQualityMetrics
}

enum CandidateFrameProcessor {
    static func process(
        jpeg original: Data,
        target: ImportedTargetLayout
    ) async throws -> ProcessedCandidateFrame {
        try await Task.detached(priority: .userInitiated) {
            guard let source = UIImage(data: original) else {
                throw CaptureEngineError.processingFailed
            }
            let normalized = normalize(source)
            guard let cgImage = normalized.cgImage,
                  let jpeg = normalized.jpegData(compressionQuality: 0.86),
                  jpeg.count <= 8_000_000
            else {
                throw CaptureEngineError.processingFailed
            }
            let request = VNDetectHumanBodyPoseRequest()
            try VNImageRequestHandler(cgImage: cgImage, orientation: .up).perform([request])
            let people = try (request.results ?? []).compactMap(personObservation)
            let selected = people.max { lhs, rhs in
                lhs.boundingBox.intersectionOverUnion(with: target.rect)
                    < rhs.boundingBox.intersectionOverUnion(with: target.rect)
            }
            let fullBody = selected.map { person in
                (person.joint(.nose, minimumConfidence: 0.3) != nil
                    || person.joint(.neck, minimumConfidence: 0.3) != nil)
                    && person.joint(.leftAnkle, minimumConfidence: 0.3) != nil
                    && person.joint(.rightAnkle, minimumConfidence: 0.3) != nil
            } ?? false
            let position = selected.map {
                1 - min(1, abs($0.boundingBox.center.x - target.rect.center.x) / 0.30)
            } ?? 0
            let scale = selected.map {
                1 - min(1, abs($0.boundingBox.height - target.rect.height) / max(target.rect.height, 0.01))
            } ?? 0
            let completeness = fullBody ? 1 : selected == nil ? 0 : 0.45
            let pose = selected.flatMap { supportedPoseScore($0, target: target) }
            return ProcessedCandidateFrame(
                jpeg: jpeg,
                metrics: FrameQualityMetrics(
                    completeFraming: completeness,
                    targetPositionMatch: position,
                    personScaleMatch: scale,
                    sharpness: sharpness(cgImage),
                    supportedPoseMatch: pose,
                    personCount: people.count,
                    headAndFeetVisible: fullBody,
                    averageConfidence: selected?.confidence ?? 0
                )
            )
        }.value
    }

    private static func normalize(_ image: UIImage) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        let scale = min(1, 2_048 / max(longest, 1))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    private static func personObservation(
        _ observation: VNHumanBodyPoseObservation
    ) throws -> PersonObservation? {
        let points = try observation.recognizedPoints(.all)
        let mapping: [(VNHumanBodyPoseObservation.JointName, BodyJoint)] = [
            (.nose, .nose), (.neck, .neck),
            (.leftShoulder, .leftShoulder), (.rightShoulder, .rightShoulder),
            (.leftElbow, .leftElbow), (.rightElbow, .rightElbow),
            (.leftWrist, .leftWrist), (.rightWrist, .rightWrist),
            (.root, .root), (.leftHip, .leftHip), (.rightHip, .rightHip),
            (.leftKnee, .leftKnee), (.rightKnee, .rightKnee),
            (.leftAnkle, .leftAnkle), (.rightAnkle, .rightAnkle),
        ]
        var joints: [BodyJoint: PoseJoint] = [:]
        for (visionName, domainName) in mapping {
            guard let point = points[visionName], point.confidence >= 0.2 else { continue }
            joints[domainName] = PoseJoint(
                point: NormalizedPoint(x: point.location.x, y: 1 - point.location.y),
                confidence: Double(point.confidence)
            )
        }
        let credible = joints.values.filter { $0.confidence >= 0.3 }
        guard !credible.isEmpty else { return nil }
        let xs = credible.map(\.point.x)
        let ys = credible.map(\.point.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else {
            return nil
        }
        let average = credible.map(\.confidence).reduce(0, +) / Double(credible.count)
        return PersonObservation(
            joints: joints,
            boundingBox: NormalizedRect(
                x: minX,
                y: minY,
                width: max(maxX - minX, 0.01),
                height: max(maxY - minY, 0.01)
            ),
            confidence: average,
            observedAt: Date()
        )
    }

    private static func supportedPoseScore(
        _ person: PersonObservation,
        target: ImportedTargetLayout
    ) -> Double? {
        guard let rule = AlignmentConfiguration.production.armRules[target.poseTemplate] else {
            return nil
        }
        switch rule {
        case .none:
            return 1
        case .oneWristAboveHip:
            let pairs: [(BodyJoint, BodyJoint)] = [(.leftWrist, .leftHip), (.rightWrist, .rightHip)]
            let hasMatch = pairs.contains { wrist, hip in
                guard let wrist = person.joint(wrist, minimumConfidence: 0.3)?.point,
                      let hip = person.joint(hip, minimumConfidence: 0.3)?.point
                else { return false }
                return wrist.y < hip.y
            }
            return hasMatch ? 1 : 0.25
        case .oneArmExtended:
            let pairs: [(BodyJoint, BodyJoint, BodyJoint)] = [
                (.leftShoulder, .leftElbow, .leftWrist),
                (.rightShoulder, .rightElbow, .rightWrist),
            ]
            let hasMatch = pairs.contains { shoulder, elbow, wrist in
                guard let shoulder = person.joint(shoulder, minimumConfidence: 0.3)?.point,
                      let elbow = person.joint(elbow, minimumConfidence: 0.3)?.point,
                      let wrist = person.joint(wrist, minimumConfidence: 0.3)?.point
                else { return false }
                return abs(wrist.x - shoulder.x) > abs(elbow.y - shoulder.y)
            }
            return hasMatch ? 1 : 0.25
        }
    }

    private static func sharpness(_ image: CGImage) -> Double {
        let width = 96
        let height = 96
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return 0 }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var total = 0.0
        var comparisons = 0
        for y in 1 ..< height {
            for x in 1 ..< width {
                let value = Int(pixels[y * width + x])
                total += Double(abs(value - Int(pixels[y * width + x - 1])))
                total += Double(abs(value - Int(pixels[(y - 1) * width + x])))
                comparisons += 2
            }
        }
        return min(max((total / Double(max(comparisons, 1))) / 22, 0), 1)
    }
}
