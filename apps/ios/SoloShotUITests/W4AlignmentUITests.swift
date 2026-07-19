import XCTest

@MainActor
final class W4AlignmentUITests: XCTestCase {
    private func launch(scenario: String = "ready", denyPermission: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-W4SeedTask",
            "-W4FixtureCamera",
            "-W4FixtureScenario", scenario,
        ]
        if denyPermission {
            app.launchArguments.append("-W4FixturePermissionDenied")
        }
        app.launch()
        return app
    }

    func testFixtureSequenceMovesFromSummaryThroughOverlayToReady() {
        let app = launch()
        app.buttons["开始现场陪拍"].tap()
        app.switches["手机已固定，脚下环境安全"].tap()
        app.buttons["进入实时对齐"].tap()
        XCTAssertTrue(app.staticTexts["Fixture 本地对齐"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["构图已就位"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["准备动作并拍摄"].exists)
        XCTAssertTrue(app.buttons["准备动作并拍摄"].isEnabled)
    }

    func testManualFallbackRequiresConfirmationAndIsLabeledUnverified() {
        let app = launch(scenario: "manual")
        app.buttons["开始现场陪拍"].tap()
        app.switches["手机已固定，脚下环境安全"].tap()
        app.buttons["进入实时对齐"].tap()
        XCTAssertTrue(app.buttons["手动已就位"].waitForExistence(timeout: 8))
        app.buttons["手动已就位"].tap()
        XCTAssertTrue(app.alerts["手动确认已就位？"].exists)
        app.alerts.buttons["确认未验证就位"].tap()
        XCTAssertTrue(app.staticTexts["这是手动确认结果，姿势和构图未经 Vision 验证。"].waitForExistence(timeout: 3))
    }

    func testFixturePermissionFailureHasRecoveryPath() {
        let app = launch(denyPermission: true)
        app.buttons["开始现场陪拍"].tap()
        app.switches["手机已固定，脚下环境安全"].tap()
        app.buttons["进入实时对齐"].tap()
        XCTAssertTrue(app.staticTexts["相机暂不可用"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["返回准备页"].exists)
    }
}
