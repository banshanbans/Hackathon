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

    private func alignAndOpenCapture(_ app: XCUIApplication) {
        app.buttons["开始现场陪拍"].tap()
        if app.switches["手机已固定，脚下环境安全"].value as? String != "1" {
            app.switches["手机已固定，脚下环境安全"].tap()
        }
        app.buttons["进入实时对齐"].tap()
        XCTAssertTrue(app.staticTexts["构图已就位"].waitForExistence(timeout: 8))
        app.buttons["准备动作并拍摄"].tap()
        app.buttons["就位后自动倒计时"].tap()
    }

    func testPhotoRoundOneCoachingThenRoundTwoFinalResult() {
        let app = launch()
        alignAndOpenCapture(app)
        XCTAssertTrue(app.staticTexts["Fixture 本地采集"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["选择一张候选帧"].waitForExistence(timeout: 8))
        app.buttons["选择本地推荐"].tap()
        XCTAssertTrue(app.staticTexts["确认上传所选照片"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["真实照片将关联 Fixture 固定演示评分，不会调用 Ark，也不代表 AI 已验证改善。"].exists)
        app.buttons["同意并上传所选 JPEG"].tap()
        XCTAssertTrue(app.staticTexts["只修正一个问题"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["向右移动半步"].exists)

        app.buttons["开始第二轮"].tap()
        app.buttons["进入实时对齐"].tap()
        XCTAssertTrue(app.staticTexts["构图已就位"].waitForExistence(timeout: 8))
        app.buttons["准备动作并拍摄"].tap()
        app.buttons["就位后自动倒计时"].tap()
        XCTAssertTrue(app.staticTexts["选择一张候选帧"].waitForExistence(timeout: 8))
        app.buttons["选择本地推荐"].tap()
        XCTAssertTrue(app.staticTexts["候选帧已安全保存在本机"].waitForExistence(timeout: 3))
        app.buttons["继续上传与评价"].tap()
        XCTAssertTrue(app.staticTexts["两轮结果"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["照片为本次真实/本地采集；评分为 Fixture 固定演示数据，不是模型对这些照片的分析。"].exists)
    }

    func testShortVideoFailureOffersExplicitPhotoFallback() {
        let app = launch(extraArguments: ["-W5FixtureShortVideo", "-W5FixtureVideoFailure"])
        alignAndOpenCapture(app)
        XCTAssertTrue(app.staticTexts["本轮采集未完成"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.buttons["切换照片降级"].exists)
        app.buttons["切换照片降级"].tap()
        XCTAssertTrue(app.staticTexts["照片降级（三张连拍）"].waitForExistence(timeout: 3))
    }

    func testSelectedFrameSurvivesTerminationAndColdStartResumesEvaluation() {
        let app = launch()
        alignAndOpenCapture(app)
        XCTAssertTrue(app.staticTexts["选择一张候选帧"].waitForExistence(timeout: 8))
        app.buttons["选择本地推荐"].tap()
        XCTAssertTrue(app.staticTexts["确认上传所选照片"].waitForExistence(timeout: 3))
        app.terminate()

        let resumed = XCUIApplication()
        resumed.launchArguments = ["-W5FixtureNetwork"]
        resumed.launch()
        XCTAssertTrue(resumed.staticTexts["只修正一个问题"].waitForExistence(timeout: 6))
        XCTAssertTrue(resumed.staticTexts["向右移动半步"].exists)
    }
}
