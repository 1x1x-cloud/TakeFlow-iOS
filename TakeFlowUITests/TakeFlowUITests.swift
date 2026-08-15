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
    func testMaximumAccessibilityTextScriptEditorAndLibraryRemainReachable()
        throws
    {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
            + maximumAccessibilityTextArguments
        app.launch()

        let addButton = app.buttons["script.empty.add"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        XCTAssertTrue(addButton.isHittable)
        addButton.tap()

        let editorScroll = app.descendants(matching: .any)[
            "editor.scrollView"
        ]
        XCTAssertTrue(editorScroll.waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["editor.title"].isHittable)
        XCTAssertTrue(app.textViews["editor.content"].isHittable)

        let readPosition = app.descendants(matching: .any)[
            "editor.readPosition"
        ]
        for _ in 0..<4 where !readPosition.isHittable {
            editorScroll.swipeUp()
        }
        XCTAssertTrue(readPosition.exists)
        XCTAssertTrue(readPosition.isHittable)

        let back = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(back.isHittable)
        back.tap()

        let scriptRow = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "script.row."
            )
        ).firstMatch
        XCTAssertTrue(scriptRow.waitForExistence(timeout: 5))
        XCTAssertTrue(scriptRow.isHittable)
        XCTAssertTrue(teleprompterOpenButton(in: app).isHittable)
        XCTAssertTrue(captureOpenButton(in: app).isHittable)
        XCTAssertTrue(app.buttons["script.add"].isHittable)
    }

    @MainActor
    func testMaximumAccessibilityTextDeleteCancellationKeepsTargetScript()
        throws
    {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
            + maximumAccessibilityTextArguments
        app.launch()
        createBlankScriptAndReturnToLibrary(app: app)

        let row = firstScriptRow(in: app)
        let delete = firstScriptDeleteButton(in: app)
        assertExistsAndHittable([row, delete])
        XCTAssertGreaterThanOrEqual(delete.frame.width, 44)
        XCTAssertGreaterThanOrEqual(delete.frame.height, 44)

        delete.tap()
        let confirmation = app.descendants(matching: .any)[
            "script.deleteConfirmation"
        ]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        let cancel = app.buttons["script.delete.cancel"]
        let confirm = app.buttons["script.delete.confirm"]
        assertExistsAndHittable([cancel, confirm])
        XCTAssertEqual(cancel.label, "取消删除稿件")
        XCTAssertEqual(confirm.label, "确认删除稿件")

        cancel.tap()
        XCTAssertTrue(confirmation.waitForNonExistence(timeout: 5))
        XCTAssertTrue(row.waitForExistence(timeout: 5))
    }

    @MainActor
    func testMaximumAccessibilityTextConfirmedDeleteStaysDeletedAfterRelaunch()
        throws
    {
        let app = XCUIApplication()
        let storeIdentifier = UUID().uuidString
        app.launchArguments = [
            "-ui-testing-persistent-store=\(storeIdentifier)"
        ] + maximumAccessibilityTextArguments
        app.launch()
        createBlankScriptAndReturnToLibrary(app: app)

        let row = firstScriptRow(in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        firstScriptDeleteButton(in: app).tap()
        let confirm = app.buttons["script.delete.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertTrue(confirm.isHittable)
        confirm.tap()

        XCTAssertTrue(row.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["script.undo"].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()

        XCTAssertFalse(firstScriptRow(in: app).waitForExistence(timeout: 2))
        XCTAssertTrue(
            app.staticTexts["script.empty.title"].waitForExistence(timeout: 5)
        )
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

        let confirmation = app.descendants(matching: .any)[
            "script.deleteConfirmation"
        ]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        let confirmDelete = app.buttons["script.delete.confirm"]
        XCTAssertTrue(confirmDelete.isHittable)
        confirmDelete.tap()

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
    func testMaximumAccessibilityTextTeleprompterControlsSurviveRotation()
        throws
    {
        let device = XCUIDevice.shared
        device.orientation = .portrait
        defer {
            device.orientation = .portrait
        }

        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
            + maximumAccessibilityTextArguments
        app.launch()
        createScriptAndOpenTeleprompter(
            app: app,
            content: String(
                repeating: "最大辅助字体提词器旋转测试。\n",
                count: 30
            )
        )

        let close = app.buttons["teleprompter.close"]
        let settings = app.buttons["teleprompter.settings"]
        let primary = app.buttons["teleprompter.primary"]
        let restart = app.buttons["teleprompter.restart"]
        assertExistsAndHittable([close, settings, primary, restart])

        primary.tap()
        waitForTeleprompterState(app, containing: "正在滚动", timeout: 6)
        XCTAssertEqual(primary.label, "暂停")
        XCTAssertTrue(primary.isHittable)
        primary.tap()
        waitForTeleprompterState(app, containing: "已暂停", timeout: 2)

        device.orientation = .landscapeLeft
        assertExistsAndHittable([close, settings, primary, restart])

        device.orientation = .portrait
        assertExistsAndHittable([close, settings, primary, restart])
        close.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["teleprompter.screen"]
                .waitForNonExistence(timeout: 5)
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
            // 保证一次滑动仍位于正文中段，避免把“到达结尾”误判为
            // “拖动后未继续”。这不会放宽恢复滚动的验收条件。
            content: String(repeating: "用户拖动后继续滚动。\n", count: 100)
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
    func testCaptureAllowedReadyCountdownRecordStopAndLocalPreview()
        throws
    {
        let app = launchCaptureApp()
        createScriptAndOpenCapture(
            app: app,
            content: String(repeating: "摄像提词完整流程。\n", count: 30)
        )
        waitForCaptureState(app, containing: "预览已就绪", timeout: 5)

        let record = app.buttons["capture.record"]
        XCTAssertTrue(record.isEnabled)
        record.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["capture.countdown"]
                .waitForExistence(timeout: 2)
        )
        waitForCaptureState(app, containing: "正在录制", timeout: 6)
        XCTAssertEqual(record.label, "停止录制")
        record.tap()
        waitForCaptureState(app, containing: "录制已完成", timeout: 3)

        let preview = app.buttons["capture.localPreview"]
        XCTAssertTrue(preview.isEnabled)
        preview.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["capture.previewScreen"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertTrue(
            app.buttons["保存到照片"].waitForExistence(timeout: 3)
        )
        XCTAssertTrue(app.buttons["分享视频"].exists)
    }

    @MainActor
    func testMaximumAccessibilityTextCaptureControlsPreviewAndExitSurviveRotation()
        throws
    {
        let device = XCUIDevice.shared
        device.orientation = .portrait
        defer {
            device.orientation = .portrait
        }

        let app = launchCaptureApp(
            extraArguments: ["-ui-testing-capture-skip-countdown"]
                + maximumAccessibilityTextArguments
        )
        createScriptAndOpenCapture(
            app: app,
            content: String(
                repeating: "最大辅助字体摄像提词布局测试。\n",
                count: 80
            )
        )
        waitForCaptureState(app, containing: "预览已就绪", timeout: 5)

        let close = app.buttons["capture.close"]
        let audioRoute = app.buttons["capture.audioRoute"]
        let promptPrimary = app.buttons["capture.teleprompter.primary"]
        let record = app.buttons["capture.record"]
        let preview = app.buttons["capture.localPreview"]
        assertExistsAndHittable([close, audioRoute, promptPrimary, record])
        XCTAssertTrue(preview.exists)
        XCTAssertEqual(audioRoute.label, "音频输入设备")
        XCTAssertTrue(
            (audioRoute.value as? String)?.contains("UI 测试麦克风") == true
        )
        assertAudioRouteControlUsesTopRegion(audioRoute, in: app)

        audioRoute.tap()
        let audioDetails = app.descendants(matching: .any)[
            "capture.audioRouteDetails"
        ]
        XCTAssertTrue(audioDetails.waitForExistence(timeout: 3))
        XCTAssertTrue(
            app.staticTexts["capture.audioRouteName"].label
                .contains("UI 测试麦克风")
        )
        let audioDone = app.buttons["capture.audioRouteDone"]
        XCTAssertTrue(audioDone.isHittable)
        audioDone.tap()
        XCTAssertTrue(audioDetails.waitForNonExistence(timeout: 3))

        promptPrimary.tap()
        waitForCaptureTeleprompterButton(
            promptPrimary,
            label: "暂停",
            timeout: 6
        )
        XCTAssertTrue(promptPrimary.isHittable)
        promptPrimary.tap()
        waitForCaptureTeleprompterButton(
            promptPrimary,
            label: "继续",
            timeout: 2
        )

        record.tap()
        waitForCaptureState(app, containing: "正在录制", timeout: 6)
        XCTAssertEqual(record.label, "停止录制")
        XCTAssertTrue(record.isHittable)
        record.tap()
        waitForCaptureState(app, containing: "录制已完成", timeout: 3)
        XCTAssertTrue(preview.isHittable)

        preview.tap()
        let previewScreen = app.descendants(matching: .any)[
            "capture.previewScreen"
        ]
        XCTAssertTrue(previewScreen.waitForExistence(timeout: 3))
        let previewClose = app.buttons["capture.previewClose"]
        XCTAssertTrue(previewClose.isHittable)
        previewClose.tap()
        XCTAssertTrue(previewScreen.waitForNonExistence(timeout: 3))
        let activePlayerCount = app.descendants(matching: .any)[
            "capture.debugActivePlayerCount"
        ]
        expectation(
            for: NSPredicate(format: "label == %@", "活动播放器 0"),
            evaluatedWith: activePlayerCount
        )
        waitForExpectations(timeout: 2)

        device.orientation = .landscapeLeft
        assertExistsAndHittable(
            [close, audioRoute, promptPrimary, record, preview]
        )
        assertAudioRouteControlUsesTopRegion(audioRoute, in: app)

        device.orientation = .portrait
        assertExistsAndHittable(
            [close, audioRoute, promptPrimary, record, preview]
        )
        assertAudioRouteControlUsesTopRegion(audioRoute, in: app)
        close.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["capture.screen"]
                .waitForNonExistence(timeout: 5)
        )
    }

    @MainActor
    func testLocalPreviewSavePausesAndKeepsSinglePlayer()
        throws
    {
        let app = launchCaptureApp()
        createScriptAndOpenCapture(
            app: app,
            content: String(
                repeating: "本地预览播放器生命周期。\n",
                count: 30
            )
        )
        waitForCaptureState(app, containing: "预览已就绪", timeout: 5)

        let record = app.buttons["capture.record"]
        record.tap()
        waitForCaptureState(app, containing: "正在录制", timeout: 6)
        record.tap()
        waitForCaptureState(app, containing: "录制已完成", timeout: 3)

        let preview = app.buttons["capture.localPreview"]
        preview.tap()
        let previewScreen =
            app.descendants(matching: .any)["capture.previewScreen"]
        XCTAssertTrue(previewScreen.waitForExistence(timeout: 3))

        let playback =
            app.descendants(matching: .any)["capture.previewPlayback"]
        let metrics =
            app.descendants(matching: .any)[
                "capture.previewPlayerMetrics"
            ]
        XCTAssertTrue(playback.waitForExistence(timeout: 3))
        XCTAssertEqual(playback.value as? String, "视频已暂停")
        XCTAssertTrue(metrics.waitForExistence(timeout: 3))
        XCTAssertTrue(metrics.label.contains("活动播放器 1"))
        XCTAssertTrue(metrics.label.contains("已创建 1"))

        playback.tap()
        expectation(
            for: NSPredicate(
                format: "value == %@",
                "视频正在播放"
            ),
            evaluatedWith: playback
        )
        waitForExpectations(timeout: 2)

        let save = app.buttons["capture.savePhotos"]
        save.tap()
        expectation(
            for: NSPredicate(
                format: "value == %@",
                "视频已暂停"
            ),
            evaluatedWith: playback
        )
        waitForExpectations(timeout: 2)
        let photoStatus =
            app.descendants(matching: .any)[
                "capture.photoSaveStatus"
            ]
        expectation(
            for: NSPredicate(
                format: "label == %@",
                "正在保存…"
            ),
            evaluatedWith: photoStatus
        )
        waitForExpectations(timeout: 2)
        XCTAssertFalse(save.isEnabled)
        XCTAssertEqual(save.label, "正在保存…")
        XCTAssertTrue(metrics.label.contains("活动播放器 1"))
        XCTAssertTrue(metrics.label.contains("已创建 1"))

        app.buttons["capture.completePhotoSave"].tap()
        expectation(
            for: NSPredicate(
                format: "label == %@",
                "已保存到照片"
            ),
            evaluatedWith: photoStatus
        )
        waitForExpectations(timeout: 2)
        XCTAssertTrue(previewScreen.exists)
        XCTAssertEqual(playback.value as? String, "视频已暂停")
        XCTAssertEqual(save.label, "已保存")
        XCTAssertFalse(save.isEnabled)
        XCTAssertTrue(metrics.label.contains("活动播放器 1"))
        XCTAssertTrue(metrics.label.contains("已创建 1"))

        playback.tap()
        expectation(
            for: NSPredicate(
                format: "value == %@",
                "视频正在播放"
            ),
            evaluatedWith: playback
        )
        waitForExpectations(timeout: 2)
        XCTAssertTrue(metrics.label.contains("活动播放器 1"))

        app.buttons["capture.previewClose"].tap()
        XCTAssertTrue(previewScreen.waitForNonExistence(timeout: 3))

        preview.tap()
        XCTAssertTrue(previewScreen.waitForExistence(timeout: 3))
        XCTAssertTrue(
            app.descendants(matching: .any)[
                "capture.previewPlayerMetrics"
            ]
                .label.contains("活动播放器 1")
        )
        XCTAssertTrue(
            app.descendants(matching: .any)[
                "capture.previewPlayerMetrics"
            ]
                .label.contains("已创建 2")
        )
        XCTAssertEqual(
            app.descendants(matching: .any)[
                "capture.previewPlayback"
            ].value as? String,
            "视频已暂停"
        )
    }

    @MainActor
    func testCaptureCameraPermissionDenied() throws {
        let app = launchCaptureApp(
            extraArguments: ["-ui-testing-camera-denied"]
        )
        createScriptAndOpenCapture(app: app, content: "摄像头拒绝")

        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(
            alert.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "摄像头权限已关闭")
            ).firstMatch.exists
        )
        XCTAssertTrue(app.buttons["capture.close"].exists)
    }

    @MainActor
    func testCaptureMicrophonePermissionDenied() throws {
        let app = launchCaptureApp(
            extraArguments: ["-ui-testing-microphone-denied"]
        )
        createScriptAndOpenCapture(app: app, content: "麦克风拒绝")

        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(
            alert.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "麦克风权限已关闭")
            ).firstMatch.exists
        )
        XCTAssertFalse(app.buttons["capture.record"].isEnabled)
    }

    @MainActor
    func testCaptureInterruptionRetainsRecoverableSegment() throws {
        let app = launchCaptureApp(
            extraArguments: ["-ui-testing-capture-interrupted"]
        )
        createScriptAndOpenCapture(app: app, content: "中断保留片段")
        waitForCaptureState(app, containing: "预览已就绪", timeout: 5)

        app.buttons["capture.record"].tap()
        waitForCaptureState(app, containing: "正在录制", timeout: 6)

        let notice = app.descendants(matching: .any)["capture.notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        XCTAssertTrue(
            notice.label.contains("发现中断录制片段"),
            "实际提示：\(notice.label)"
        )
        XCTAssertFalse(app.buttons["capture.localPreview"].isEnabled)
        XCTAssertFalse(app.buttons["capture.switchCamera"].isEnabled)

        let recoveryList = app.descendants(matching: .any)[
            "capture.recoveryList"
        ]
        XCTAssertTrue(recoveryList.waitForExistence(timeout: 5))
        let recoveryCards = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "capture.recoveryCard."
            )
        )
        let firstRecoveryCard = recoveryCards.firstMatch
        XCTAssertTrue(firstRecoveryCard.waitForExistence(timeout: 3))
        XCTAssertTrue(firstRecoveryCard.isHittable)
        XCTAssertTrue(
            app.staticTexts["发现中断录制片段"].waitForExistence(timeout: 3)
        )
        let retry = app.buttons["capture.retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 3))
        XCTAssertEqual(retry.label, "重新准备摄像头")
        XCTAssertTrue(retry.isHittable)
        let inspect = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "capture.recoveryInspect."
            )
        ).firstMatch
        XCTAssertTrue(inspect.waitForExistence(timeout: 3))
        XCTAssertTrue(inspect.isHittable)
        inspect.tap()

        let warning = app.descendants(matching: .any)[
            "capture.recoveryWarning"
        ]
        let reviewSheet = app.descendants(matching: .any)[
            "capture.recoveryReviewSheet"
        ]
        XCTAssertTrue(reviewSheet.waitForExistence(timeout: 5))
        XCTAssertTrue(warning.waitForExistence(timeout: 5))
        XCTAssertTrue(warning.label.contains("中断片段，可能不完整"))
        XCTAssertTrue(
            app.descendants(matching: .any)[
                "capture.recoveryAudioStatus"
            ].waitForExistence(timeout: 3)
        )
        XCTAssertTrue(app.buttons["capture.recoveryPlayback"].exists)

        app.buttons["capture.recoveryRetain"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)[
                "capture.recoveryRetained"
            ].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.buttons["capture.recoveryPlayback"].exists)
        XCTAssertTrue(app.buttons["capture.recoveryLater"].exists)

        let playback = app.buttons["capture.recoveryPlayback"]
        playback.tap()
        expectation(
            for: NSPredicate(format: "label == %@", "暂停视频"),
            evaluatedWith: playback
        )
        waitForExpectations(timeout: 2)
        let activePlayerCount = app.descendants(matching: .any)[
            "capture.debugActivePlayerCount"
        ]
        expectation(
            for: NSPredicate(format: "label == %@", "活动播放器 1"),
            evaluatedWith: activePlayerCount
        )
        waitForExpectations(timeout: 2)

        let dragStart = reviewSheet.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)
        )
        let dragEnd = reviewSheet.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92)
        )
        dragStart.press(
            forDuration: 0.05,
            thenDragTo: dragEnd,
            withVelocity: .fast,
            thenHoldForDuration: 0
        )
        XCTAssertTrue(reviewSheet.waitForNonExistence(timeout: 5))
        XCTAssertTrue(warning.waitForNonExistence(timeout: 5))
        expectation(
            for: NSPredicate(format: "label == %@", "活动播放器 0"),
            evaluatedWith: activePlayerCount
        )
        waitForExpectations(timeout: 2)
        XCTAssertTrue(retry.waitForExistence(timeout: 3))
        XCTAssertEqual(retry.label, "重新准备摄像头")
        XCTAssertTrue(recoveryList.exists)
        XCTAssertTrue(
            app.descendants(matching: .any).matching(
                NSPredicate(
                    format: "identifier BEGINSWITH %@",
                    "capture.recoveryCard."
                )
            ).firstMatch.exists
        )
    }

    @MainActor
    func testTwoRecoverableCardsAndRetryRemainHittableInCompactHeight()
        throws
    {
        let device = XCUIDevice.shared
        device.orientation = .portrait
        defer {
            device.orientation = .portrait
        }

        let app = launchCaptureApp(
            extraArguments: [
                "-ui-testing-capture-interruption-ends",
                "-UIPreferredContentSizeCategoryName",
                "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge"
            ]
        )
        createScriptAndOpenCapture(
            app: app,
            content: "紧凑高度双恢复片段"
        )
        waitForCaptureState(app, containing: "预览已就绪", timeout: 5)

        app.buttons["capture.record"].tap()
        waitForCaptureState(app, containing: "正在录制", timeout: 6)
        let triggerInterruption =
            app.buttons["capture.debugTriggerInterruption"]
        XCTAssertTrue(triggerInterruption.waitForExistence(timeout: 3))
        triggerInterruption.tap()
        waitForRecoveryCardCount(1, in: app, timeout: 6)

        let retry = app.buttons["capture.retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 3))
        XCTAssertTrue(retry.isHittable)
        let firstInspect = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "capture.recoveryInspect."
            )
        ).firstMatch
        XCTAssertTrue(firstInspect.waitForExistence(timeout: 3))
        XCTAssertTrue(firstInspect.isHittable)
        retry.tap()
        waitForCaptureState(app, containing: "预览已就绪", timeout: 6)

        app.buttons["capture.record"].tap()
        waitForCaptureState(app, containing: "正在录制", timeout: 6)
        XCTAssertTrue(triggerInterruption.waitForExistence(timeout: 3))
        triggerInterruption.tap()
        waitForRecoveryCardCount(2, in: app, timeout: 6)

        device.orientation = .landscapeLeft
        let recoveryPanel = app.descendants(matching: .any)[
            "capture.recoveryActionPanel"
        ]
        XCTAssertTrue(recoveryPanel.waitForExistence(timeout: 5))

        let recoveryCards = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "capture.recoveryCard."
            )
        )
        XCTAssertEqual(recoveryCards.count, 2)
        XCTAssertTrue(recoveryCards.element(boundBy: 0).exists)
        XCTAssertTrue(recoveryCards.element(boundBy: 0).isHittable)

        let inspectButtons = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "capture.recoveryInspect."
            )
        )
        XCTAssertEqual(inspectButtons.count, 2)
        XCTAssertTrue(inspectButtons.element(boundBy: 0).isHittable)
        XCTAssertTrue(retry.exists)
        XCTAssertEqual(retry.label, "重新准备摄像头")
        XCTAssertTrue(retry.isHittable)

        let recoveryList = app.descendants(matching: .any)[
            "capture.recoveryList"
        ]
        XCTAssertTrue(recoveryList.exists)
        XCTAssertTrue(recoveryList.isHittable)
        recoveryList.swipeLeft()
        XCTAssertTrue(recoveryCards.element(boundBy: 1).exists)
        XCTAssertTrue(recoveryCards.element(boundBy: 1).isHittable)
        XCTAssertTrue(inspectButtons.element(boundBy: 1).isHittable)
        XCTAssertTrue(retry.isHittable)

        device.orientation = .portrait
        recoveryList.swipeRight()
        XCTAssertTrue(recoveryCards.element(boundBy: 0).isHittable)
        XCTAssertTrue(inspectButtons.element(boundBy: 0).isHittable)
        XCTAssertTrue(retry.isHittable)

        inspectButtons.element(boundBy: 0).tap()
        let reviewSheet = app.descendants(matching: .any)[
            "capture.recoveryReviewSheet"
        ]
        XCTAssertTrue(reviewSheet.waitForExistence(timeout: 5))
        let later = app.buttons["capture.recoveryLater"]
        XCTAssertTrue(later.waitForExistence(timeout: 5))
        later.tap()
        XCTAssertTrue(reviewSheet.waitForNonExistence(timeout: 5))
        XCTAssertTrue(retry.waitForExistence(timeout: 3))
        XCTAssertTrue(retry.isHittable)
    }

    @MainActor
    func testRecoverableRecordingDeletionRequiresConfirmation() throws {
        let app = launchCaptureApp(
            extraArguments: ["-ui-testing-capture-interrupted"]
        )
        createScriptAndOpenCapture(app: app, content: "中断片段删除确认")
        waitForCaptureState(app, containing: "预览已就绪", timeout: 5)

        app.buttons["capture.record"].tap()
        waitForCaptureState(app, containing: "正在录制", timeout: 6)
        let inspect = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "capture.recoveryInspect."
            )
        ).firstMatch
        XCTAssertTrue(inspect.waitForExistence(timeout: 5))
        inspect.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)[
                "capture.recoveryWarning"
            ].waitForExistence(timeout: 5)
        )

        app.buttons["capture.recoveryDelete"].tap()
        let confirmation = app.sheets["确认删除中断片段？"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        confirmation.buttons["删除片段"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)[
                "capture.recoveryWarning"
            ].waitForNonExistence(timeout: 5)
        )
    }

    @MainActor
    func testCaptureInterruptionEndOffersExplicitCameraRecovery()
        throws
    {
        let app = launchCaptureApp(
            extraArguments: ["-ui-testing-capture-interruption-ends"]
        )
        createScriptAndOpenCapture(
            app: app,
            content: "中断结束后由用户重新准备摄像头"
        )
        waitForCaptureState(app, containing: "预览已就绪", timeout: 5)
        XCTAssertFalse(
            app.buttons["capture.debugTriggerInterruption"].exists
        )

        app.buttons["capture.record"].tap()
        waitForCaptureState(app, containing: "正在录制", timeout: 6)

        let triggerInterruption =
            app.buttons["capture.debugTriggerInterruption"]
        XCTAssertTrue(triggerInterruption.waitForExistence(timeout: 3))
        triggerInterruption.tap()

        waitForCaptureState(
            app,
            containing: "请重新准备摄像头",
            timeout: 6
        )

        let retry = app.buttons["capture.retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 3))
        XCTAssertEqual(retry.label, "重新准备摄像头")
        XCTAssertFalse(app.buttons["capture.switchCamera"].isEnabled)

        let inspect = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "capture.recoveryInspect."
            )
        ).firstMatch
        XCTAssertTrue(inspect.waitForExistence(timeout: 3))
        inspect.tap()
        let later = app.buttons["capture.recoveryLater"]
        XCTAssertTrue(later.waitForExistence(timeout: 5))
        later.tap()
        XCTAssertTrue(retry.waitForExistence(timeout: 3))
        XCTAssertEqual(retry.label, "重新准备摄像头")
        XCTAssertTrue(inspect.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["capture.switchCamera"].isEnabled)

        retry.tap()

        waitForCaptureState(app, containing: "预览已就绪", timeout: 5)
        XCTAssertTrue(app.buttons["capture.record"].isEnabled)
        XCTAssertTrue(app.buttons["capture.switchCamera"].isEnabled)
        XCTAssertFalse(
            app.buttons["capture.debugTriggerInterruption"].exists
        )
        XCTAssertFalse(app.staticTexts["capture.duration"].exists)
    }

    @MainActor
    func testCaptureLowStorageBlocksStart() throws {
        let app = launchCaptureApp(
            extraArguments: ["-ui-testing-low-storage"]
        )
        createScriptAndOpenCapture(app: app, content: "低存储空间")
        waitForCaptureState(app, containing: "预览已就绪", timeout: 5)

        app.buttons["capture.record"].tap()

        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        XCTAssertTrue(
            alert.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "存储空间不足")
            ).firstMatch.exists
        )
    }

    @MainActor
    func testCaptureCameraSwitchIsDisabledWhileRecording() throws {
        let app = launchCaptureApp()
        createScriptAndOpenCapture(app: app, content: "录制中禁止切换")
        waitForCaptureState(app, containing: "预览已就绪", timeout: 5)

        let switchCamera = app.buttons["capture.switchCamera"]
        XCTAssertTrue(switchCamera.isEnabled)
        app.buttons["capture.record"].tap()
        waitForCaptureState(app, containing: "正在录制", timeout: 6)

        XCTAssertFalse(switchCamera.isEnabled)
        app.buttons["capture.record"].tap()
    }

    @MainActor
    func testCaptureCanRecordSwitchAndRecordAgainWithoutLeaving()
        throws
    {
        let app = launchCaptureApp(
            extraArguments: ["-ui-testing-capture-skip-countdown"]
        )
        createScriptAndOpenCapture(
            app: app,
            content: String(repeating: "连续完成两次录制。\n", count: 30)
        )
        waitForCaptureState(app, containing: "预览已就绪", timeout: 5)

        let record = app.buttons["capture.record"]
        let preview = app.buttons["capture.localPreview"]
        let switchCamera = app.buttons["capture.switchCamera"]
        XCTAssertEqual(
            switchCamera.value as? String,
            "当前为前置摄像头"
        )

        record.tap()
        waitForCaptureState(app, containing: "正在录制", timeout: 6)
        record.tap()
        waitForCaptureState(app, containing: "录制已完成", timeout: 3)

        XCTAssertTrue(preview.isEnabled)
        XCTAssertTrue(switchCamera.isEnabled)
        XCTAssertFalse(
            app.descendants(matching: .any)["capture.previewScreen"].exists
        )

        switchCamera.tap()
        expectation(
            for: NSPredicate(
                format: "value == %@",
                "当前为后置摄像头"
            ),
            evaluatedWith: switchCamera
        )
        waitForExpectations(timeout: 5)
        XCTAssertTrue(record.isEnabled)

        record.tap()
        waitForCaptureState(app, containing: "正在录制", timeout: 6)
        record.tap()
        waitForCaptureState(app, containing: "录制已完成", timeout: 3)

        XCTAssertTrue(preview.isEnabled)
        preview.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["capture.previewScreen"]
                .waitForExistence(timeout: 3)
        )
    }

    @MainActor
    func testCaptureCanExitAndEnterAgain() throws {
        let app = launchCaptureApp()
        createScriptAndOpenCapture(
            app: app,
            content: "重复进入摄像提词"
        )
        waitForCaptureState(app, containing: "预览已就绪", timeout: 5)

        app.buttons["capture.close"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["capture.screen"]
                .waitForNonExistence(timeout: 5)
        )
        let openButton = captureOpenButton(in: app)
        XCTAssertTrue(openButton.waitForExistence(timeout: 5))
        openButton.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["capture.screen"]
                .waitForExistence(timeout: 5)
        )
        waitForCaptureState(app, containing: "预览已就绪", timeout: 5)
        XCTAssertTrue(app.buttons["capture.record"].isEnabled)
    }

    @MainActor
    func testCapturePreparationTimeoutOffersWorkingRetry() throws {
        let app = launchCaptureApp(
            extraArguments: ["-ui-testing-capture-timeout-once"]
        )
        createScriptAndOpenCapture(
            app: app,
            content: "摄像头超时重试"
        )

        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        XCTAssertTrue(
            alert.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "准备超时")
            ).firstMatch.exists
        )
        let retry = alert.buttons["重新尝试"]
        XCTAssertTrue(retry.exists)
        retry.tap()

        waitForCaptureState(app, containing: "预览已就绪", timeout: 5)
        XCTAssertTrue(app.buttons["capture.record"].isEnabled)
    }

    @MainActor
    func testCaptureForegroundDoesNotAutomaticallyResumeRecording()
        throws
    {
        let app = launchCaptureApp()
        createScriptAndOpenCapture(app: app, content: "前后台中断")
        waitForCaptureState(app, containing: "预览已就绪", timeout: 5)
        app.buttons["capture.record"].tap()
        waitForCaptureState(app, containing: "正在录制", timeout: 6)

        XCUIDevice.shared.press(.home)
        app.activate()

        waitForCaptureState(
            app,
            containing: "请重新准备摄像头",
            timeout: 5
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["capture.state"].label
                .contains("正在录制")
        )
        XCTAssertFalse(app.buttons["capture.record"].isEnabled)
        XCTAssertFalse(app.buttons["capture.switchCamera"].isEnabled)
        XCTAssertTrue(app.buttons["capture.retry"].exists)
    }

    @MainActor
    func testCaptureOverlayTeleprompterStartPauseAndDragStillWorks()
        throws
    {
        let app = launchCaptureApp()
        createScriptAndOpenCapture(
            app: app,
            content: String(repeating: "摄像层上的长稿提词。\n", count: 100)
        )
        let primary = app.buttons["capture.teleprompter.primary"]
        XCTAssertTrue(primary.waitForExistence(timeout: 5))
        primary.tap()
        waitForCaptureTeleprompterButton(
            primary,
            label: "暂停",
            timeout: 6
        )
        primary.tap()
        waitForCaptureTeleprompterButton(
            primary,
            label: "继续",
            timeout: 2
        )

        let text = app.descendants(matching: .any)[
            "capture.teleprompter.text"
        ]
        XCTAssertTrue(text.waitForExistence(timeout: 3))
        text.swipeUp()
        primary.tap()
        waitForCaptureTeleprompterToResumeOrFinish(
            primary,
            timeout: 2
        )
    }

    @MainActor
    func testCapturePromptTapFocusesAndDeviceLockIsTruthful()
        throws
    {
        let app = launchCaptureApp()
        createScriptAndOpenCapture(
            app: app,
            content: String(repeating: "点击提词区域也应对焦。\n", count: 80)
        )
        waitForCaptureState(app, containing: "预览已就绪", timeout: 5)

        let prompt = app.descendants(matching: .any)[
            "capture.teleprompter.text"
        ]
        XCTAssertTrue(prompt.waitForExistence(timeout: 3))
        prompt.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
            .tap()

        let notice = app.descendants(matching: .any)[
            "capture.focusNotice"
        ]
        expectation(
            for: NSPredicate(
                format: "label CONTAINS %@",
                "已设置"
            ),
            evaluatedWith: notice
        )
        waitForExpectations(timeout: 2)

        let lock = app.buttons["capture.focusLock"]
        XCTAssertTrue(lock.isEnabled)
        lock.tap()
        expectation(
            for: NSPredicate(
                format: "value == %@",
                "焦点和曝光已锁定"
            ),
            evaluatedWith: lock
        )
        waitForExpectations(timeout: 2)

        lock.tap()
        expectation(
            for: NSPredicate(
                format: "value == %@",
                "焦点和曝光自动调整"
            ),
            evaluatedWith: lock
        )
        waitForExpectations(timeout: 2)
    }

    @MainActor
    func testCaptureCameraSwitchClearsOldFocusLockFeedback()
        throws
    {
        let app = launchCaptureApp()
        createScriptAndOpenCapture(
            app: app,
            content: String(repeating: "切换镜头清理旧对焦状态。\n", count: 40)
        )
        waitForCaptureState(app, containing: "预览已就绪", timeout: 5)

        let prompt = app.descendants(matching: .any)[
            "capture.teleprompter.text"
        ]
        prompt.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)
        ).tap()
        let focusNotice = app.descendants(matching: .any)[
            "capture.focusNotice"
        ]
        XCTAssertTrue(focusNotice.waitForExistence(timeout: 2))

        let lock = app.buttons["capture.focusLock"]
        lock.tap()
        expectation(
            for: NSPredicate(
                format: "value == %@",
                "焦点和曝光已锁定"
            ),
            evaluatedWith: lock
        )
        waitForExpectations(timeout: 2)
        XCTAssertEqual(lock.label, "解锁焦点和曝光")

        app.buttons["capture.switchCamera"].tap()
        XCTAssertFalse(focusNotice.waitForExistence(timeout: 0.5))
        waitForCaptureState(app, containing: "预览已就绪", timeout: 5)

        XCTAssertEqual(lock.label, "锁定焦点和曝光")
        XCTAssertEqual(lock.value as? String, "焦点和曝光自动调整")
        XCTAssertFalse(focusNotice.exists)
        XCTAssertTrue(lock.isEnabled)
    }

    @MainActor
    func testCapturePromptDragAndControlTapDoNotTriggerFocus()
        throws
    {
        let app = launchCaptureApp()
        createScriptAndOpenCapture(
            app: app,
            content: String(repeating: "拖动提词不应触发对焦。\n", count: 100)
        )
        waitForCaptureState(app, containing: "预览已就绪", timeout: 5)

        let prompt = app.descendants(matching: .any)[
            "capture.teleprompter.text"
        ]
        XCTAssertTrue(prompt.waitForExistence(timeout: 3))
        let start = prompt.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)
        )
        let end = prompt.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)
        )
        start.press(
            forDuration: 0.05,
            thenDragTo: end,
            withVelocity: .fast,
            thenHoldForDuration: 0
        )

        let indicator = app.descendants(matching: .any)[
            "capture.focusIndicator"
        ]
        XCTAssertFalse(indicator.waitForExistence(timeout: 0.4))

        app.buttons["capture.switchCamera"].tap()
        XCTAssertFalse(indicator.waitForExistence(timeout: 0.4))
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
    private func launchCaptureApp(
        extraArguments: [String] = []
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"] + extraArguments
        app.launch()
        return app
    }

    @MainActor
    private func createScriptAndOpenCapture(
        app: XCUIApplication,
        content: String
    ) {
        let addButton = app.buttons["script.empty.add"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.tap()

        let editor = app.textViews["editor.content"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        editor.typeText(content)

        let saveStatus = app.descendants(matching: .any)[
            "editor.saveStatus"
        ]
        expectation(
            for: NSPredicate(format: "label == %@", "已保存"),
            evaluatedWith: saveStatus
        )
        waitForExpectations(timeout: 15)
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let openButton = captureOpenButton(in: app)
        XCTAssertTrue(openButton.waitForExistence(timeout: 5))
        XCTAssertEqual(openButton.label, "摄像提词")
        openButton.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["capture.screen"]
                .waitForExistence(timeout: 5)
        )
    }

    @MainActor
    private func captureOpenButton(
        in app: XCUIApplication
    ) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "capture.open."
            )
        ).firstMatch
    }

    @MainActor
    private func createBlankScriptAndReturnToLibrary(
        app: XCUIApplication
    ) {
        let add = app.buttons["script.empty.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        XCTAssertTrue(
            app.textFields["editor.title"].waitForExistence(timeout: 5)
        )
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(firstScriptRow(in: app).waitForExistence(timeout: 5))
    }

    @MainActor
    private func firstScriptRow(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "script.row."
            )
        ).firstMatch
    }

    @MainActor
    private func firstScriptDeleteButton(
        in app: XCUIApplication
    ) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "script.delete."
            )
        ).firstMatch
    }

    @MainActor
    private func assertAudioRouteControlUsesTopRegion(
        _ audioRoute: XCUIElement,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let screen = app.descendants(matching: .any)["capture.screen"]
        let record = app.buttons["capture.record"]
        let preview = app.buttons["capture.localPreview"]
        XCTAssertTrue(screen.exists, file: file, line: line)
        XCTAssertLessThan(
            audioRoute.frame.midY,
            screen.frame.midY,
            "音频设备入口必须位于画面上半部的配置区",
            file: file,
            line: line
        )
        XCTAssertFalse(
            audioRoute.frame.intersects(record.frame),
            "音频设备入口不得遮挡录制按钮",
            file: file,
            line: line
        )
        if preview.exists {
            XCTAssertFalse(
                audioRoute.frame.intersects(preview.frame),
                "音频设备入口不得遮挡预览入口",
                file: file,
                line: line
            )
        }
        XCTAssertTrue(
            screen.frame.insetBy(dx: -1, dy: -1).contains(audioRoute.frame),
            "音频设备入口必须保持在屏幕安全布局范围内",
            file: file,
            line: line
        )
    }

    @MainActor
    private func waitForCaptureState(
        _ app: XCUIApplication,
        containing text: String,
        timeout: TimeInterval
    ) {
        expectation(
            for: NSPredicate(format: "label CONTAINS %@", text),
            evaluatedWith: app.staticTexts["capture.state"]
        )
        waitForExpectations(timeout: timeout)
    }

    @MainActor
    private func waitForRecoveryCardCount(
        _ expectedCount: Int,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) {
        let cards = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "capture.recoveryCard."
            )
        )
        let predicate = NSPredicate { _, _ in
            cards.count == expectedCount
        }
        let countExpectation = XCTNSPredicateExpectation(
            predicate: predicate,
            object: app
        )
        let result = XCTWaiter.wait(
            for: [countExpectation],
            timeout: timeout
        )
        XCTAssertEqual(
            result,
            .completed,
            "恢复卡片数量未在 \(timeout) 秒内变为 \(expectedCount)，"
                + "实际为 \(cards.count)"
        )
    }

    @MainActor
    private func waitForCaptureTeleprompterButton(
        _ button: XCUIElement,
        label: String,
        timeout: TimeInterval
    ) {
        expectation(
            for: NSPredicate(format: "label == %@", label),
            evaluatedWith: button
        )
        waitForExpectations(timeout: timeout)
    }

    @MainActor
    private func waitForCaptureTeleprompterToResumeOrFinish(
        _ button: XCUIElement,
        timeout: TimeInterval
    ) {
        let predicate = NSPredicate { _, _ in
            let label = button.label
            return label == "暂停" || label == "开始"
        }
        let resumedExpectation = XCTNSPredicateExpectation(
            predicate: predicate,
            object: button
        )
        let result = XCTWaiter.wait(
            for: [resumedExpectation],
            timeout: timeout
        )
        XCTAssertEqual(
            result,
            .completed,
            "拖动后点击继续应进入运行状态；若 XCUITest 等待运行界面空闲期间稿件已滚动至结尾，则允许进入完成状态"
        )
        XCTAssertNotEqual(button.label, "继续")
    }

    @MainActor
    private func waitForTeleprompterState(
        _ app: XCUIApplication,
        containing text: String,
        timeout: TimeInterval
    ) {
        let predicate = NSPredicate { _, _ in
            app.descendants(matching: .any)["teleprompter.state"]
                .label.contains(text)
        }
        let stateExpectation = XCTNSPredicateExpectation(
            predicate: predicate,
            object: app
        )
        let result = XCTWaiter.wait(
            for: [stateExpectation],
            timeout: timeout
        )
        XCTAssertEqual(
            result,
            .completed,
            "提词器状态未在 \(timeout) 秒内包含“\(text)”"
        )
    }

    @MainActor
    private var maximumAccessibilityTextArguments: [String] {
        [
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL"
        ]
    }

    @MainActor
    private func assertExistsAndHittable(
        _ elements: [XCUIElement],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for element in elements {
            XCTAssertTrue(
                element.waitForExistence(timeout: 5),
                "元素不存在：\(element)",
                file: file,
                line: line
            )
            XCTAssertTrue(
                element.isHittable,
                "元素不可点击：\(element)",
                file: file,
                line: line
            )
        }
    }
}
