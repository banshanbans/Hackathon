import CoreGraphics
import CoreImage
import CoreVideo
import CryptoKit
import Foundation
import ImageIO
import UIKit
@preconcurrency import Vision

enum SilhouetteExtractionError: Error, Equatable {
    case invalidImage
    case noMask
    case noContour
}

struct ReferencePoseCandidate: Equatable, Sendable {
    let fullBodyVisible: Bool
}

enum ReferenceLabelSelection: Equatable {
    case selected(Int)
    case unavailable(ReferenceSilhouetteStatus)
}

enum ReferenceSilhouetteSelector {
    static func poseStatus(_ candidates: [ReferencePoseCandidate]) -> ReferenceSilhouetteStatus {
        if candidates.isEmpty { return .noPerson }
        if candidates.count > 1 { return .multiplePeople }
        return candidates[0].fullBodyVisible ? .ready : .partialPerson
    }

    static func selectLabel(from counts: [Int: Int]) -> ReferenceLabelSelection {
        let ranked = counts.filter { $0.key > 0 && $0.value > 0 }.sorted { $0.value > $1.value }
        guard let selected = ranked.first else { return .unavailable(.noPerson) }
        if ranked.count > 1, ranked[1].value * 3 > selected.value {
            return .unavailable(.multiplePeople)
        }
        return .selected(selected.key)
    }
}

enum MaskContourExtractor {
    static func contour(
        from mask: CVPixelBuffer,
        preferredBox: NormalizedRect? = nil
    ) throws -> SilhouetteContour {
        let request = VNDetectContoursRequest()
        request.maximumImageDimension = 256
        request.contrastAdjustment = 1
        request.detectsDarkOnLight = false
        let handler = VNImageRequestHandler(cvPixelBuffer: mask, orientation: .up, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first else {
            throw SilhouetteExtractionError.noContour
        }

        let candidates = try observation.topLevelContours.compactMap { contour -> ([[NormalizedPoint]], Double)? in
            let outer = try simplifiedPoints(contour)
            let outerArea = polygonArea(outer)
            guard outer.count >= 3, outerArea >= 0.005 else { return nil }
            let meaningfulHoles = try contour.childContours.compactMap { child -> [NormalizedPoint]? in
                let points = try simplifiedPoints(child)
                let area = polygonArea(points)
                return points.count >= 3 && area >= max(0.000_5, outerArea * 0.003) ? points : nil
            }
            let loops = [outer] + meaningfulHoles
            let contour = SilhouetteContour(loops: loops)
            let preference = if let preferredBox, let bounds = contour.bounds {
                bounds.intersectionOverUnion(with: preferredBox) * 3 + outerArea
            } else {
                outerArea
            }
            return (loops, preference)
        }
        guard let selected = candidates.max(by: { $0.1 < $1.1 }) else {
            throw SilhouetteExtractionError.noContour
        }
        return SilhouetteContour(loops: selected.0)
    }

    private static func simplifiedPoints(_ contour: VNContour) throws -> [NormalizedPoint] {
        let simplified = try contour.polygonApproximation(epsilon: 0.004)
        return simplified.normalizedPoints.map { point in
            // Vision contours use a lower-left origin. The app domain uses top-left.
            NormalizedPoint(x: Double(point.x), y: 1 - Double(point.y))
        }
    }

    static func polygonArea(_ points: [NormalizedPoint]) -> Double {
        guard points.count >= 3 else { return 0 }
        var area = 0.0
        for index in points.indices {
            let next = points[(index + 1) % points.count]
            area += points[index].x * next.y - next.x * points[index].y
        }
        return abs(area) / 2
    }
}

struct ReferenceSilhouetteExtractor: Sendable {
    func extract(
        data: Data,
        selectedBox: NormalizedRect,
        extractedAt: Date = Date()
    ) -> ReferenceSilhouetteAsset {
        let digest = Self.sha256(data)
        guard let image = normalizedCGImage(data) else {
            return .unavailable(.extractionFailed, sourceSHA256: digest, extractedAt: extractedAt)
        }

        do {
            let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
            let poseRequest = VNDetectHumanBodyPoseRequest()
            let maskRequest = VNGeneratePersonInstanceMaskRequest()
            try handler.perform([poseRequest, maskRequest])

            let relevantPoses = try (poseRequest.results ?? []).compactMap { observation -> ReferencePoseCandidate? in
                let points = try observation.recognizedPoints(.all)
                let credible = points.values.filter { $0.confidence >= 0.30 }
                guard !credible.isEmpty else { return nil }
                let domainPoints = credible.map {
                    NormalizedPoint(x: $0.location.x, y: 1 - $0.location.y)
                }
                guard let box = bounds(domainPoints), overlapFraction(box, selectedBox) >= 0.15 else {
                    return nil
                }
                let headVisible = (points[.nose]?.confidence ?? 0) >= 0.30
                    || (points[.neck]?.confidence ?? 0) >= 0.30
                let feetVisible = (points[.leftAnkle]?.confidence ?? 0) >= 0.30
                    && (points[.rightAnkle]?.confidence ?? 0) >= 0.30
                return ReferencePoseCandidate(fullBodyVisible: headVisible && feetVisible)
            }
            let poseStatus = ReferenceSilhouetteSelector.poseStatus(relevantPoses)
            guard poseStatus == .ready else {
                return .unavailable(poseStatus, sourceSHA256: digest, extractedAt: extractedAt)
            }
            guard let instanceObservation = maskRequest.results?.first else {
                return .unavailable(.noPerson, sourceSHA256: digest, extractedAt: extractedAt)
            }
            let labelSelection = ReferenceSilhouetteSelector.selectLabel(
                from: labelCounts(in: instanceObservation.instanceMask, selectedBox: selectedBox)
            )
            let selectedLabel: Int
            switch labelSelection {
            case let .selected(value):
                selectedLabel = value
            case let .unavailable(status):
                return .unavailable(status, sourceSHA256: digest, extractedAt: extractedAt)
            }
            let mask = try instanceObservation.generateMask(
                forInstances: IndexSet(integer: selectedLabel)
            )
            guard let contour = try MaskContourExtractor.contour(from: mask).normalizedToTightBounds() else {
                return .unavailable(.extractionFailed, sourceSHA256: digest, extractedAt: extractedAt)
            }
            return ReferenceSilhouetteAsset(
                schemaVersion: "1.0",
                algorithmVersion: ReferenceSilhouetteAsset.algorithmVersion,
                sourceSHA256: digest,
                status: .ready,
                contour: contour,
                extractedAt: extractedAt
            )
        } catch {
            return .unavailable(.extractionFailed, sourceSHA256: digest, extractedAt: extractedAt)
        }
    }

