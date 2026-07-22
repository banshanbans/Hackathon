import XCTest

@MainActor
final class W4AlignmentUITests: XCTestCase {
    private func launch(
        scenario: String = "ready",
        denyPermission: Bool = false,
        referenceFailure: Bool = false,
        handoffDiscovery: Bool = false
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-W4SeedTask",
            "-W4FixtureCamera",
            "-W4FixtureScenario", scenario,
        ]
        if denyPermission {
            app.launchArguments.append("-W4FixturePermissionDenied")
        }
        if referenceFailure {
            app.launchArguments.append("-W4FixtureReferenceFailure")
        }
        if handoffDiscovery {
            app.launchArguments.append("-W4FixtureHandoffDiscovery")
        }
        app.launch()
        return app
    }

    private func countdownElement(_ app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(identifier: "auto-countdown").firstMatch
    }

    func testFixtureSequenceAutomaticallyStartsCountdownAtEightyPercent() {
        let app = launch()
        app.buttons["开始现场陪拍"].tap()
        app.switches["手机已固定，周围安全"].tap()
        app.buttons["开始实时陪拍"].tap()
        XCTAssertTrue(app.staticTexts["演示陪拍"].waitForExistence(timeout: 3))
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '轮廓接近度'")).firstMatch
                .waitForExistence(timeout: 3)
        )
        XCTAssertTrue(countdownElement(app).waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["三张照片连拍"].exists)
        XCTAssertFalse(app.buttons["准备动作"].exists)
    }

    func testPresetReferenceIsBundledAndHomeListsSavedHandoff() {
        let app = launch()
        XCTAssertTrue(app.images["preset-reference-image"].waitForExistence(timeout: 3))

        app.buttons["返回首页"].tap()
        XCTAssertTrue(app.staticTexts["本机已接力任务"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.textFields["六位任务码"].exists)
        XCTAssertTrue(app.buttons["继续任务 294816"].exists)

        app.buttons["继续任务 294816"].tap()
        XCTAssertTrue(app.staticTexts["你的 ShotPlan 已到达"].waitForExistence(timeout: 3))
    }

    func testHomeListsServerUnclaimedHandoffsAsOneTapActions() {
        let app = launch(handoffDiscovery: true)
        app.buttons["返回首页"].tap()

        XCTAssertTrue(app.staticTexts["等待认领"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["一键认领任务 731204"].exists)
        XCTAssertTrue(app.buttons["刷新现场任务"].exists)
    }

    func testAlignmentFlowHasHomeEntryAndReturnsToTaskList() {
        let app = launch(scenario: "manual")
        app.buttons["开始现场陪拍"].tap()
        app.switches["手机已固定，周围安全"].tap()
        app.buttons["开始实时陪拍"].tap()
        XCTAssertTrue(app.staticTexts["演示陪拍"].waitForExistence(timeout: 3))

        app.buttons["返回首页"].tap()
        XCTAssertTrue(app.staticTexts["本机已接力任务"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["继续任务 294816"].exists)
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
        XCTAssertTrue(app.staticTexts["手动就位 · 未经智能验证"].waitForExistence(timeout: 3))
        XCTAssertTrue(countdownElement(app).exists)
    }

    func testCountdownCancelsBelowSeventyPercentAndCanRetrigger() {
        let app = launch(scenario: "auto_cancel")
        app.buttons["开始现场陪拍"].tap()
        app.switches["手机已固定，周围安全"].tap()
        app.buttons["开始实时陪拍"].tap()
        XCTAssertTrue(countdownElement(app).waitForExistence(timeout: 8))
        let selectionTitle = app.staticTexts["这一拍，哪一刻最像你？"]
        XCTAssertFalse(selectionTitle.waitForExistence(timeout: 4))
        XCTAssertTrue(selectionTitle.waitForExistence(timeout: 10))
    }

    func testFixturePermissionFailureHasRecoveryPath() {
        let app = launch(denyPermission: true)
        app.buttons["开始现场陪拍"].tap()
        app.switches["手机已固定，周围安全"].tap()
        app.buttons["开始实时陪拍"].tap()
        XCTAssertTrue(app.staticTexts["相机还没准备好"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["返回准备"].exists)
    }

    func testMultiplePeopleAndMissingLiveSilhouetteExposeHonestSoftScoreStates() {
        var app = launch(scenario: "multiple")
        app.buttons["开始现场陪拍"].tap()
        app.switches["手机已固定，周围安全"].tap()
        app.buttons["开始实时陪拍"].tap()
        XCTAssertTrue(app.staticTexts["检测到多人，轮廓比对已暂停"].waitForExistence(timeout: 3))

        app.terminate()
        app = launch(scenario: "silhouette_lost")
        app.buttons["开始现场陪拍"].tap()
        app.switches["手机已固定，周围安全"].tap()
        app.buttons["开始实时陪拍"].tap()
        XCTAssertTrue(app.staticTexts["正在提取实时人物轮廓"].waitForExistence(timeout: 3))
    }

    func testReferenceFailureFallsBackToCompositionAndCriticalPressurePausesVision() {
        var app = launch(referenceFailure: true)
        app.buttons["开始现场陪拍"].tap()
        app.switches["手机已固定，周围安全"].tap()
        app.buttons["开始实时陪拍"].tap()
        XCTAssertTrue(app.staticTexts["参考轮廓不可用，使用构图辅助"].waitForExistence(timeout: 3))

        app.terminate()
        app = launch(scenario: "critical")
        app.buttons["开始现场陪拍"].tap()
        app.switches["手机已固定，周围安全"].tap()
        app.buttons["开始实时陪拍"].tap()
        XCTAssertTrue(app.staticTexts["设备压力过高，实时轮廓已暂停"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["我已就位"].exists)
    }
}
