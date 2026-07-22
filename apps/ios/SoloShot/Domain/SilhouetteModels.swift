import CoreGraphics
import Foundation

enum ReferenceSilhouetteStatus: String, Codable, Equatable, Sendable {
    case pending
    case ready
    case noPerson = "no_person"
    case multiplePeople = "multiple_people"
    case partialPerson = "partial_person"
    case extractionFailed = "extraction_failed"

    var userMessage: String {
        switch self {
        case .ready:
            "参考轮廓已就绪"
        case .pending:
            "正在提取参考轮廓"
        case .noPerson, .multiplePeople, .partialPerson, .extractionFailed:
            "参考轮廓不可用，使用构图辅助"
        }
    }
}

struct SilhouetteContour: Codable, Equatable, Sendable {
    /// Closed loops in normalized top-left coordinates. The first loop is the outer boundary;
    /// subsequent loops are meaningful holes such as spaces between an arm and the torso.
    let loops: [[NormalizedPoint]]

    var isUsable: Bool {
        loops.first?.count ?? 0 >= 3
    }

    var bounds: NormalizedRect? {
        let points = loops.flatMap { $0 }
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

    func normalizedToTightBounds() -> SilhouetteContour? {
        guard let bounds, bounds.width > 0, bounds.height > 0 else { return nil }
        return SilhouetteContour(loops: loops.map { loop in
            loop.map { point in
                NormalizedPoint(
                    x: (point.x - bounds.x) / bounds.width,
                    y: (point.y - bounds.y) / bounds.height
                )
            }
        })
    }

    func transformed(into rect: NormalizedRect) -> SilhouetteContour {
        SilhouetteContour(loops: loops.map { loop in
            loop.map { point in
                NormalizedPoint(
                    x: rect.x + point.x * rect.width,
                    y: rect.y + point.y * rect.height
                )
            }
        })
    }

    func smoothed(with previous: SilhouetteContour?, alpha: Double = 0.45) -> SilhouetteContour {
        guard let currentOuter = loops.first,
              let previousOuter = previous?.loops.first
        else { return self }
        let pointCount = 96
        let current = Self.resample(currentOuter, count: pointCount)
        let older = Self.resample(previousOuter, count: pointCount)
        guard current.count == pointCount, older.count == pointCount else { return self }
        let safeAlpha = min(max(alpha, 0), 1)
        let blended = zip(older, current).map { old, new in
            NormalizedPoint(
                x: old.x * (1 - safeAlpha) + new.x * safeAlpha,
                y: old.y * (1 - safeAlpha) + new.y * safeAlpha
            )
        }
        return SilhouetteContour(loops: [blended] + Array(loops.dropFirst()))
    }

    private static func resample(_ source: [NormalizedPoint], count: Int) -> [NormalizedPoint] {
        guard source.count >= 3, count >= 3 else { return source }
        var points = source
        if signedArea(points) < 0 { points.reverse() }
        if let start = points.indices.min(by: {
            points[$0].y == points[$1].y ? points[$0].x < points[$1].x : points[$0].y < points[$1].y
        }) {
            points = Array(points[start...]) + Array(points[..<start])
        }
        let closed = points + [points[0]]
        var lengths = [Double](repeating: 0, count: closed.count)
        for index in 1 ..< closed.count {
            lengths[index] = lengths[index - 1] + distance(closed[index - 1], closed[index])
        }
        guard let total = lengths.last, total > 0 else { return source }
        return (0 ..< count).map { sample in
            let target = total * Double(sample) / Double(count)
            let segment = max(1, lengths.firstIndex(where: { $0 >= target }) ?? lengths.count - 1)
            let startLength = lengths[segment - 1]
            let segmentLength = max(lengths[segment] - startLength, 0.000_001)
            let ratio = (target - startLength) / segmentLength
            let lhs = closed[segment - 1]
            let rhs = closed[segment]
            return NormalizedPoint(
                x: lhs.x + (rhs.x - lhs.x) * ratio,
                y: lhs.y + (rhs.y - lhs.y) * ratio
            )
        }
    }

    private static func signedArea(_ points: [NormalizedPoint]) -> Double {
        points.indices.reduce(into: 0.0) { result, index in
            let next = points[(index + 1) % points.count]
            result += points[index].x * next.y - next.x * points[index].y
        } / 2
    }

    private static func distance(_ lhs: NormalizedPoint, _ rhs: NormalizedPoint) -> Double {
        hypot(rhs.x - lhs.x, rhs.y - lhs.y)
    }
}

struct ReferenceSilhouetteAsset: Codable, Equatable, Sendable {
    static let algorithmVersion = "1.0.0"

