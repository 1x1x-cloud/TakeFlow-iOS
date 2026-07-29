@preconcurrency import AVFoundation
import Foundation

final class AVFoundationCaptureService: NSObject, CaptureSessionServicing,
    @unchecked Sendable
{
    private let session = AVCaptureSession()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let sessionQueue = DispatchQueue(
        label: "com.example.takeflow.capture-session",
        qos: .userInitiated
    )

    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var currentConfiguration: CaptureConfiguration?
    private var currentCapabilities: CaptureCapabilities = .unavailable
    private var activeSessionID: UUID?
    private var eventContinuations:
        [UUID: AsyncStream<CaptureSessionEvent>.Continuation] = [:]
    private var activeRecordings:
        [URL: (recordingID: UUID, sessionID: UUID)] = [:]
    private var activeRecordingID: UUID?
    private var stoppingRecordingID: UUID?
    private var durationTimer: DispatchSourceTimer?
    private var notificationTokens: [NSObjectProtocol] = []
    private var shouldStopSessionAfterRecording = false
    private var interruptionWasIssued = false

    override init() {
        super.init()
        installNotifications()
    }

    deinit {
        durationTimer?.cancel()
        notificationTokens.forEach(
            NotificationCenter.default.removeObserver
        )
        eventContinuations.values.forEach { $0.finish() }
    }

    func events(
        for sessionID: UUID
    ) async -> AsyncStream<CaptureSessionEvent> {
        let pair = AsyncStream<CaptureSessionEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(32)
        )
        pair.continuation.onTermination = { [weak self] _ in
            guard let captureService = self else {
                return
            }
            captureService.sessionQueue.async { [weak captureService] in
                captureService?.removeEventContinuation(for: sessionID)
            }
        }
        await runOnSessionQueueWithoutThrowing {
            self.eventContinuations.removeValue(forKey: sessionID)?.finish()
            self.eventContinuations[sessionID] = pair.continuation
        }
        return pair.stream
    }

    func configure(
        sessionID: UUID,
        position: CameraPosition,
        preferredResolution: VideoResolution
    ) async throws {
        try await runOnSessionQueue {
            guard self.activeRecordingID == nil else {
                throw CaptureError.alreadyRecording
            }
            if self.activeSessionID != sessionID {
                if let previousSessionID = self.activeSessionID {
                    self.finishEvents(for: previousSessionID)
                }
                if self.session.isRunning {
                    self.session.stopRunning()
                }
                self.activeSessionID = sessionID
                self.interruptionWasIssued = false
            }
            try self.configureLocked(
                position: position,
                preferredResolution: preferredResolution
            )
        }
    }

    func startPreview(sessionID: UUID) async throws {
        try await runOnSessionQueue {
            guard
                self.activeSessionID == sessionID,
                let configuration = self.currentConfiguration,
                let device = self.videoInput?.device
            else {
                throw CaptureError.staleCallback
            }
            if !self.session.isRunning {
                self.session.startRunning()
            }
            self.yield(
                .sessionReady(
                    source: CapturePreviewSource(
                        session: self.session,
                        device: device
                    ),
                    configuration: configuration,
                    capabilities: self.currentCapabilities
                ),
                to: sessionID
            )
        }
    }

    func stopPreview(sessionID: UUID) async {
        await runOnSessionQueueWithoutThrowing {
            guard self.activeSessionID == sessionID else {
                self.finishEvents(for: sessionID)
                return
            }
            guard self.activeRecordingID == nil else {
                self.shouldStopSessionAfterRecording = true
                if
                    self.stoppingRecordingID != self.activeRecordingID,
                    self.movieOutput.isRecording
                {
                    self.stoppingRecordingID = self.activeRecordingID
                    self.movieOutput.stopRecording()
                }
                return
            }
            if self.session.isRunning {
                self.session.stopRunning()
            }
            self.activeSessionID = nil
            self.currentConfiguration = nil
            self.currentCapabilities = .unavailable
            self.videoInput = nil
            self.audioInput = nil
            self.finishEvents(for: sessionID)
        }
    }

    func switchCamera(sessionID: UUID) async throws {
        try await runOnSessionQueue {
            guard self.activeSessionID == sessionID else {
                throw CaptureError.staleCallback
            }
            guard self.activeRecordingID == nil else {
                throw CaptureError.cameraSwitchDuringRecording
            }
            guard let configuration = self.currentConfiguration else {
                throw CaptureError.cameraUnavailable
            }
            let target: CameraPosition =
                configuration.position == .front ? .back : .front
            try self.configureLocked(
                position: target,
                preferredResolution: configuration.format.resolution
            )
            if !self.session.isRunning {
                self.session.startRunning()
            }
            guard
                let updatedConfiguration = self.currentConfiguration,
                let device = self.videoInput?.device
            else {
                throw CaptureError.cameraUnavailable
            }
            self.yield(
                .sessionReady(
                    source: CapturePreviewSource(
                        session: self.session,
                        device: device
                    ),
                    configuration: updatedConfiguration,
                    capabilities: self.currentCapabilities
                ),
                to: sessionID
            )
        }
    }

    func startRecording(
        sessionID: UUID,
        recordingID: UUID,
        outputURL: URL,
        rotationAngle: Double
    ) async throws {
        try await runOnSessionQueue {
            guard
                self.activeSessionID == sessionID,
                self.activeRecordingID == nil,
                let configuration = self.currentConfiguration,
                self.session.isRunning
            else {
                throw CaptureError.alreadyRecording
            }
            guard
                let videoConnection = self.movieOutput.connection(with: .video)
            else {
                throw CaptureError.unsupportedConfiguration
            }

            videoConnection.automaticallyAdjustsVideoMirroring = false
            videoConnection.isVideoMirrored = configuration.outputMirrored
            if videoConnection.isVideoRotationAngleSupported(rotationAngle) {
                videoConnection.videoRotationAngle = rotationAngle
            }
            if videoConnection.isVideoStabilizationSupported {
                videoConnection.preferredVideoStabilizationMode = .auto
            }

            let codec = Self.avCodec(for: configuration.format.codec)
            self.movieOutput.setOutputSettings(
                [AVVideoCodecKey: codec],
                for: videoConnection
            )
            if let audioConnection = self.movieOutput.connection(with: .audio) {
                self.movieOutput.setOutputSettings(
                    [
                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVSampleRateKey: 48_000,
                        AVEncoderBitRateKey: 128_000
                    ],
                    for: audioConnection
                )
            }

            self.movieOutput.movieFragmentInterval = CMTime(
                seconds: 2,
                preferredTimescale: 600
            )
            let standardizedURL = outputURL.standardizedFileURL
            self.activeRecordingID = recordingID
            self.activeRecordings[standardizedURL] = (
                recordingID: recordingID,
                sessionID: sessionID
            )
            self.interruptionWasIssued = false
            self.shouldStopSessionAfterRecording = false
            self.stoppingRecordingID = nil
            self.movieOutput.startRecording(
                to: standardizedURL,
                recordingDelegate: self
            )
            self.startDurationTimer(recordingID: recordingID)
        }
    }

    func stopRecording(recordingID: UUID) async throws {
        try await runOnSessionQueue {
            guard let activeID = self.activeRecordingID else {
                throw CaptureError.notRecording
            }
            guard activeID == recordingID else {
                throw CaptureError.staleCallback
            }
            if self.stoppingRecordingID == recordingID {
                return
            }
            guard self.movieOutput.isRecording else {
                throw CaptureError.notRecording
            }
            self.stoppingRecordingID = recordingID
            self.movieOutput.stopRecording()
        }
    }

    func setFocusAndExposure(
        sessionID: UUID,
        at point: NormalizedCapturePoint,
        locked: Bool
    ) async throws {
        try await runOnSessionQueue {
            guard self.activeSessionID == sessionID else {
                throw CaptureError.staleCallback
            }
            guard let device = self.videoInput?.device else {
                throw CaptureError.cameraUnavailable
            }
            guard
                device.isFocusPointOfInterestSupported
                    || device.isExposurePointOfInterestSupported
            else {
                throw CaptureError.focusUnsupported
            }
            let devicePoint = CGPoint(x: point.x, y: point.y)
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = devicePoint
                let focusMode: AVCaptureDevice.FocusMode =
                    locked && device.isFocusModeSupported(.locked)
                    ? .locked : .autoFocus
                guard device.isFocusModeSupported(focusMode) else {
                    throw CaptureError.focusUnsupported
                }
                device.focusMode = focusMode
            }

            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = devicePoint
                let exposureMode: AVCaptureDevice.ExposureMode =
                    locked && device.isExposureModeSupported(.locked)
                    ? .locked : .continuousAutoExposure
                guard device.isExposureModeSupported(exposureMode) else {
                    throw CaptureError.exposureUnsupported
                }
                device.exposureMode = exposureMode
            }
        }
    }

    func handleApplicationBackgrounded(sessionID: UUID) async {
        await runOnSessionQueueWithoutThrowing {
            guard self.activeSessionID == sessionID else {
                return
            }
            self.interruptLocked(reason: .applicationBackgrounded)
        }
    }

    func handleApplicationForegrounded(sessionID: UUID) async {
        await runOnSessionQueueWithoutThrowing {
            guard self.activeSessionID == sessionID else {
                return
            }
            // Deliberately does not restart the session or recording. The user
            // must explicitly reconfigure and start a new recording.
        }
    }

    private func configureLocked(
        position: CameraPosition,
        preferredResolution: VideoResolution
    ) throws {
        guard activeRecordingID == nil else {
            throw CaptureError.alreadyRecording
        }
        let devicePosition: AVCaptureDevice.Position =
            position == .front ? .front : .back
        guard let device = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: devicePosition
        ) else {
            throw CaptureError.cameraUnavailable
        }
        guard let microphone = AVCaptureDevice.default(for: .audio) else {
            throw CaptureError.microphoneUnavailable
        }

        let supportedResolutions = Set(
            VideoResolution.allCases.filter {
                supports(device: device, resolution: $0)
                    && session.canSetSessionPreset(Self.preset(for: $0))
            }
        )

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        for input in session.inputs {
            session.removeInput(input)
        }
        for output in session.outputs {
            session.removeOutput(output)
        }

        let preliminaryResolution =
            supportedResolutions.contains(preferredResolution)
            ? preferredResolution : .fullHD1080p
        let preset = Self.preset(for: preliminaryResolution)
        guard session.canSetSessionPreset(preset) else {
            throw CaptureError.unsupportedConfiguration
        }
        session.sessionPreset = preset

        let newVideoInput = try AVCaptureDeviceInput(device: device)
        let newAudioInput = try AVCaptureDeviceInput(device: microphone)
        guard
            session.canAddInput(newVideoInput),
            session.canAddInput(newAudioInput),
            session.canAddOutput(movieOutput)
        else {
            throw CaptureError.unsupportedConfiguration
        }
        session.addInput(newVideoInput)
        session.addInput(newAudioInput)
        session.addOutput(movieOutput)

        let availableCodecs = movieOutput.availableVideoCodecTypes
        let domainCodecs = Set(
            availableCodecs.compactMap(Self.domainCodec(for:))
        )
        guard
            let selectedFormat = CaptureFormatSelector.select(
                preferredResolution: preferredResolution,
                supportedResolutions: supportedResolutions,
                availableCodecs: domainCodecs
            )
        else {
            throw CaptureError.unsupportedConfiguration
        }
        try setThirtyFramesPerSecond(
            on: device,
            resolution: selectedFormat.resolution
        )

        let capabilities = makeCapabilities(
            device: device,
            availableCodecs: availableCodecs
        )
        let configuration = CaptureConfiguration(
            position: position,
            format: selectedFormat,
            previewMirrored: position == .front,
            outputMirrored: false
        )
        videoInput = newVideoInput
        audioInput = newAudioInput
        currentConfiguration = configuration
        currentCapabilities = capabilities
    }

    private func makeCapabilities(
        device: AVCaptureDevice,
        availableCodecs: [AVVideoCodecType]
    ) -> CaptureCapabilities {
        let formats: [CaptureFormatOption] =
            VideoResolution.allCases.compactMap {
                resolution -> CaptureFormatOption? in
            guard
                supports(device: device, resolution: resolution),
                session.canSetSessionPreset(Self.preset(for: resolution)),
                let codec = selectCodec(
                    resolution: resolution,
                    available: availableCodecs
                )
            else {
                return nil
            }
            return CaptureFormatOption(
                resolution: resolution,
                framesPerSecond: 30,
                codec: codec
            )
            }
        return CaptureCapabilities(
            availableFormats: formats,
            supportsFocusPoint: device.isFocusPointOfInterestSupported,
            supportsExposurePoint: device.isExposurePointOfInterestSupported,
            supportsFocusLock: device.isFocusModeSupported(.locked),
            supportsExposureLock: device.isExposureModeSupported(.locked),
            supportsVideoStabilization:
                movieOutput.connection(with: .video)?
                    .isVideoStabilizationSupported == true
        )
    }

    private func supports(
        device: AVCaptureDevice,
        resolution: VideoResolution
    ) -> Bool {
        let target = Self.dimensions(for: resolution)
        return device.formats.contains { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(
                format.formatDescription
            )
            return dimensions.width >= target.width
                && dimensions.height >= target.height
                && format.videoSupportedFrameRateRanges.contains {
                    $0.minFrameRate <= 30 && $0.maxFrameRate >= 30
                }
        }
    }

    private func setThirtyFramesPerSecond(
        on device: AVCaptureDevice,
        resolution: VideoResolution
    ) throws {
        let target = Self.dimensions(for: resolution)
        guard let format = device.formats.first(where: { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(
                format.formatDescription
            )
            return dimensions.width >= target.width
                && dimensions.height >= target.height
                && format.videoSupportedFrameRateRanges.contains {
                    $0.minFrameRate <= 30 && $0.maxFrameRate >= 30
                }
        }) else {
            throw CaptureError.unsupportedConfiguration
        }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.activeFormat = format
        let duration = CMTime(value: 1, timescale: 30)
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
    }

    private func selectCodec(
        resolution: VideoResolution,
        available: [AVVideoCodecType]
    ) -> CaptureVideoCodec? {
        let preferred: [CaptureVideoCodec] =
            resolution == .ultraHD4K ? [.hevc, .h264] : [.h264, .hevc]
        return preferred.first { available.contains(Self.avCodec(for: $0)) }
    }

    private func startDurationTimer(recordingID: UUID) {
        durationTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: sessionQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            guard
                let self,
                self.activeRecordingID == recordingID,
                self.movieOutput.isRecording
            else {
                return
            }
            let seconds = CMTimeGetSeconds(self.movieOutput.recordedDuration)
            if seconds.isFinite {
                self.yieldToActiveSession(
                    .duration(
                        recordingID: recordingID,
                        seconds: seconds
                    )
                )
            }
        }
        durationTimer = timer
        timer.resume()
    }

    private func installNotifications() {
        let center = NotificationCenter.default
        notificationTokens.append(
            center.addObserver(
                forName: .AVCaptureSessionWasInterrupted,
                object: session,
                queue: nil
            ) { [weak self] _ in
                guard let captureService = self else {
                    return
                }
                captureService.sessionQueue.async {
                    captureService.interruptLocked(
                        reason: .cameraUnavailable
                    )
                }
            }
        )
        notificationTokens.append(
            center.addObserver(
                forName: .AVCaptureSessionRuntimeError,
                object: session,
                queue: nil
            ) { [weak self] notification in
                let nsError = notification.userInfo?[
                    AVCaptureSessionErrorKey
                ] as? NSError
                let isMediaServicesReset =
                    nsError?.code
                    == AVError.Code.mediaServicesWereReset.rawValue
                guard let captureService = self else {
                    return
                }
                captureService.sessionQueue.async {
                    if isMediaServicesReset {
                        captureService.yieldToActiveSession(
                            .mediaServicesReset
                        )
                        captureService.interruptLocked(
                            reason: .mediaServicesReset
                        )
                    } else {
                        captureService.interruptLocked(reason: .unknown)
                    }
                }
            }
        )
    }

    private func interruptLocked(reason: CaptureInterruptionReason) {
        guard !interruptionWasIssued else {
            return
        }
        interruptionWasIssued = true
        if let recordingID = activeRecordingID {
            let outputURL = activeRecordings.first {
                $0.value.recordingID == recordingID
            }?.key
            yieldToActiveSession(
                .interrupted(
                    recordingID: recordingID,
                    reason: reason,
                    outputURL: outputURL
                )
            )
            shouldStopSessionAfterRecording = true
            if
                stoppingRecordingID != recordingID,
                movieOutput.isRecording
            {
                stoppingRecordingID = recordingID
                movieOutput.stopRecording()
            }
        } else {
            yieldToActiveSession(
                .interrupted(
                    recordingID: nil,
                    reason: reason,
                    outputURL: nil
                )
            )
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    private func yieldToActiveSession(_ event: CaptureSessionEvent) {
        guard let activeSessionID else {
            return
        }
        yield(event, to: activeSessionID)
    }

    private func yield(
        _ event: CaptureSessionEvent,
        to sessionID: UUID
    ) {
        eventContinuations[sessionID]?.yield(event)
    }

    private func finishEvents(for sessionID: UUID) {
        eventContinuations.removeValue(forKey: sessionID)?.finish()
    }

    private func removeEventContinuation(for sessionID: UUID) {
        eventContinuations.removeValue(forKey: sessionID)
    }

    private func runOnSessionQueue<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func runOnSessionQueueWithoutThrowing(
        _ operation: @escaping @Sendable () -> Void
    ) async {
        await withCheckedContinuation { continuation in
            sessionQueue.async {
                operation()
                continuation.resume()
            }
        }
    }

    private static func preset(
        for resolution: VideoResolution
    ) -> AVCaptureSession.Preset {
        resolution == .ultraHD4K ? .hd4K3840x2160 : .hd1920x1080
    }

    private static func dimensions(
        for resolution: VideoResolution
    ) -> CMVideoDimensions {
        resolution == .ultraHD4K
            ? CMVideoDimensions(width: 3_840, height: 2_160)
            : CMVideoDimensions(width: 1_920, height: 1_080)
    }

    private static func avCodec(
        for codec: CaptureVideoCodec
    ) -> AVVideoCodecType {
        codec == .hevc ? .hevc : .h264
    }

    private static func domainCodec(
        for codec: AVVideoCodecType
    ) -> CaptureVideoCodec? {
        switch codec {
        case .h264:
            .h264
        case .hevc:
            .hevc
        default:
            nil
        }
    }
}

extension AVFoundationCaptureService: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: (any Error)?
    ) {
        sessionQueue.async {
            let standardizedURL = outputFileURL.standardizedFileURL
            guard
                let recordingContext = self.activeRecordings.removeValue(
                    forKey: standardizedURL
                )
            else {
                return
            }
            let recordingID = recordingContext.recordingID
            let duration = CMTimeGetSeconds(output.recordedDuration)
            self.durationTimer?.cancel()
            self.durationTimer = nil
            self.activeRecordingID = nil
            self.stoppingRecordingID = nil

            let wasSuccessful: Bool
            if let error = error as NSError? {
                wasSuccessful =
                    error.userInfo[
                        AVErrorRecordingSuccessfullyFinishedKey
                    ] as? Bool == true
            } else {
                wasSuccessful = true
            }

            if wasSuccessful {
                self.yield(
                    .recordingFinished(
                        recordingID: recordingID,
                        outputURL: standardizedURL,
                        duration: duration.isFinite ? max(duration, 0) : 0
                    ),
                    to: recordingContext.sessionID
                )
            } else {
                self.yield(
                    .recordingFailed(
                        recordingID: recordingID,
                        outputURL: standardizedURL,
                        error: .recordingFailed
                    ),
                    to: recordingContext.sessionID
                )
            }

            if self.shouldStopSessionAfterRecording {
                if self.session.isRunning {
                    self.session.stopRunning()
                }
                if self.activeSessionID == recordingContext.sessionID {
                    self.activeSessionID = nil
                    self.currentConfiguration = nil
                    self.currentCapabilities = .unavailable
                    self.videoInput = nil
                    self.audioInput = nil
                }
                self.finishEvents(for: recordingContext.sessionID)
            }
            self.shouldStopSessionAfterRecording = false
        }
    }
}
