import XCTest

@MainActor
final class W5CaptureUITests: XCTestCase {
    private func launch(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-W4SeedTask",
            "-W4FixtureCamera",
            "-W4FixtureScenario", "ready",
            "-W5FixtureNetwork",
        ] + extraArguments
        app.launch()
        return app
    }

    private func countdownElement(_ app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(identifier: "auto-countdown").firstMatch
    }

    private func alignAndOpenCapture(_ app: XCUIApplication) {
        app.buttons["开始现场陪拍"].tap()
        if app.switches["手机已固定，周围安全"].value as? String != "1" {
            app.switches["手机已固定，周围安全"].tap()
        }
        app.buttons["开始实时陪拍"].tap()
        XCTAssertTrue(countdownElement(app).waitForExistence(timeout: 8))
    }

    func testPhotoRoundOneCoachingThenRoundTwoFinalResult() {
        let app = launch()
        alignAndOpenCapture(app)
        XCTAssertTrue(app.staticTexts["演示拍摄"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["这一拍，哪一刻最像你？"].waitForExistence(timeout: 8))
        app.buttons["就选这一张"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["只上传你选中的这一张"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["演示模式 · 照片不会交给 AI 判断，结果来自预设样例"].exists)
        app.buttons["上传这张照片并查看演示结果"].tap()
        XCTAssertTrue(app.staticTexts["下一拍，只改这一点"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["参考"].exists)
        XCTAssertTrue(app.staticTexts["第一拍"].exists)
        XCTAssertTrue(app.progressIndicators["round-one-readiness"].exists)
        XCTAssertTrue(app.staticTexts["向右移动半步"].exists)

        app.buttons["带着建议再拍一次"].tap()
        app.buttons["开始实时陪拍"].tap()
        XCTAssertTrue(countdownElement(app).waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["这一拍，哪一刻最像你？"].waitForExistence(timeout: 10))
        app.buttons["就选这一张"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["这一张已留在本机"].waitForExistence(timeout: 3))
        app.buttons["继续复盘"].tap()
        XCTAssertTrue(app.staticTexts["你拍到了想要的画面"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.segmentedControls["final-comparison-picker"].exists)
        XCTAssertTrue(app.buttons["参考"].exists)
        XCTAssertTrue(app.buttons["第一拍"].exists)
        XCTAssertTrue(app.buttons["调整后"].exists)
        XCTAssertTrue(app.staticTexts["照片来自本次拍摄；作品就绪度为演示参考，不代表 AI 对照片的判断。"].exists)
    }

    func testShortVideoFailureOffersExplicitPhotoFallback() {
        let app = launch(extraArguments: ["-W5FixtureShortVideo", "-W5FixtureVideoFailure"])
        alignAndOpenCapture(app)
        XCTAssertTrue(app.staticTexts["这一拍没有保存下来"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.buttons["改用三张连拍"].exists)
        app.buttons["改用三张连拍"].tap()
        XCTAssertTrue(app.staticTexts["照片降级 · 三张连拍"].waitForExistence(timeout: 8))
    }

    func testSelectedFrameSurvivesTerminationAndColdStartResumesEvaluation() {
        let app = launch()
        alignAndOpenCapture(app)
        XCTAssertTrue(app.staticTexts["这一拍，哪一刻最像你？"].waitForExistence(timeout: 8))
        app.buttons["就选这一张"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["只上传你选中的这一张"].waitForExistence(timeout: 3))
        app.terminate()

        let resumed = XCUIApplication()
        resumed.launchArguments = ["-W5FixtureNetwork"]
        resumed.launch()
        XCTAssertTrue(resumed.staticTexts["下一拍，只改这一点"].waitForExistence(timeout: 6))
        XCTAssertTrue(resumed.staticTexts["向右移动半步"].exists)
    }
}
