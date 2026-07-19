import CoreGraphics
import XCTest
@testable import SoloShot

final class OverlayRendererTests: XCTestCase {
    func testTargetAndIdenticalPersonRectUseExactlyTheSameAspectFillMapping() {
        let task = makeW4ImportedTask()
        let target = task.targetLayout!
        let person = PersonObservation(
            joints: [:],
            boundingBox: target.rect,
            confidence: 0.9,
            observedAt: task.importedAt
        )
        let result = OverlayRenderer.primitives(
            target: target,
            person: person,
            imageSize: CGSize(width: 720, height: 1_280),
            viewSize: CGSize(width: 390, height: 844),
            includeDebugJoints: false
        )
        XCTAssertEqual(result.targetRect, result.personRect)
        XCTAssertEqual(
            result.imageRect,
            CoordinateMapper.aspectFillRect(
                NormalizedRect(x: 0, y: 0, width: 1, height: 1),
                imageSize: CGSize(width: 720, height: 1_280),
                viewSize: CGSize(width: 390, height: 844)
            )
        )
    }
}