    func normalizedCGImage(_ data: Data) -> CGImage? {
        guard let image = UIImage(data: data) else { return nil }
        let pixelWidth = max(Int(image.size.width * image.scale), 1)
        let pixelHeight = max(Int(image.size.height * image.scale), 1)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(
            size: CGSize(width: pixelWidth, height: pixelHeight),
            format: format
        ).image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        }.cgImage
    }

    private func bounds(_ points: [NormalizedPoint]) -> NormalizedRect? {
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max()
        else { return nil }
        return NormalizedRect(
            x: minX,
            y: minY,
            width: max(maxX - minX, 0.000_001),
            height: max(maxY - minY, 0.000_001)
        )
    }

    private func overlapFraction(_ lhs: NormalizedRect, _ rhs: NormalizedRect) -> Double {
        let width = max(0, min(lhs.maxX, rhs.maxX) - max(lhs.x, rhs.x))
        let height = max(0, min(lhs.maxY, rhs.maxY) - max(lhs.y, rhs.y))
        let intersection = width * height
        return intersection / max(lhs.width * lhs.height, 0.000_001)
    }

    private func labelCounts(
        in mask: CVPixelBuffer,
        selectedBox: NormalizedRect
    ) -> [Int: Int] {
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(mask) else { return [:] }
        let width = CVPixelBufferGetWidth(mask)
        let height = CVPixelBufferGetHeight(mask)
        let rowBytes = CVPixelBufferGetBytesPerRow(mask)
        let minX = max(0, min(width - 1, Int(selectedBox.x * Double(width))))
        let maxX = max(minX + 1, min(width, Int((selectedBox.maxX * Double(width)).rounded(.up))))
        let minY = max(0, min(height - 1, Int(selectedBox.y * Double(height))))
        let maxY = max(minY + 1, min(height, Int((selectedBox.maxY * Double(height)).rounded(.up))))
        let format = CVPixelBufferGetPixelFormatType(mask)
        var counts: [Int: Int] = [:]
        for y in minY ..< maxY {
            for x in minX ..< maxX {
                let label: Int
                if format == kCVPixelFormatType_OneComponent32Float {
                    let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float.self)
                    label = Int(row[x].rounded())
                } else {
                    let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
                    label = Int(row[x])
                }
                if label > 0 { counts[label, default: 0] += 1 }
            }
        }
        return counts
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

final class LiveSilhouetteEngine {
    private let request = VNGeneratePersonSegmentationRequest()
    private let sequenceHandler = VNSequenceRequestHandler()

    init() {
        request.qualityLevel = .fast
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
    }

    func observation(
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        person: PersonObservation,
        observedAt: Date
    ) throws -> SilhouetteObservation? {
        try sequenceHandler.perform([request], on: pixelBuffer, orientation: orientation)
        guard let mask = request.results?.first?.pixelBuffer else { return nil }
        let contour = try MaskContourExtractor.contour(
            from: mask,
            preferredBox: person.boundingBox
        )
        guard let bounds = contour.bounds,
              bounds.intersectionOverUnion(with: person.boundingBox) >= 0.05
        else { return nil }
        return SilhouetteObservation(
            contour: contour,
            confidence: person.confidence,
            observedAt: observedAt
        )
    }
}
