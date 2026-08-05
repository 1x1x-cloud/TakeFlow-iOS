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
    private var activeSessionGeneration: UInt64 = 0
    private var eventContinuations:
        [UUID: AsyncStream<CaptureSessionEvent>.Continuation] = [:]
    private struct ActiveRecordingContext: Sendable {
        let recordingID: UUID
        let sessionID: UUID
        let sessionGeneration: UInt64
        let cameraPosition: CameraPosition
        var didStart = false
    }
    private var activeRecordings: [URL: ActiveRecordingContext] = [:]
    private var activeRecordingID: UUID?
    private var stoppingRecordingID: UUID?
    private var durationTimer: DispatchSourceTimer?
    private var elapsedTimekeeper: RecordingElapsedTimekeeper
    private var notificationTokens: [NSObjectProtocol] = []
    private var shouldStopSessionAfterRecording = false
    private var interruptionWasIssued = false
    private var observedInterruptionReasons:
        Set<CaptureInterruptionReason> = []
    private var lastInterruptionReason: CaptureInterruptionReason?

    private struct NotificationContext: Sendable {
        let sessionID: UUID
        let generation: UInt64
    }

    override init() {
        elapsedTimekeeper = RecordingElapsedTimekeeper()
        super.init()
    }

    init(timeSource: any RecordingMonotonicTimeProviding) {
        elapsedTimekeeper = RecordingElapsedTimekeeper(
            timeSource: timeSource
        )
        super.init()
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
                self.activeSessionGeneration &+= 1
                self.interruptionWasIssued = false
                self.observedInterruptionReasons.removeAll()
                self.lastInterruptionReason = nil
                self.installNotifications(
                    for: NotificationContext(
                        sessionID: sessionID,
                        generation: self.activeSessionGeneration
                    )
                )
            }
            if self.hasConfiguredCaptureGraph {
                try self.reconfigureVideoLocked(
                    position: position,
                    preferredResolution: preferredResolution
                )
            } else {
                try self.configureLocked(
                    position: position,
                    preferredResolution: preferredResolution
                )
            }
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
                if let recordingID = self.activeRecordingID {
                    self.requestStopLocked(recordingID: recordingID)
                }
                return
            }
            if self.session.isRunning {
                self.session.stopRunning()
            }
            self.activeSessionID = nil
            self.activeSessionGeneration &+= 1
            self.currentConfiguration = nil
            self.currentCapabilities = .unavailable
            self.videoInput = nil
            self.audioInput = nil
            self.removeNotifications()
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
            guard self.session.isRunning else {
                throw CaptureError.cameraUnavailable
            }
            let target: CameraPosition =
                configuration.position == .front ? .back : .front
            self.recordDiagnostic(
                "camera_switch_began",
                isReconfiguring: true
            )
            try self.reconfigureVideoLocked(
                position: target,
                preferredResolution: configuration.format.resolution
            )
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
            self.recordDiagnostic(
                "camera_switch_completed",
                isReconfiguring: false
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
                seconds: RecordingMediaPolicy.movieFragmentIntervalSeconds,
                preferredTimescale: 600
            )
            let standardizedURL = outputURL.standardizedFileURL
            self.activeRecordingID = recordingID
            self.activeRecordings[standardizedURL] = ActiveRecordingContext(
                recordingID: recordingID,
                sessionID: sessionID,
                sessionGeneration: self.activeSessionGeneration,
                cameraPosition: configuration.position
            )
            self.interruptionWasIssued = false
            self.observedInterruptionReasons.removeAll()
            self.shouldStopSessionAfterRecording = false
            self.stoppingRecordingID = nil
            self.movieOutput.startRecording(
                to: standardizedURL,
                recordingDelegate: self
            )
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
            self.requestStopLocked(recordingID: recordingID)
        }
    }

    func setFocusAndExposurePoint(
        sessionID: UUID,
        at point: NormalizedCapturePoint
    ) async throws -> CapturePointAdjustmentResult {
        try await runOnSessionQueue {
            guard self.activeSessionID == sessionID else {
                throw CaptureError.staleCallback
            }
            guard let device = self.videoInput?.device else {
                throw CaptureError.cameraUnavailable
            }
            let canSetFocusPoint =
                device.isFocusPointOfInterestSupported
                && device.isFocusModeSupported(.autoFocus)
            let canSetExposurePoint =
                device.isExposurePointOfInterestSupported
                && device.isExposureModeSupported(.autoExpose)
            guard canSetFocusPoint || canSetExposurePoint else {
                throw CaptureError.focusUnsupported
            }
            let devicePoint = CGPoint(x: point.x, y: point.y)
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            var focusApplied = false
            if canSetFocusPoint {
                device.focusPointOfInterest = devicePoint
                device.focusMode = .autoFocus
                focusApplied = true
            }

            var exposureApplied = false
            if canSetExposurePoint {
                device.exposurePointOfInterest = devicePoint
                device.exposureMode = .autoExpose
                exposureApplied = true
            }

            return CapturePointAdjustmentResult(
                focusApplied: focusApplied,
                exposureApplied: exposureApplied
            )
        }
    }

    func setFocusAndExposureLocked(
        sessionID: UUID,
        locked: Bool
    ) async throws -> CaptureFocusExposureLockState {
        try await runOnSessionQueue {
            guard self.activeSessionID == sessionID else {
                throw CaptureError.staleCallback
            }
            guard let device = self.videoInput?.device else {
                throw CaptureError.cameraUnavailable
            }

            let focusMode: AVCaptureDevice.FocusMode =
                locked ? .locked : .continuousAutoFocus
            let exposureMode: AVCaptureDevice.ExposureMode =
                locked ? .locked : .continuousAutoExposure
            guard device.isFocusModeSupported(focusMode) else {
                throw CaptureError.focusUnsupported
            }
            guard device.isExposureModeSupported(exposureMode) else {
                throw CaptureError.exposureUnsupported
            }

            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.focusMode = focusMode
            device.exposureMode = exposureMode

            return CaptureFocusExposureLockState(
                focusLocked: device.focusMode == .locked,
                exposureLocked: device.exposureMode == .locked
            )
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
        try resetFocusAndExposureToContinuousModes(on: device)

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

    /// Reconfigures only the video input. The microphone input and movie
    /// output remain attached so a camera switch cannot tear down the audio
    /// graph while a completed movie is being finalized.
    private func reconfigureVideoLocked(
        position: CameraPosition,
        preferredResolution: VideoResolution
    ) throws {
        guard activeRecordingID == nil else {
            throw CaptureError.alreadyRecording
        }
        guard
            let oldVideoInput = videoInput,
            let audioInput,
            session.inputs.contains(where: { $0 === oldVideoInput }),
            session.inputs.contains(where: { $0 === audioInput }),
            session.outputs.contains(where: { $0 === movieOutput })
        else {
            throw CaptureError.unsupportedConfiguration
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

        let supportedResolutions = Set(
            VideoResolution.allCases.filter {
                supports(device: device, resolution: $0)
                    && session.canSetSessionPreset(Self.preset(for: $0))
            }
        )
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

        let newVideoInput = try AVCaptureDeviceInput(device: device)
        try resetFocusAndExposureToContinuousModes(
            on: oldVideoInput.device
        )
        session.beginConfiguration()
        session.removeInput(oldVideoInput)
        do {
            let preset = Self.preset(for: selectedFormat.resolution)
            guard
                session.canSetSessionPreset(preset),
                session.canAddInput(newVideoInput)
            else {
                throw CaptureError.unsupportedConfiguration
            }
            session.sessionPreset = preset
            session.addInput(newVideoInput)
            try setThirtyFramesPerSecond(
                on: device,
                resolution: selectedFormat.resolution
            )
            try resetFocusAndExposureToContinuousModes(on: device)
            session.commitConfiguration()
        } catch {
            if session.inputs.contains(where: { $0 === newVideoInput }) {
                session.removeInput(newVideoInput)
            }
            if session.canAddInput(oldVideoInput) {
                session.addInput(oldVideoInput)
            }
            session.commitConfiguration()
            throw error
        }

        let capabilities = makeCapabilities(
            device: device,
            availableCodecs: availableCodecs
        )
        videoInput = newVideoInput
        currentConfiguration = CaptureConfiguration(
            position: position,
            format: selectedFormat,
            previewMirrored: position == .front,
            outputMirrored: false
        )
        currentCapabilities = capabilities
    }

    private var hasConfiguredCaptureGraph: Bool {
        guard let videoInput, let audioInput else {
            return false
        }
        return session.inputs.contains(where: { $0 === videoInput })
            && session.inputs.contains(where: { $0 === audioInput })
            && session.outputs.contains(where: { $0 === movieOutput })
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
            supportsFocusPoint:
                device.isFocusPointOfInterestSupported
                && device.isFocusModeSupported(.autoFocus),
            supportsExposurePoint:
                device.isExposurePointOfInterestSupported
                && device.isExposureModeSupported(.autoExpose),
            supportsFocusLock: device.isFocusModeSupported(.locked),
            supportsExposureLock: device.isExposureModeSupported(.locked),
            supportsContinuousFocus:
                device.isFocusModeSupported(.continuousAutoFocus),
            supportsContinuousExposure:
                device.isExposureModeSupported(.continuousAutoExposure),
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

    private func resetFocusAndExposureToContinuousModes(
        on device: AVCaptureDevice
    ) throws {
        let canResetFocus =
            device.isFocusModeSupported(.continuousAutoFocus)
        let canResetExposure =
            device.isExposureModeSupported(.continuousAutoExposure)
        guard canResetFocus || canResetExposure else {
            return
        }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        if canResetFocus {
            device.focusMode = .continuousAutoFocus
        }
        if canResetExposure {
            device.exposureMode = .continuousAutoExposure
        }
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
        guard elapsedTimekeeper.start(recordingID: recordingID) else {
            return
        }
        durationTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: sessionQueue)
        timer.schedule(
            deadline: .now(),
            repeating: RecordingMediaPolicy.durationUpdateInterval
        )
        timer.setEventHandler { [weak self] in
            guard
                let self,
                self.activeRecordingID == recordingID,
                self.movieOutput.isRecording,
                let seconds = self.elapsedTimekeeper.elapsed(
                    for: recordingID
                )
            else {
                return
            }
            self.yieldToActiveSession(
                .duration(
                    recordingID: recordingID,
                    seconds: seconds
                )
            )
        }
        durationTimer = timer
        timer.resume()
    }

    private func stopDurationTimer(recordingID: UUID) {
        durationTimer?.cancel()
        durationTimer = nil
        _ = elapsedTimekeeper.stop(recordingID: recordingID)
    }

    private func requestStopLocked(recordingID: UUID) {
        guard activeRecordingID == recordingID else {
            return
        }
        guard stoppingRecordingID != recordingID else {
            return
        }
        stoppingRecordingID = recordingID
        stopDurationTimer(recordingID: recordingID)
        let hasRequestedOutput = activeRecordings.values.contains {
            $0.recordingID == recordingID
        }
        if movieOutput.isRecording || hasRequestedOutput {
            movieOutput.stopRecording()
        }
    }

    private func installNotifications(for context: NotificationContext) {
        removeNotifications()
        let center = NotificationCenter.default
        notificationTokens.append(
            center.addObserver(
                forName: .AVCaptureSessionWasInterrupted,
                object: session,
                queue: nil
            ) { [weak self] notification in
                guard let captureService = self else {
                    return
                }
                let rawReason = notification.userInfo?[
                    AVCaptureSessionInterruptionReasonKey
                ] as? NSNumber
                let rawValue = rawReason?.intValue
                let reason = Self.domainInterruptionReason(
                    fromAVFoundationRawValue: rawValue
                )
                captureService.sessionQueue.async {
                    captureService.interruptLocked(
                        reason: reason,
                        context: context,
                        rawReason: rawValue
                    )
                }
            }
        )
        notificationTokens.append(
            center.addObserver(
                forName: .AVCaptureSessionInterruptionEnded,
                object: session,
                queue: nil
            ) { [weak self] _ in
                guard let captureService = self else {
                    return
                }
                captureService.sessionQueue.async {
                    captureService.endInterruptionLocked(context: context)
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
                let isMediaServicesReset = Self
                    .isMediaServicesResetRuntimeError(nsError)
                guard let captureService = self else {
                    return
                }
                captureService.sessionQueue.async {
                    guard captureService.isCurrent(context) else {
                        return
                    }
                    if isMediaServicesReset {
                        captureService.yieldToActiveSession(
                            .mediaServicesReset
                        )
                        captureService.interruptLocked(
                            reason: .mediaServicesReset,
                            context: context,
                            rawReason: nil
                        )
                    } else {
                        captureService.interruptLocked(
                            reason: .unknown,
                            context: context,
                            rawReason: nil
                        )
                    }
                }
            }
        )
    }

    private func removeNotifications() {
        notificationTokens.forEach(
            NotificationCenter.default.removeObserver
        )
        notificationTokens.removeAll()
    }

    private func interruptLocked(
        reason: CaptureInterruptionReason,
        context: NotificationContext? = nil,
        rawReason: Int? = nil
    ) {
        if let context, !isCurrent(context) {
            recordDiagnostic(
                "stale_interruption_ignored",
                interruptionReason: reason,
                interruptionEnded: false,
                rawInterruptionReason: rawReason
            )
            return
        }
        let inserted = observedInterruptionReasons.insert(reason).inserted
        guard inserted else {
            return
        }
        let isFirstInterruptionSource = !interruptionWasIssued
        interruptionWasIssued = true
        if isFirstInterruptionSource {
            lastInterruptionReason = reason
        }
        recordDiagnostic(
            "capture_interruption_began",
            interruptionReason: reason,
            interruptionEnded: false,
            rawInterruptionReason: rawReason
        )
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
            guard isFirstInterruptionSource else {
                return
            }
            shouldStopSessionAfterRecording = true
            requestStopLocked(recordingID: recordingID)
        } else {
            yieldToActiveSession(
                .interrupted(
                    recordingID: nil,
                    reason: reason,
                    outputURL: nil
                )
            )
            guard isFirstInterruptionSource else {
                return
            }
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    private func endInterruptionLocked(context: NotificationContext) {
        guard isCurrent(context), interruptionWasIssued else {
            recordDiagnostic(
                "stale_interruption_end_ignored",
                interruptionReason: lastInterruptionReason,
                interruptionEnded: true
            )
            return
        }
        let reason = lastInterruptionReason
        interruptionWasIssued = false
        observedInterruptionReasons.removeAll()
        recordDiagnostic(
            "capture_interruption_ended",
            interruptionReason: reason,
            interruptionEnded: true
        )
        yieldToActiveSession(.interruptionEnded(reason: reason))
    }

    private func isCurrent(_ context: NotificationContext) -> Bool {
        activeSessionID == context.sessionID
            && activeSessionGeneration == context.generation
    }

    private func recordDiagnostic(
        _ event: String,
        isReconfiguring: Bool = false,
        interruptionReason: CaptureInterruptionReason? = nil,
        interruptionEnded: Bool? = nil,
        rawInterruptionReason: Int? = nil
    ) {
        CaptureDiagnostics.record(
            event,
            lifecycleGeneration: activeSessionGeneration,
            sessionID: activeSessionID,
            cameraPosition: currentConfiguration?.position,
            isRecording: activeRecordingID != nil,
            isFinalizing: stoppingRecordingID != nil,
            isReconfiguring: isReconfiguring,
            interruptionReason: interruptionReason,
            interruptionEnded: interruptionEnded,
            rawInterruptionReason: rawInterruptionReason
        )
    }

    static func domainInterruptionReason(
        fromAVFoundationRawValue rawValue: Int?
    ) -> CaptureInterruptionReason {
        switch rawValue {
        case 1:
            .applicationBackgrounded
        case 2:
            .audioDeviceInUseByAnotherClient
        case 3:
            .videoDeviceInUseByAnotherClient
        case 4:
            .videoDeviceNotAvailableWithMultipleForegroundApps
        case 5:
            .videoDeviceNotAvailableDueToSystemPressure
        case 6:
            .sensitiveContentMitigationActivated
        default:
            .unknown
        }
    }

    static func isMediaServicesResetRuntimeError(
        _ error: NSError?
    ) -> Bool {
        guard error?.domain == AVFoundationErrorDomain,
              let rawCode = error?.code
        else {
            return false
        }
        return AVError.Code(rawValue: rawCode) == .mediaServicesWereReset
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
        didStartRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        sessionQueue.async {
            let standardizedURL = outputFileURL.standardizedFileURL
            guard
                var recordingContext =
                    self.activeRecordings[standardizedURL],
                self.activeRecordingID == recordingContext.recordingID,
                self.activeSessionID == recordingContext.sessionID,
                self.activeSessionGeneration
                    == recordingContext.sessionGeneration,
                !recordingContext.didStart
            else {
                return
            }

            if self.stoppingRecordingID == recordingContext.recordingID {
                if output.isRecording {
                    output.stopRecording()
                }
                return
            }

            recordingContext.didStart = true
            self.activeRecordings[standardizedURL] = recordingContext
            self.yield(
                .recordingStarted(
                    recordingID: recordingContext.recordingID
                ),
                to: recordingContext.sessionID
            )
            self.startDurationTimer(
                recordingID: recordingContext.recordingID
            )
        }
    }

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
            #if DEBUG
            let attributes = try? FileManager.default.attributesOfItem(
                atPath: standardizedURL.path
            )
            let fileSize = (attributes?[.size] as? NSNumber)?.int64Value
            CaptureDiagnostics.record(
                "recording_did_finish_received",
                lifecycleGeneration: recordingContext.sessionGeneration,
                sessionID: recordingContext.sessionID,
                cameraPosition: recordingContext.cameraPosition,
                isRecording: false,
                isFinalizing: true,
                isReconfiguring: false,
                recordingID: recordingID,
                didFinishFile: true,
                fileExists: attributes != nil,
                fileNonEmpty: fileSize.map { $0 > 0 }
            )
            #endif
            self.stopDurationTimer(recordingID: recordingID)
            self.elapsedTimekeeper.reset()
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
                    self.activeSessionGeneration &+= 1
                    self.currentConfiguration = nil
                    self.currentCapabilities = .unavailable
                    self.videoInput = nil
                    self.audioInput = nil
                    self.removeNotifications()
                }
                self.finishEvents(for: recordingContext.sessionID)
            }
            self.shouldStopSessionAfterRecording = false
        }
    }
}
