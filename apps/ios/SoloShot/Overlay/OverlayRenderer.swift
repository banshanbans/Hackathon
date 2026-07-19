import CoreGraphics
import Foundation

struct OverlayPrimitives: Equatable {
    let imageRect: CGRect
    let targetRect: CGRect
    let targetHead: CGPoint
    let targetFootY: CGFloat
    let personRect: CGRect?
    let joints: [BodyJoint: CGPoint]
}

enum OverlayRenderer {
    static func primitives(
        target: ImportedTargetLayout,
        person: PersonObservation?,
        imageSize: CGSize,
        viewSize: CGSize,
        includeDebugJoints: Bool
    ) -> OverlayPrimitives {
        let imageRect = CoordinateMapper.aspectFillRect(
            NormalizedRect(x: 0, y: 0, width: 1, height: 1),
            imageSize: imageSize,
            viewSize: viewSize
        )
        let targetRect = CoordinateMapper.aspectFillRect(
            target.rect,
            imageSize: imageSize,
            viewSize: viewSize
        )
        let head = CoordinateMapper.aspectFillPoint(
            target.headPoint,
            imageSize: imageSize,
            viewSize: viewSize
        )
        let foot = CoordinateMapper.aspectFillPoint(
            NormalizedPoint(x: target.centerX, y: target.footLineY),
            imageSize: imageSize,
            viewSize: viewSize
        )
        let personRect = person.map {
            CoordinateMapper.aspectFillRect(
                $0.boundingBox,
                imageSize: imageSize,
                viewSize: viewSize
            )
        }
        let joints: [BodyJoint: CGPoint]
        if includeDebugJoints, let person {
            joints = person.joints.mapValues {
                CoordinateMapper.aspectFillPoint(
                    $0.point,
                    imageSize: imageSize,
                    viewSize: viewSize
                )
            }
        } else {
            joints = [:]
        }
        return OverlayPrimitives(
            imageRect: imageRect,
            targetRect: targetRect,
            targetHead: head,
            targetFootY: foot.y,
            personRect: personRect,
            joints: joints
        )
    }
}
