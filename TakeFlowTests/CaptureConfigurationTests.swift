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

    func testPreviewFocusConversionUsesPreviewLocalCoordinates() {
        var receivedLayerPoint: CGPoint?
        let converted = CapturePreviewPointConverter.convert(
            screenPoint: CGPoint(x: 140, y: 260),
            previewFrameInWindow: CGRect(
                x: 40,
                y: 60,
                width: 200,
                height: 400
            )
        ) { layerPoint in
            receivedLayerPoint = layerPoint
            return CGPoint(
                x: layerPoint.x / 200,
                y: layerPoint.y / 400
            )
        }

        XCTAssertEqual(receivedLayerPoint, CGPoint(x: 100, y: 200))
        XCTAssertEqual(
            converted,
            NormalizedCapturePoint(x: 0.5, y: 0.5)
        )
    }

    func testPreviewLayerConversionContractHandlesCameraTransforms() {
        struct Scenario {
            let name: String
            let layerConversion: (CGPoint) -> CGPoint
            let expected: NormalizedCapturePoint
        }
        let scenarios = [
            Scenario(
                name: "后摄竖屏含aspect-fill裁切",
                layerConversion: { point in
                    CGPoint(
                        x: (point.x + 20) / 240,
                        y: point.y / 400
                    )
                },
                expected: NormalizedCapturePoint(
                    x: 100.0 / 240.0,
                    y: 0.25
                )
            ),
            Scenario(
                name: "前摄镜像",
                layerConversion: { point in
                    CGPoint(
                        x: 1 - point.x / 200,
                        y: point.y / 400
                    )
                },
                expected: NormalizedCapturePoint(x: 0.6, y: 0.25)
            ),
            Scenario(
                name: "充电口朝左横屏",
                layerConversion: { point in
                    CGPoint(
                        x: point.y / 400,
                        y: 1 - point.x / 200
                    )
                },
                expected: NormalizedCapturePoint(x: 0.25, y: 0.6)
            ),
            Scenario(
                name: "充电口朝右横屏",
                layerConversion: { point in
                    CGPoint(
                        x: 1 - point.y / 400,
                        y: point.x / 200
                    )
                },
                expected: NormalizedCapturePoint(x: 0.75, y: 0.4)
            )
        ]

        for scenario in scenarios {
            let converted = CapturePreviewPointConverter.convert(
                screenPoint: CGPoint(x: 90, y: 130),
                previewFrameInWindow: CGRect(
                    x: 10,
                    y: 30,
                    width: 200,
                    height: 400
                ),
                devicePointForLayerPoint: scenario.layerConversion
            )
            XCTAssertEqual(
                converted,
                scenario.expected,
                scenario.name
            )
        }
    }

    func testPreviewFocusConversionRejectsPointsOutsidePreview() {
        let converted = CapturePreviewPointConverter.convert(
            screenPoint: CGPoint(x: 9, y: 30),
            previewFrameInWindow: CGRect(
                x: 10,
                y: 30,
                width: 200,
                height: 400
            )
        ) { _ in
            XCTFail("预览外点击不应调用AVCaptureVideoPreviewLayer转换")
            return .zero
        }

        XCTAssertNil(converted)
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
