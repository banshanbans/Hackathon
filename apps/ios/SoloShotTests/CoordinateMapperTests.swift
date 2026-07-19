import CoreGraphics
import XCTest
@testable import SoloShot

final class CoordinateMapperTests: XCTestCase {
    func testVisionOriginAndRotationsMapToTopLeftCoordinates() {
        let point = NormalizedPoint(x: 0.2, y: 0.7)
        let unrotated = CoordinateMapper.visionPointToTopLeft(point)
        XCTAssertEqual(unrotated.x, 0.2, accuracy: 0.000_001)
        XCTAssertEqual(unrotated.y, 0.3, accuracy: 0.000_001)
        let right = CoordinateMapper.visionPointToTopLeft(point, rotation: .degrees90)
        XCTAssertEqual(right.x, 0.7, accuracy: 0.000_001)
        XCTAssertEqual(right.y, 0.2, accuracy: 0.000_001)
        let upsideDown = CoordinateMapper.visionPointToTopLeft(point, rotation: .degrees180)
        XCTAssertEqual(upsideDown.x, 0.8, accuracy: 0.000_001)
        XCTAssertEqual(upsideDown.y, 0.7, accuracy: 0.000_001)
    }

    func testAspectFillUsesTheSameCropForPointsAndRects() {
        let imageSize = CGSize(width: 1_920, height: 1_080)
        let viewSize = CGSize(width: 390, height: 844)
        let full = CoordinateMapper.aspectFillRect(
            NormalizedRect(x: 0, y: 0, width: 1, height: 1),
            imageSize: imageSize,
            viewSize: viewSize
        )
        let center = CoordinateMapper.aspectFillPoint(
            NormalizedPoint(x: 0.5, y: 0.5),
            imageSize: imageSize,
            viewSize: viewSize
        )
        XCTAssertEqual(full.midX, viewSize.width / 2, accuracy: 0.001)
        XCTAssertEqual(full.midY, viewSize.height / 2, accuracy: 0.001)
        XCTAssertEqual(center.x, full.midX, accuracy: 0.001)
        XCTAssertEqual(center.y, full.midY, accuracy: 0.001)
        XCTAssertLessThan(full.minX, 0)
        XCTAssertEqual(full.height, viewSize.height, accuracy: 0.001)
    }
}
