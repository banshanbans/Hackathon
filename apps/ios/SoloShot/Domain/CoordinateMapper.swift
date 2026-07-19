import CoreGraphics
import Foundation

enum CaptureRotation: Equatable, Sendable {
    case degrees0
    case degrees90
    case degrees180
    case degrees270
}

enum CoordinateMapper {
    static func visionPointToTopLeft(
        _ point: NormalizedPoint,
        rotation: CaptureRotation = .degrees0
    ) -> NormalizedPoint {
        let topLeft = NormalizedPoint(x: point.x, y: 1 - point.y)
        return switch rotation {
        case .degrees0:
            topLeft
        case .degrees90:
            NormalizedPoint(x: 1 - topLeft.y, y: topLeft.x)
        case .degrees180:
            NormalizedPoint(x: 1 - topLeft.x, y: 1 - topLeft.y)
        case .degrees270:
            NormalizedPoint(x: topLeft.y, y: 1 - topLeft.x)
        }
    }

    static func aspectFillRect(
        _ normalized: NormalizedRect,
        imageSize: CGSize,
        viewSize: CGSize
    ) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              viewSize.width > 0, viewSize.height > 0
        else {
            return .zero
        }
        let scale = max(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let scaled = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let offsetX = (viewSize.width - scaled.width) / 2
        let offsetY = (viewSize.height - scaled.height) / 2
        return CGRect(
            x: offsetX + normalized.x * scaled.width,
            y: offsetY + normalized.y * scaled.height,
            width: normalized.width * scaled.width,
            height: normalized.height * scaled.height
        )
    }

    static func aspectFillPoint(
        _ normalized: NormalizedPoint,
        imageSize: CGSize,
        viewSize: CGSize
    ) -> CGPoint {
        let unit = NormalizedRect(x: normalized.x, y: normalized.y, width: 0, height: 0)
        return aspectFillRect(unit, imageSize: imageSize, viewSize: viewSize).origin
    }
}

