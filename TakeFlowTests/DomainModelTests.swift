import XCTest
@testable import TakeFlow

final class DomainModelTests: XCTestCase {
    func testBaseModelsCanBeInstantiated() {
        let script = Script(title: "测试稿", content: "你好")
        let project = RecordingProject(scriptID: script.id)
        let segment = RecordingSegment(
            projectID: project.id,
            sequence: 0,
            localFileURL: URL(fileURLWithPath: "/tmp/segment.mov")
        )
        let preferences = UserPreferences()

        XCTAssertEqual(project.scriptID, script.id)
        XCTAssertEqual(segment.projectID, project.id)
        XCTAssertEqual(project.resolution, .fullHD1080p)
        XCTAssertEqual(preferences.defaultResolution, .fullHD1080p)
        XCTAssertFalse(preferences.voiceTrackingEnabled)
    }

    func testAppErrorProvidesUserSafeDescription() {
        XCTAssertEqual(
            AppError.persistenceUnavailable.errorDescription,
            "暂时无法保存或读取内容。"
        )
    }
}
