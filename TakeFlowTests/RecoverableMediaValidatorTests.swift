import AVFoundation
import XCTest
@testable import TakeFlow

final class RecoverableMediaValidatorTests: XCTestCase {
    func testMissingFileIsRejected() async {
        let result = await AVFoundationRecoverableMediaValidator().validate(
            makeRecoverable(url: temporaryURL(name: "missing.mov"))
        )

        XCTAssertEqual(result, .invalid(.fileMissing))
    }

    func testCorruptContainerIsRejectedWithoutCrash() async throws {
        let url = temporaryURL(name: "corrupt.mov")
        try Data("not a movie".utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        let result = await AVFoundationRecoverableMediaValidator().validate(
            makeRecoverable(url: url)
        )

        XCTAssertEqual(result, .invalid(.containerUnrecognized))
    }

    func testPlayableVideoWithoutAudioReportsMissingAudioTrack()
        async throws
    {
        let url = try await makeMovie(includeAudio: false)
        let result = await AVFoundationRecoverableMediaValidator().validate(
            makeRecoverable(url: url)
        )

        guard case .playable(let info) = result else {
            return XCTFail("Expected playable media, received \(result)")
        }
        XCTAssertGreaterThan(info.duration, 0)
        XCTAssertFalse(info.hasAudioTrack)
    }

    func testPlayableVideoWithAudioReportsBothTracks() async throws {
        let url = try await makeMovie(includeAudio: true)
        let result = await AVFoundationRecoverableMediaValidator().validate(
            makeRecoverable(url: url)
        )

        guard case .playable(let info) = result else {
            return XCTFail("Expected playable media, received \(result)")
        }
        XCTAssertGreaterThan(info.duration, 0)
        XCTAssertTrue(info.hasAudioTrack)
    }

    private func makeMovie(includeAudio: Bool) async throws -> URL {
        let url = temporaryURL(name: "media-\(UUID().uuidString).mov")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 16,
                AVVideoHeightKey: 16
            ]
        )
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 16,
                kCVPixelBufferHeightKey as String: 16
            ]
        )
        XCTAssertTrue(writer.canAdd(videoInput))
        writer.add(videoInput)

        let audioInput: AVAssetWriterInput? = includeAudio
            ? AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 64_000
                ]
            ) : nil
        if let audioInput {
            XCTAssertTrue(writer.canAdd(audioInput))
            writer.add(audioInput)
        }

        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let pixelBuffer = try XCTUnwrap(makePixelBuffer())
        XCTAssertTrue(adaptor.append(pixelBuffer, withPresentationTime: .zero))
        XCTAssertTrue(
            adaptor.append(
                pixelBuffer,
                withPresentationTime: CMTime(seconds: 1, preferredTimescale: 600)
            )
        )
        if let audioInput {
            let audioBuffer = try makeSilentAudioSampleBuffer()
            XCTAssertTrue(audioInput.append(audioBuffer))
            audioInput.markAsFinished()
        }
        videoInput.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? CaptureError.fileFinalizationFailed
        }
        return url
    }

    private func makePixelBuffer() -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            nil,
            16,
            16,
            kCVPixelFormatType_32BGRA,
            nil,
            &buffer
        )
        return buffer
    }

    private func makeSilentAudioSampleBuffer() throws -> CMSampleBuffer {
        let frameCount = 48_000
        let byteCount = frameCount * MemoryLayout<Int16>.size
        var description = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger
                | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var formatDescription: CMAudioFormatDescription?
        XCTAssertEqual(
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &description,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: 0,
                magicCookie: nil,
                extensions: nil,
                formatDescriptionOut: &formatDescription
            ),
            noErr
        )
        var blockBuffer: CMBlockBuffer?
        XCTAssertEqual(
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: byteCount,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: byteCount,
                flags: 0,
                blockBufferOut: &blockBuffer
            ),
            kCMBlockBufferNoErr
        )
        let silence = Data(count: byteCount)
        try silence.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress,
                  let blockBuffer else {
                throw CaptureError.filePreparationFailed
            }
            let status = CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
            guard status == kCMBlockBufferNoErr else {
                throw CaptureError.filePreparationFailed
            }
        }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sampleSize = 2
        var sampleBuffer: CMSampleBuffer?
        XCTAssertEqual(
            CMSampleBufferCreate(
                allocator: kCFAllocatorDefault,
                dataBuffer: blockBuffer,
                dataReady: true,
                makeDataReadyCallback: nil,
                refcon: nil,
                formatDescription: try XCTUnwrap(formatDescription),
                sampleCount: frameCount,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleSizeEntryCount: 1,
                sampleSizeArray: &sampleSize,
                sampleBufferOut: &sampleBuffer
            ),
            noErr
        )
        return try XCTUnwrap(sampleBuffer)
    }

    private func makeRecoverable(url: URL) -> RecoverableRecording {
        RecoverableRecording(
            projectID: UUID(),
            recordingID: UUID(),
            fileURL: url,
            reason: .unknown,
            discoveredAt: .now
        )
    }

    private func temporaryURL(name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(name)
    }
}
