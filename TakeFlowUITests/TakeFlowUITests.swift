import XCTest

final class TakeFlowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchShowsMinimalHome() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.staticTexts["home.title"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["home.status"].exists)
    }
}