    let schemaVersion: String
    let algorithmVersion: String
    let sourceSHA256: String
    let status: ReferenceSilhouetteStatus
    let contour: SilhouetteContour?
    let extractedAt: Date

    static func unavailable(
        _ status: ReferenceSilhouetteStatus,
        sourceSHA256: String,
        extractedAt: Date = Date()
    ) -> ReferenceSilhouetteAsset {
        ReferenceSilhouetteAsset(
            schemaVersion: "1.0",
            algorithmVersion: algorithmVersion,
            sourceSHA256: sourceSHA256,
            status: status,
            contour: nil,
            extractedAt: extractedAt
        )
    }
}

struct SilhouetteObservation: Equatable, Sendable {
    let contour: SilhouetteContour
    let confidence: Double
    let observedAt: Date

    init(contour: SilhouetteContour, confidence: Double, observedAt: Date) {
        self.contour = contour
        self.confidence = min(max(confidence, 0), 1)
        self.observedAt = observedAt
    }
}

struct SilhouetteMatch: Equatable, Sendable {
    let score: Double
    let observedAt: Date

    init(score: Double, observedAt: Date) {
        self.score = min(max(score, 0), 1)
        self.observedAt = observedAt
    }
}

enum SilhouetteMatcher {
    static func dice(
        reference: SilhouetteContour,
        live: SilhouetteContour,
        width: Int = 96,
        height: Int = 160
    ) -> Double? {
        guard reference.isUsable, live.isUsable, width > 0, height > 0,
              let referenceMask = rasterize(reference, width: width, height: height),
              let liveMask = rasterize(live, width: width, height: height)
        else { return nil }

        var referenceCount = 0
        var liveCount = 0
        var intersection = 0
        for index in referenceMask.indices {
            let referenceOn = referenceMask[index] > 0
            let liveOn = liveMask[index] > 0
            if referenceOn { referenceCount += 1 }
            if liveOn { liveCount += 1 }
            if referenceOn, liveOn { intersection += 1 }
        }
        let total = referenceCount + liveCount
        return total > 0 ? Double(2 * intersection) / Double(total) : nil
    }

    private static func rasterize(
        _ contour: SilhouetteContour,
        width: Int,
        height: Int
    ) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.beginPath()
        for loop in contour.loops where loop.count >= 3 {
            context.move(to: CGPoint(x: loop[0].x * Double(width), y: loop[0].y * Double(height)))
            for point in loop.dropFirst() {
                context.addLine(to: CGPoint(x: point.x * Double(width), y: point.y * Double(height)))
            }
            context.closePath()
        }
        context.fillPath(using: .evenOdd)
        return pixels
    }
}

extension SilhouetteContour {
    static let fixturePerson = SilhouetteContour(loops: [[
        NormalizedPoint(x: 0.50, y: 0.00),
        NormalizedPoint(x: 0.40, y: 0.03),
        NormalizedPoint(x: 0.35, y: 0.10),
        NormalizedPoint(x: 0.38, y: 0.18),
        NormalizedPoint(x: 0.28, y: 0.23),
        NormalizedPoint(x: 0.18, y: 0.38),
        NormalizedPoint(x: 0.25, y: 0.43),
        NormalizedPoint(x: 0.37, y: 0.31),
        NormalizedPoint(x: 0.34, y: 0.57),
        NormalizedPoint(x: 0.26, y: 0.78),
        NormalizedPoint(x: 0.30, y: 1.00),
        NormalizedPoint(x: 0.43, y: 1.00),
        NormalizedPoint(x: 0.50, y: 0.68),
        NormalizedPoint(x: 0.57, y: 1.00),
        NormalizedPoint(x: 0.70, y: 1.00),
        NormalizedPoint(x: 0.74, y: 0.78),
        NormalizedPoint(x: 0.66, y: 0.57),
        NormalizedPoint(x: 0.63, y: 0.31),
        NormalizedPoint(x: 0.75, y: 0.43),
        NormalizedPoint(x: 0.82, y: 0.38),
        NormalizedPoint(x: 0.72, y: 0.23),
        NormalizedPoint(x: 0.62, y: 0.18),
        NormalizedPoint(x: 0.65, y: 0.10),
        NormalizedPoint(x: 0.60, y: 0.03),
    ]])
}
