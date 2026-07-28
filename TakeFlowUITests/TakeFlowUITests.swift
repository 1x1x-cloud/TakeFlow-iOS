import XCTest

final class TakeFlowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchShowsScriptLibrary() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()

        XCTAssertTrue(app.navigationBars["稿件"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts["script.empty.title"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.buttons["script.empty.add"].exists)
    }

    @MainActor
    func testCreateEditAndAutosaveScript() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()

        let addButton = app.buttons["script.empty.add"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.tap()

        let titleField = app.textFields["editor.title"]
        let contentEditor = app.textViews["editor.content"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        XCTAssertTrue(contentEditor.exists)

        titleField.tap()
        titleField.typeText("UI Autosave")
        contentEditor.tap()
        contentEditor.typeText("Offline plain text 123.")

        let saveStatus = app.descendants(matching: .any)["editor.saveStatus"]
        XCTAssertTrue(saveStatus.waitForExistence(timeout: 5))
        let saved = NSPredicate(format: "label == %@", "已保存")
        expectation(for: saved, evaluatedWith: saveStatus)
        waitForExpectations(timeout: 5)

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["UI Autosave"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testDuplicateDeleteConfirmationAndUndo() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()

        let addButton = app.buttons["script.empty.add"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.tap()
        XCTAssertTrue(
            app.textFields["editor.title"].waitForExistence(timeout: 5)
        )
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let originalTitle = app.staticTexts["未命名稿件"]
        XCTAssertTrue(originalTitle.waitForExistence(timeout: 5))
        originalTitle.swipeLeft()
        let duplicateAction = app.buttons["复制"]
        XCTAssertTrue(duplicateAction.waitForExistence(timeout: 5))
        duplicateAction.tap()

        let duplicateTitle = app.staticTexts["未命名稿件 副本"]
        XCTAssertTrue(duplicateTitle.waitForExistence(timeout: 5))
        duplicateTitle.swipeLeft()
        let deleteAction = app.buttons["删除"]
        XCTAssertTrue(deleteAction.waitForExistence(timeout: 5))
        deleteAction.tap()

        let confirmation = app.sheets["删除这份稿件？"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["删除"].tap()

        let undoButton = app.buttons["script.undo"]
        XCTAssertTrue(undoButton.waitForExistence(timeout: 5))
        XCTAssertFalse(duplicateTitle.exists)
        undoButton.tap()
        XCTAssertTrue(duplicateTitle.waitForExistence(timeout: 5))
    }

    @MainActor
    func testSavedScriptSurvivesAppRelaunch() throws {
        let app = XCUIApplication()
        let storeIdentifier = UUID().uuidString
        app.launchArguments = [
            "-ui-testing-persistent-store=\(storeIdentifier)"
        ]
        app.launch()

        let addButton = app.buttons["script.empty.add"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.tap()

        let titleField = app.textFields["editor.title"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        titleField.tap()
        titleField.typeText("Relaunch Recovery")

        let saveStatus = app.descendants(matching: .any)["editor.saveStatus"]
        let saved = NSPredicate(format: "label == %@", "已保存")
        expectation(for: saved, evaluatedWith: saveStatus)
        waitForExpectations(timeout: 5)

        app.terminate()
        app.launch()

        XCTAssertTrue(
            app.staticTexts["Relaunch Recovery"].waitForExistence(timeout: 5)
        )
    }

    @MainActor
    func testOpenTeleprompterShowsAccessibleControlsAndCountdown() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()

        createScriptAndOpenTeleprompter(
            app: app,
            content: "Teleprompter UI launch text."
        )

        XCTAssertTrue(
            app.descendants(matching: .any)["teleprompter.screen"]
                .waitForExistence(timeout: 5)
        )
        let primary = app.buttons["teleprompter.primary"]
        XCTAssertTrue(primary.waitForExistence(timeout: 5))
        XCTAssertEqual(primary.label, "开始")
        XCTAssertEqual(primary.value as? String, "尚未开始")
        XCTAssertTrue(app.buttons["teleprompter.settings"].exists)
        XCTAssertTrue(app.buttons["teleprompter.restart"].exists)

        let promptText = app.descendants(matching: .any)[
            "teleprompter.text"
        ]
        XCTAssertTrue(promptText.exists)
        promptText.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        ).tap()
        let showControls = app.buttons["teleprompter.showControls"]
        XCTAssertTrue(showControls.waitForExistence(timeout: 2))
        showControls.tap()
        XCTAssertTrue(primary.waitForExistence(timeout: 2))

        app.buttons["teleprompter.settings"].tap()
        XCTAssertTrue(
            app.sliders["teleprompter.speed"].waitForExistence(timeout: 2)
        )
        app.buttons["完成"].tap()
        XCTAssertTrue(primary.waitForExistence(timeout: 2))

        primary.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["teleprompter.countdown"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["teleprompter.state"].label
                .contains("倒计时")
        )
    }

    @MainActor
    func testTeleprompterCountdownRunPauseAndResume() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        createScriptAndOpenTeleprompter(
            app: app,
            content: String(
                repeating: "Countdown run pause resume. ",
                count: 20
            )
        )

        let primary = app.buttons["teleprompter.primary"]
        XCTAssertTrue(primary.waitForExistence(timeout: 5))
        primary.tap()
        waitForTeleprompterState(app, containing: "正在滚动", timeout: 6)

        primary.tap()
        waitForTeleprompterState(app, containing: "已暂停", timeout: 2)
        XCTAssertEqual(primary.label, "继续")

        primary.tap()
        waitForTeleprompterState(app, containing: "正在滚动", timeout: 2)
        XCTAssertEqual(primary.label, "暂停")
    }

    @MainActor
    func testTeleprompterContinuesAfterUserDrag() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        createScriptAndOpenTeleprompter(
            app: app,
            content: String(repeating: "用户拖动后继续滚动。\n", count: 20)
        )

        let primary = app.buttons["teleprompter.primary"]
        primary.tap()
        waitForTeleprompterState(app, containing: "正在滚动", timeout: 6)

        let prompt = app.descendants(matching: .any)[
            "teleprompter.text"
        ]
        XCTAssertTrue(prompt.waitForExistence(timeout: 5))
        prompt.swipeUp()
        waitForTeleprompterState(app, containing: "正在滚动", timeout: 3)
        XCTAssertEqual(primary.label, "暂停")
    }

    @MainActor
    func testTeleprompterPreferencesPersistAfterReentry() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        createScriptAndOpenTeleprompter(
            app: app,
            content: String(repeating: "偏好持久化内容。\n", count: 50)
        )

        app.buttons["teleprompter.settings"].tap()
        let fontSlider = app.sliders["teleprompter.fontSize"]
        let speedSlider = app.sliders["teleprompter.speed"]
        let marginSlider = app.sliders["teleprompter.margin"]
        XCTAssertTrue(fontSlider.waitForExistence(timeout: 3))
        fontSlider.adjust(toNormalizedSliderPosition: 0.75)
        speedSlider.adjust(toNormalizedSliderPosition: 0.70)
        let fontValue = String(describing: fontSlider.value)
        let speedValue = String(describing: speedSlider.value)
        for _ in 0..<3 where !marginSlider.exists {
            app.swipeUp()
        }
        XCTAssertTrue(marginSlider.waitForExistence(timeout: 3))
        marginSlider.adjust(toNormalizedSliderPosition: 0.65)
        let marginValue = String(describing: marginSlider.value)
        app.buttons["完成"].tap()
        app.buttons["teleprompter.close"].tap()

        let openButton = teleprompterOpenButton(in: app)
        XCTAssertTrue(openButton.waitForExistence(timeout: 5))
        openButton.tap()
        XCTAssertTrue(
            app.buttons["teleprompter.settings"].waitForExistence(timeout: 5)
        )
        app.buttons["teleprompter.settings"].tap()

        let restoredFont = app.sliders["teleprompter.fontSize"]
        let restoredSpeed = app.sliders["teleprompter.speed"]
        let restoredMargin = app.sliders["teleprompter.margin"]
        XCTAssertTrue(restoredFont.waitForExistence(timeout: 3))
        XCTAssertEqual(String(describing: restoredFont.value), fontValue)
        XCTAssertEqual(String(describing: restoredSpeed.value), speedValue)
        for _ in 0..<3 where !restoredMargin.exists {
            app.swipeUp()
        }
        XCTAssertTrue(restoredMargin.waitForExistence(timeout: 3))
        XCTAssertEqual(String(describing: restoredMargin.value), marginValue)
    }

    @MainActor
    func testEmptyScriptCannotEnterRunningState() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()

        let addButton = app.buttons["script.empty.add"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.tap()
        XCTAssertTrue(
            app.textViews["editor.content"].waitForExistence(timeout: 5)
        )
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let openButton = teleprompterOpenButton(in: app)
        XCTAssertTrue(openButton.waitForExistence(timeout: 5))
        openButton.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["teleprompter.empty"]
                .waitForExistence(timeout: 5)
        )
        let primary = app.buttons["teleprompter.primary"]
        XCTAssertTrue(primary.exists)
        XCTAssertFalse(primary.isEnabled)
        XCTAssertFalse(
            app.descendants(matching: .any)["teleprompter.state"].label
                .contains("正在滚动")
        )
    }

    @MainActor
    private func createScriptAndOpenTeleprompter(
        app: XCUIApplication,
        content: String
    ) {
        let addButton = app.buttons["script.empty.add"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.tap()

        let contentEditor = app.textViews["editor.content"]
        XCTAssertTrue(contentEditor.waitForExistence(timeout: 5))
        contentEditor.tap()
        contentEditor.typeText(content)

        let saveStatus = app.descendants(matching: .any)[
            "editor.saveStatus"
        ]
        let saved = NSPredicate(format: "label == %@", "已保存")
        expectation(for: saved, evaluatedWith: saveStatus)
        waitForExpectations(timeout: 15)
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let openButton = teleprompterOpenButton(in: app)
        XCTAssertTrue(openButton.waitForExistence(timeout: 5))
        XCTAssertEqual(openButton.label, "提词模式")
        openButton.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["teleprompter.screen"]
                .waitForExistence(timeout: 5)
        )
    }

    @MainActor
    private func teleprompterOpenButton(
        in app: XCUIApplication
    ) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "teleprompter.open."
            )
        ).firstMatch
    }

    @MainActor
    private func waitForTeleprompterState(
        _ app: XCUIApplication,
        containing text: String,
        timeout: TimeInterval
    ) {
        let state = app.descendants(matching: .any)["teleprompter.state"]
        let predicate = NSPredicate(
            format: "label CONTAINS %@",
            text
        )
        expectation(for: predicate, evaluatedWith: state)
        waitForExpectations(timeout: timeout)
    }
}
