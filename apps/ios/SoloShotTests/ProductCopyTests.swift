import XCTest
@testable import SoloShot

final class ProductCopyTests: XCTestCase {
    func testExecutionModesUseTrustedChineseLabels() {
        XCTAssertEqual(ProductCopy.executionMode("fixture"), "演示模式")
        XCTAssertEqual(ProductCopy.executionMode("live"), "实时分析")
        XCTAssertEqual(ProductCopy.executionMode("fallback"), "稳妥模式")
        XCTAssertEqual(ProductCopy.executionMode("error"), "需要重试")
    }

    func testShotPlanEnumsNeverReachReleaseCopy() {
        XCTAssertEqual(ProductCopy.creationMode("scene_adaptation"), "灵感迁移")
        XCTAssertEqual(ProductCopy.cameraHeight("waist"), "腰部高度")
        XCTAssertEqual(ProductCopy.cameraAngle("level"), "镜头水平")
        XCTAssertEqual(ProductCopy.lens("1x"), "1× 主摄")
        XCTAssertEqual(ProductCopy.round(1), "第一次")
        XCTAssertEqual(ProductCopy.round(2), "调整后")
    }
}
