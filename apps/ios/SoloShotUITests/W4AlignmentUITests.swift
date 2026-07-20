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
        app.switches["手机已固定，周围安全"].tap()
        app.buttons["开始实时陪拍"].tap()
        XCTAssertTrue(app.staticTexts["演示陪拍"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["构图已经对上了"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["准备动作"].exists)
        XCTAssertTrue(app.buttons["准备动作"].isEnabled)
    }

    func testManualFallbackRequiresConfirmationAndIsLabeledUnverified() {
        let app = launch(scenario: "manual")
        app.buttons["开始现场陪拍"].tap()
        app.switches["手机已固定，周围安全"].tap()
        app.buttons["开始实时陪拍"].tap()
        XCTAssertTrue(app.buttons["我已就位"].waitForExistence(timeout: 8))
        app.buttons["我已就位"].tap()
        XCTAssertTrue(app.alerts["这次改用手动确认？"].exists)
        app.alerts.buttons["继续使用手动确认"].tap()
        XCTAssertTrue(app.staticTexts["这是手动确认，SoloShot 尚未验证构图与动作。"].waitForExistence(timeout: 3))
    }

    func testFixturePermissionFailureHasRecoveryPath() {
        let app = launch(denyPermission: true)
        app.buttons["开始现场陪拍"].tap()
        app.switches["手机已固定，周围安全"].tap()
        app.buttons["开始实时陪拍"].tap()
        XCTAssertTrue(app.staticTexts["相机还没准备好"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["返回准备"].exists)
    }
}
