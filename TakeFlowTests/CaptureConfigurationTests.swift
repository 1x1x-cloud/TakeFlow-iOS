import XCTest
@testable import TakeFlow

final class CaptureConfigurationTests: XCTestCase {
    func testDefault1080pPrefersH264AtThirtyFramesPerSecond() {
        let selected = CaptureFormatSelector.select(
            preferredResolution: .fullHD1080p,
            supportedResolutions: [.fullHD1080p, .ultraHD4K],
            availableCodecs: [.h264, .hevc]
        )

        XCTAssertEqual(
            selected,
            CaptureFormatOption(
                resolution: .fullHD1080p,
                framesPerSecond: 30,
                codec: .h264
            )
        )
    }

    func test4KPrefersHEVCWhenActuallySupported() {
        let selected = CaptureFormatSelector.select(
            preferredResolution: .ultraHD4K,
            supportedResolutions: [.fullHD1080p, .ultraHD4K],
            availableCodecs: [.h264, .hevc]
        )

        XCTAssertEqual(selected?.resolution, .ultraHD4K)
        XCTAssertEqual(selected?.codec, .hevc)
        XCTAssertEqual(selected?.framesPerSecond, 30)
    }

    func testUnsupported4KFallsBackTo1080p() {
        let selected = CaptureFormatSelector.select(
            preferredResolution: .ultraHD4K,
            supportedResolutions: [.fullHD1080p],
            availableCodecs: [.h264]
        )

        XCTAssertEqual(selected?.resolution, .fullHD1080p)
        XCTAssertEqual(selected?.codec, .h264)
    }

    func testUnavailablePreferredCodecFallsBackSafely() {
        let selected1080 = CaptureFormatSelector.select(
            preferredResolution: .fullHD1080p,
            supportedResolutions: [.fullHD1080p],
            availableCodecs: [.hevc]
        )
        let selected4K = CaptureFormatSelector.select(
            preferredResolution: .ultraHD4K,
            supportedResolutions: [.ultraHD4K],
            availableCodecs: [.h264]
        )

        XCTAssertEqual(selected1080?.codec, .hevc)
        XCTAssertEqual(selected4K?.codec, .h264)
    }

    func testNoSupportedCodecRejectsConfiguration() {
        XCTAssertNil(
            CaptureFormatSelector.select(
                preferredResolution: .fullHD1080p,
                supportedResolutions: [.fullHD1080p],
                availableCodecs: []
            )
        )
    }

    func testNoSupportedResolutionRejectsConfiguration() {
        XCTAssertNil(
            CaptureFormatSelector.select(
                preferredResolution: .ultraHD4K,
                supportedResolutions: [],
                availableCodecs: [.h264, .hevc]
            )
        )
    }

    func testFrontPreviewMirrorDoesNotImplyOutputMirror() {
        let configuration = CaptureConfiguration(
            position: .front,
            format: CaptureFormatOption(
                resolution: .fullHD1080p,
                framesPerSecond: 30,
                codec: .h264
            ),
            previewMirrored: true,
            outputMirrored: false
        )

        XCTAssertTrue(configuration.previewMirrored)
        XCTAssertFalse(configuration.outputMirrored)
    }

    func testBackPreviewAndOutputAreNotMirrored() {
        let configuration = CaptureConfiguration(
            position: .back,
            format: CaptureFormatOption(
                resolution: .fullHD1080p,
                framesPerSecond: 30,
                codec: .h264
            ),
            previewMirrored: false,
            outputMirrored: false
        )

        XCTAssertFalse(configuration.previewMirrored)
        XCTAssertFalse(configuration.outputMirrored)
    }

    func testFocusPointIsClampedToCaptureCoordinateSpace() {
        let point = NormalizedCapturePoint(x: -0.3, y: 1.8)

        XCTAssertEqual(point, NormalizedCapturePoint(x: 0, y: 1))
    }

    func testAudioRouteDescribesBluetoothAvailability() {
        let route = AudioInputRoute(
            name: "Bluetooth HFP",
            isBluetooth: true,
            isAvailable: true
        )

        XCTAssertTrue(route.isBluetooth)
        XCTAssertTrue(route.isAvailable)
    }

    func testNoSixtyFramesPerSecondOptionCanBeConstructedBySelector() {
        for resolution in VideoResolution.allCases {
            let selected = CaptureFormatSelector.select(
                preferredResolution: resolution,
                supportedResolutions: Set(VideoResolution.allCases),
                availableCodecs: [.h264, .hevc]
            )
            XCTAssertEqual(selected?.framesPerSecond, 30)
        }
    }
}
