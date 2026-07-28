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
}
