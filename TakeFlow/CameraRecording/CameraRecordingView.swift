import SwiftUI

struct CameraRecordingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var recordingViewModel: CameraRecordingViewModel
    @StateObject private var teleprompterViewModel: TeleprompterViewModel
    @StateObject private var localRecordingPlayer:
        LocalRecordingPlayerController
    @State private var showsLocalPreview = false
    @State private var isClosing = false
    @State private var focusRequest: CaptureFocusRequest?
    @State private var focusIndicator: CaptureFocusIndicator?
    @State private var focusIndicatorDismissTask: Task<Void, Never>?
    @State private var focusOperationTask: Task<Void, Never>?
    @State private var focusLockTask: Task<Void, Never>?

    private static let focusCoordinateSpace = "camera-recording-focus"

    init(
        scriptID: UUID,
        service: any TeleprompterScriptProviding,
        dependencies: CameraRecordingDependencies
    ) {
        _recordingViewModel = StateObject(
            wrappedValue: CameraRecordingViewModel(
                scriptID: scriptID,
                dependencies: dependencies
            )
        )
        _teleprompterViewModel = StateObject(
            wrappedValue: TeleprompterViewModel(
                scriptID: scriptID,
                service: service
            )
        )
#if DEBUG
        let playerFactory: any LocalRecordingPlayerCreating =
            dependencies.isUITestFake
            ? FakeLocalRecordingPlayerFactory()
            : SystemLocalRecordingPlayerFactory()
#else
        let playerFactory: any LocalRecordingPlayerCreating =
            SystemLocalRecordingPlayerFactory()
#endif
        _localRecordingPlayer = StateObject(
            wrappedValue: LocalRecordingPlayerController(
                factory: playerFactory,
                photos: dependencies.photos
            )
        )
    }

    var body: some View {
        GeometryReader { geometry in
            TimelineView(
                .animation(
                    minimumInterval: 1.0 / 120.0,
                    paused: !needsTeleprompterClock
                )
            ) { timeline in
                ZStack {
                    previewLayer
                    Color.black.opacity(0.18)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)

                    focusTapSurface(in: geometry)

                    if let document = teleprompterViewModel.document,
                       !teleprompterViewModel.isEmpty {
                        promptText(document: document, in: geometry)
                    }

                    if let focusIndicator {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(.yellow, lineWidth: 2)
                            .frame(width: 64, height: 64)
                            .position(focusIndicator.point)
                            .allowsHitTesting(false)
                            .accessibilityLabel(
                                CameraRecordingStrings.focusIndicator
                            )
                            .accessibilityIdentifier(
                                "capture.focusIndicator"
                            )
                    }

                    VStack(spacing: 12) {
                        topControls
                        Spacer()
                        statusOverlay
                        bottomControls
                    }
                    .padding()
                }
                .coordinateSpace(name: Self.focusCoordinateSpace)
                .onChange(of: timeline.date) {
                    teleprompterViewModel.tick()
                }
            }
        }
        .background(.black)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            async let scriptLoad: Void = teleprompterViewModel.load()
            async let capturePreparation: Void =
                recordingViewModel.prepare()
            _ = await (scriptLoad, capturePreparation)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                teleprompterViewModel.sceneDidEnterBackground()
                recordingViewModel.sceneDidEnterBackground()
            case .active:
                Task {
                    await teleprompterViewModel.sceneDidBecomeActive()
                }
                recordingViewModel.sceneDidBecomeActive()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
        .onChange(
            of: recordingViewModel.focusAndExposureFeedbackGeneration
        ) {
            clearFocusAndExposureFeedback()
        }
        .onDisappear {
            localRecordingPlayer.close()
            clearFocusAndExposureFeedback()
            teleprompterViewModel.viewDidDisappear()
            Task {
                await recordingViewModel.viewDidDisappear()
            }
        }
        .sheet(
            isPresented: $showsLocalPreview,
            onDismiss: {
                localRecordingPlayer.close()
            }
        ) {
            localPreview
        }
        .alert(
            TeleprompterStrings.errorTitle,
            isPresented: errorBinding
        ) {
            if recordingViewModel.canRetryPreparation {
                Button(CameraRecordingStrings.retry) {
                    Task {
                        await recordingViewModel.retryPreparation()
                    }
                }
            }
            Button(ScriptEditorStrings.dismiss, role: .cancel) {
                recordingViewModel.dismissError()
            }
        } message: {
            Text(recordingViewModel.errorMessage ?? "")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("capture.screen")
    }

    @ViewBuilder
    private var previewLayer: some View {
        if let source = recordingViewModel.previewSource {
            CapturePreviewView(
                source: source,
                mirrored:
                    recordingViewModel.configuration?.previewMirrored
                    == true,
                focusRequest: focusRequest,
                onFocus: handleConvertedFocus,
                onRotationAngleChanged:
                    recordingViewModel.setCaptureRotationAngle
            )
            .ignoresSafeArea()
        } else {
            unavailablePreview
        }
    }

    @ViewBuilder
    private var unavailablePreview: some View {
#if DEBUG
        if recordingViewModel.isFakePreview,
           recordingViewModel.state != .failed(.cameraUnavailable) {
            LinearGradient(
                colors: [.indigo, .black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            .overlay {
                Label(
                    CameraRecordingStrings.fakePreview,
                    systemImage: "video.fill"
                )
                .foregroundStyle(.white.opacity(0.8))
                .accessibilityIdentifier("capture.fakePreview")
            }
        } else {
            Color.black.ignoresSafeArea()
        }
#else
        Color.black.ignoresSafeArea()
#endif
    }

    private func promptText(
        document: TeleprompterDocument,
        in geometry: GeometryProxy
    ) -> some View {
        TeleprompterTextView(
            document: document,
            preferences: teleprompterViewModel.preferences,
            targetOffset: teleprompterViewModel.scrollOffset,
            anchor: teleprompterViewModel.anchor,
            layoutRevision: teleprompterViewModel.layoutRevision,
            foregroundColor: .white,
            onTapped: { pointInWindow in
                handleFocusScreenTap(
                    pointInWindow,
                    in: geometry
                )
            },
            onDragStarted: teleprompterViewModel.beginDragging,
            onDragChanged: teleprompterViewModel.updateDragging,
            onDragEnded: teleprompterViewModel.endDragging,
            onVisibleAnchorChanged:
                teleprompterViewModel.visibleAnchorChanged,
            onLayoutResolved: teleprompterViewModel.layoutResolved
        )
        .frame(
            width: geometry.size.width
                * teleprompterViewModel.preferences.textAreaWidthFraction
        )
        .offset(
            y: geometry.size.height
                * teleprompterViewModel.preferences.verticalPosition
        )
        .scaleEffect(
            x:
                teleprompterViewModel.preferences
                    .isHorizontallyMirrored ? -1 : 1,
            y:
                teleprompterViewModel.preferences
                    .isVerticallyMirrored ? -1 : 1
        )
        .accessibilityIdentifier("capture.teleprompter.text")
    }

    private var topControls: some View {
        HStack(spacing: 12) {
            Button {
                guard !isClosing else {
                    return
                }
                isClosing = true
                Task {
                    await recordingViewModel.viewDidDisappear()
                    dismiss()
                }
            } label: {
                Image(systemName: "xmark")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel(CameraRecordingStrings.close)
            .accessibilityIdentifier("capture.close")
            .disabled(isClosing)

            Spacer()

            Text(recordingStateDescription)
                .font(.headline)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("capture.state")

            Spacer()

            if !recordingViewModel.capabilities.availableFormats.isEmpty {
                Menu {
                    ForEach(
                        recordingViewModel.capabilities.availableFormats
                    ) { format in
                        Button(qualityTitle(format.resolution)) {
                            recordingViewModel.selectResolution(
                                format.resolution
                            )
                        }
                        .disabled(
                            format.resolution
                                == recordingViewModel.selectedResolution
                        )
                    }
                } label: {
                    Text(
                        qualityTitle(
                            recordingViewModel.selectedResolution
                        )
                    )
                    .font(.caption.bold())
                    .frame(minHeight: 44)
                }
                .disabled(recordingViewModel.state != .ready)
                .accessibilityLabel(CameraRecordingStrings.quality)
                .accessibilityIdentifier("capture.quality")
            }

            Button {
                recordingViewModel.switchCamera()
            } label: {
                Image(systemName: "camera.rotate")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .disabled(!recordingViewModel.canSwitchCamera)
            .accessibilityLabel(CameraRecordingStrings.switchCamera)
            .accessibilityValue(
                recordingViewModel.configuration?.position == .back
                    ? CameraRecordingStrings.backCameraActive
                    : CameraRecordingStrings.frontCameraActive
            )
            .accessibilityIdentifier("capture.switchCamera")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }

    @ViewBuilder
    private var statusOverlay: some View {
        if case .starting(let remaining) = recordingViewModel.state {
            Text("\(remaining)")
                .font(.system(size: 88, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .accessibilityLabel(
                    CameraRecordingStrings.recordingCountdown(remaining)
                )
                .accessibilityIdentifier("capture.countdown")
        }

        if case .awaitingRecordingStart = recordingViewModel.state {
            ProgressView(CameraRecordingStrings.startingRecording)
                .tint(.white)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.black.opacity(0.65), in: Capsule())
                .accessibilityIdentifier("capture.startingRecording")
        }

        if recordingViewModel.state.isActivelyRecording {
            VStack(spacing: 4) {
                Text(
                    CameraRecordingStrings.duration(
                        recordingViewModel.recordingDuration
                    )
                )
                .monospacedDigit()
                .font(.title2.bold())
                .accessibilityIdentifier("capture.duration")
                Text(CameraRecordingStrings.directionLocked)
                    .font(.caption)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.red.opacity(0.8), in: Capsule())
        }

        if recordingViewModel.state == .ready
            || recordingViewModel.state.isActivelyRecording {
            Label(
                CameraRecordingStrings.audioInput(
                    recordingViewModel.audioRoute
                ),
                systemImage: recordingViewModel.audioRoute.isBluetooth
                    ? "wave.3.right"
                    : "mic.fill"
            )
            .font(.caption)
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.black.opacity(0.65), in: Capsule())
            .accessibilityIdentifier("capture.audioRoute")
        }

        if let notice = recordingViewModel.noticeMessage {
            Text(notice)
                .font(.subheadline)
                .foregroundStyle(.white)
                .padding(8)
                .background(.black.opacity(0.65), in: Capsule())
                .accessibilityIdentifier("capture.notice")
        }

        if let notice =
            recordingViewModel.focusAndExposureNoticeMessage {
            Text(notice)
                .font(.subheadline)
                .foregroundStyle(.white)
                .padding(8)
                .background(.black.opacity(0.65), in: Capsule())
                .accessibilityIdentifier("capture.focusNotice")
        }

        if recordingViewModel.canRetryPreparation {
            Button(retryButtonTitle) {
                Task {
                    await recordingViewModel.retryPreparation()
                }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("capture.retry")
        }
    }

    private var bottomControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                teleprompterButton
                recordingButton
                focusLockButton
                previewButton
            }
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    teleprompterButton
                    recordingButton
                }
                HStack(spacing: 12) {
                    focusLockButton
                    previewButton
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(CameraRecordingStrings.controls)
    }

    private var teleprompterButton: some View {
        Button {
            teleprompterViewModel.primaryAction()
        } label: {
            Label(
                teleprompterButtonTitle,
                systemImage: teleprompterButtonIcon
            )
            .frame(minWidth: 82, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .tint(.white)
        .disabled(teleprompterViewModel.isEmpty)
        .accessibilityIdentifier("capture.teleprompter.primary")
    }

    private var recordingButton: some View {
        Button {
            switch recordingViewModel.state {
            case .ready:
                recordingViewModel.startRecording()
            case .starting:
                recordingViewModel.cancelCountdown()
            case .awaitingRecordingStart:
                break
            case .recording:
                recordingViewModel.stopRecording()
            default:
                break
            }
        } label: {
            Label(recordButtonTitle, systemImage: recordButtonIcon)
                .frame(minWidth: 92, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .tint(recordingViewModel.state.isActivelyRecording ? .red : .blue)
        .disabled(!isRecordButtonEnabled)
        .accessibilityIdentifier("capture.record")
    }

    private var focusLockButton: some View {
        Button {
            focusLockTask?.cancel()
            focusLockTask = Task {
                await recordingViewModel.toggleFocusAndExposureLock()
            }
        } label: {
            Image(
                systemName:
                    recordingViewModel.isFocusAndExposureLocked
                    ? "viewfinder.circle.fill" : "viewfinder.circle"
            )
            .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .tint(.white)
        .disabled(!recordingViewModel.canToggleFocusAndExposureLock)
        .accessibilityLabel(
            recordingViewModel.isFocusAndExposureLocked
                ? CameraRecordingStrings.focusUnlock
                : CameraRecordingStrings.focusLock
        )
        .accessibilityValue(
            recordingViewModel.isFocusAndExposureLocked
                ? CameraRecordingStrings.focusAndExposureLocked
                : CameraRecordingStrings.focusUnlocked
        )
        .accessibilityIdentifier("capture.focusLock")
    }

    private var previewButton: some View {
        Button {
            guard let recording =
                recordingViewModel.completedRecording
            else {
                return
            }
            localRecordingPlayer.open(recording)
            showsLocalPreview = true
        } label: {
            Image(systemName: "play.rectangle.fill")
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .tint(.white)
        .disabled(recordingViewModel.completedRecording == nil)
        .accessibilityLabel(CameraRecordingStrings.localPreview)
        .accessibilityIdentifier("capture.localPreview")
    }

    @ViewBuilder
    private var localPreview: some View {
        if let recording = recordingViewModel.completedRecording {
            LocalRecordingPreviewView(
                controller: localRecordingPlayer,
                recording: recording,
                usesFakePreview: usesFakeLocalRecordingPreview
            )
        }
    }

    private var usesFakeLocalRecordingPreview: Bool {
#if DEBUG
        recordingViewModel.isFakePreview
#else
        false
#endif
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { recordingViewModel.errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    recordingViewModel.dismissError()
                }
            }
        )
    }

    private func focusTapSurface(
        in geometry: GeometryProxy
    ) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture(
                    count: 1,
                    coordinateSpace: .named(Self.focusCoordinateSpace)
                )
                .onEnded { value in
                    handleFocusTap(
                        at: value.location,
                        in: geometry
                    )
                }
            )
    }

    private func handleFocusTap(
        at localPoint: CGPoint,
        in geometry: GeometryProxy
    ) {
        guard
            !isClosing,
            recordingViewModel.canAdjustFocusAndExposure
        else {
            return
        }
        let globalOrigin = geometry.frame(in: .global).origin
        let request = CaptureFocusRequest(
            id: UUID(),
            screenPoint: CGPoint(
                x: globalOrigin.x + localPoint.x,
                y: globalOrigin.y + localPoint.y
            ),
            indicatorPoint: localPoint
        )
        focusRequest = request

#if DEBUG
        if recordingViewModel.isFakePreview {
            let normalized = NormalizedCapturePoint(
                x: localPoint.x / max(geometry.size.width, 1),
                y: localPoint.y / max(geometry.size.height, 1)
            )
            performFocus(normalized, requestID: request.id)
        }
#endif
    }

    private func handleFocusScreenTap(
        _ screenPoint: CGPoint,
        in geometry: GeometryProxy
    ) {
        let globalOrigin = geometry.frame(in: .global).origin
        let localPoint = CGPoint(
            x: screenPoint.x - globalOrigin.x,
            y: screenPoint.y - globalOrigin.y
        )
        guard CGRect(origin: .zero, size: geometry.size)
            .contains(localPoint)
        else {
            return
        }
        handleFocusTap(at: localPoint, in: geometry)
    }

    private func handleConvertedFocus(
        _ point: NormalizedCapturePoint,
        requestID: UUID
    ) {
        performFocus(point, requestID: requestID)
    }

    private func performFocus(
        _ point: NormalizedCapturePoint,
        requestID: UUID
    ) {
        focusOperationTask?.cancel()
        focusOperationTask = Task {
            let didApply = await recordingViewModel.focus(at: point)
            guard
                didApply,
                focusRequest?.id == requestID,
                let indicatorPoint = focusRequest?.indicatorPoint
            else {
                return
            }
            showFocusIndicator(
                CaptureFocusIndicator(
                    id: requestID,
                    point: indicatorPoint
                )
            )
        }
    }

    private func clearFocusAndExposureFeedback() {
        focusOperationTask?.cancel()
        focusOperationTask = nil
        focusLockTask?.cancel()
        focusLockTask = nil
        focusIndicatorDismissTask?.cancel()
        focusIndicatorDismissTask = nil
        focusRequest = nil
        focusIndicator = nil
    }

    private func showFocusIndicator(
        _ indicator: CaptureFocusIndicator
    ) {
        focusIndicatorDismissTask?.cancel()
        focusIndicator = indicator
        focusIndicatorDismissTask = Task {
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            guard focusIndicator?.id == indicator.id else {
                return
            }
            focusIndicator = nil
        }
    }

    private var needsTeleprompterClock: Bool {
        switch teleprompterViewModel.state {
        case .countingDown, .running:
            true
        default:
            false
        }
    }

    private var isRecordButtonEnabled: Bool {
        switch recordingViewModel.state {
        case .ready, .starting, .recording:
            true
        default:
            false
        }
    }

    private var recordButtonTitle: String {
        switch recordingViewModel.state {
        case .starting:
            TeleprompterStrings.cancelCountdown
        case .awaitingRecordingStart:
            CameraRecordingStrings.startingRecording
        case .recording:
            CameraRecordingStrings.stop
        default:
            CameraRecordingStrings.record
        }
    }

    private var recordButtonIcon: String {
        switch recordingViewModel.state {
        case .starting:
            "xmark.circle.fill"
        case .awaitingRecordingStart:
            "hourglass"
        case .recording:
            "stop.circle.fill"
        default:
            "record.circle"
        }
    }

    private var teleprompterButtonTitle: String {
        switch teleprompterViewModel.state {
        case .running:
            TeleprompterStrings.pause
        case .paused:
            TeleprompterStrings.resume
        case .countingDown:
            TeleprompterStrings.cancelCountdown
        default:
            TeleprompterStrings.start
        }
    }

    private var teleprompterButtonIcon: String {
        switch teleprompterViewModel.state {
        case .running:
            "pause.fill"
        case .countingDown:
            "xmark"
        default:
            "play.fill"
        }
    }

    private var recordingStateDescription: String {
        switch recordingViewModel.state {
        case .idle:
            CameraRecordingStrings.preparing
        case .requestingPermissions:
            "正在检查摄像头和麦克风权限"
        case .configuring:
            CameraRecordingStrings.preparing
        case .ready:
            recordingViewModel.completedRecording == nil
                ? CameraRecordingStrings.ready
                : CameraRecordingStrings.completedAndReady
        case .starting(let seconds):
            "将在 \(seconds) 秒后开始录制"
        case .awaitingRecordingStart:
            CameraRecordingStrings.startingRecording
        case .recording:
            "正在录制"
        case .stopping:
            "正在安全完成录制"
        case .finished:
            "录制已完成"
        case .interrupted(let recordingID, _):
            recordingID == nil
                ? CameraRecordingStrings.cameraInterrupted
                : CameraRecordingStrings.interrupted
        case .recoveryRequired:
            CameraRecordingStrings.interruptionEnded
        case .failed:
            CameraRecordingStrings.unavailable
        }
    }

    private var retryButtonTitle: String {
        if case .recoveryRequired = recordingViewModel.state {
            return CameraRecordingStrings.prepareCameraAgain
        }
        return CameraRecordingStrings.retry
    }

    private func qualityTitle(
        _ resolution: VideoResolution
    ) -> String {
        resolution == .ultraHD4K
            ? CameraRecordingStrings.ultraHD
            : CameraRecordingStrings.fullHD
    }
}

private struct CaptureFocusIndicator: Equatable {
    let id: UUID
    let point: CGPoint
}
