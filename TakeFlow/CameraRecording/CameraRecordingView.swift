import SwiftUI

struct CameraRecordingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var recordingViewModel: CameraRecordingViewModel
    @StateObject private var teleprompterViewModel: TeleprompterViewModel
    @StateObject private var localRecordingPlayer:
        LocalRecordingPlayerController
    @State private var showsLocalPreview = false
    @State private var showsAudioRouteDetails = false
    @State private var selectedRecoverableRecordingID: UUID?
    @State private var isClosing = false
    @State private var focusRequest: CaptureFocusRequest?
    @State private var focusIndicator: CaptureFocusIndicator?
    @State private var focusIndicatorDismissTask: Task<Void, Never>?
    @State private var focusOperationTask: Task<Void, Never>?
    @State private var focusLockTask: Task<Void, Never>?
#if DEBUG
    @State private var recoveryVisibleSafeAreaFrame = CGRect.zero
#endif

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

                    VStack(spacing: cameraOverlaySpacing) {
                        topControls
                            .fixedSize(horizontal: false, vertical: true)
                            .layoutPriority(3)
                        middleOverlayRegion
                            .frame(maxHeight: .infinity)
                            .layoutPriority(1)
                        bottomControls
                            .fixedSize(horizontal: false, vertical: true)
                            .layoutPriority(3)
                    }
                    .padding(cameraOverlayPadding)
                }
                .coordinateSpace(name: Self.focusCoordinateSpace)
                .onChange(of: timeline.date) {
                    teleprompterViewModel.tick()
                }
#if DEBUG
                .onChange(of: geometry.size, initial: true) {
                    updateRecoverySafeAreaFrame(in: geometry)
                }
                .onChange(of: geometry.safeAreaInsets) {
                    updateRecoverySafeAreaFrame(in: geometry)
                }
#endif
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
#if DEBUG
        .onChange(
            of: recordingViewModel.recoverableReviewItems,
            initial: true
        ) { _, items in
            recordingViewModel.recordSwiftUIRecoverableItemsObserved(items)
        }
#endif
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
        .sheet(isPresented: $showsAudioRouteDetails) {
            AudioRouteDetailsView(
                route: recordingViewModel.audioRoute,
                onClose: {
                    showsAudioRouteDetails = false
                }
            )
        }
        .sheet(
            isPresented: recoverableReviewPresented,
            onDismiss: {
                localRecordingPlayer.close()
                selectedRecoverableRecordingID = nil
            }
        ) {
            recoverableReview
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

            if !usesAccessibilityControlLayout {
                Text(recordingStateDescription)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("capture.state")

                Spacer()
            }

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
                    if usesAccessibilityControlLayout {
                        Image(systemName: "rectangle.inset.filled.and.camera")
                            .frame(minWidth: 44, minHeight: 44)
                    } else {
                        Text(
                            qualityTitle(
                                recordingViewModel.selectedResolution
                            )
                        )
                        .font(.caption.bold())
                        .frame(minHeight: 44)
                    }
                }
                .disabled(recordingViewModel.state != .ready)
                .accessibilityLabel(CameraRecordingStrings.quality)
                .accessibilityValue(
                    qualityTitle(recordingViewModel.selectedResolution)
                )
                .accessibilityIdentifier("capture.quality")
            }

            if recordingViewModel.state == .ready
                || recordingViewModel.state.isActivelyRecording {
                audioRouteButton
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

    private var audioRouteButton: some View {
        Button {
            showsAudioRouteDetails = true
        } label: {
            Image(
                systemName: recordingViewModel.audioRoute.isBluetooth
                    ? "wave.3.right"
                    : "mic.fill"
            )
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(CameraRecordingStrings.audioInputDevice)
        .accessibilityValue(
            CameraRecordingStrings.audioInput(recordingViewModel.audioRoute)
        )
        .accessibilityHint(
            CameraRecordingStrings.audioInputAccessibilityHint
        )
        .accessibilityIdentifier("capture.audioRoute")
    }

    @ViewBuilder
    private var middleOverlayRegion: some View {
        if shouldShowRecoveryActionPanel {
            VStack(spacing: usesCompactRecoveryLayout ? 4 : 8) {
                statusRegion(maximumHeight: recoveryStatusMaximumHeight)
                recoveryActionPanel
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        } else {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                statusRegion(maximumHeight: regularStatusMaximumHeight)
                Spacer(minLength: 0)
            }
        }
    }

    private func statusRegion(maximumHeight: CGFloat?) -> some View {
        ScrollView(.vertical) {
            statusOverlay
                .padding(.horizontal, 4)
        }
        .scrollIndicators(.visible)
        .frame(maxWidth: .infinity, maxHeight: maximumHeight)
        .accessibilityIdentifier("capture.statusRegion")
    }

    private var statusOverlay: some View {
        VStack(spacing: 8) {
            if usesAccessibilityControlLayout {
                Text(recordingStateDescription)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.65), in: Capsule())
                    .accessibilityIdentifier("capture.state")
            }

            if case .starting(let remaining) = recordingViewModel.state {
                Text("\(remaining)")
                    .font(
                        .system(size: 88, weight: .bold, design: .rounded)
                    )
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

            if !shouldShowRecoveryActionPanel,
               let notice = recordingViewModel.noticeMessage {
                recoveryNoticeText(
                    notice,
                    identifier: "capture.notice"
                )
            }

            if !shouldShowRecoveryActionPanel,
               let notice = recordingViewModel.interruptionNoticeMessage {
                recoveryNoticeText(
                    notice,
                    identifier: "capture.interruptionNotice"
                )
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

#if DEBUG
            if recordingViewModel.canTriggerInterruptionAndEndForUITesting {
                Button("触发测试中断") {
                    Task {
                        await recordingViewModel
                            .triggerInterruptionAndEndForUITesting()
                    }
                }
                .accessibilityIdentifier(
                    "capture.debugTriggerInterruption"
                )
            }

            if recordingViewModel.isFakePreview {
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityLabel(
                        "活动播放器 "
                            + "\(localRecordingPlayer.activeSessionCount)"
                    )
                    .accessibilityIdentifier(
                        "capture.debugActivePlayerCount"
                    )
            }
#endif
        }
        .frame(maxWidth: .infinity)
    }

    private var shouldShowRecoveryActionPanel: Bool {
        !recordingViewModel.recoverableReviewItems.isEmpty
            || recordingViewModel.shouldShowManualReprepare
    }

    private var usesCompactRecoveryLayout: Bool {
        verticalSizeClass == .compact
    }

    private var usesAccessibilityControlLayout: Bool {
        dynamicTypeSize.isAccessibilitySize
    }

    private var recoveryStatusMaximumHeight: CGFloat {
        usesCompactRecoveryLayout ? 52 : 88
    }

    private var regularStatusMaximumHeight: CGFloat {
        if usesCompactRecoveryLayout {
            return usesAccessibilityControlLayout ? 110 : 96
        }
        return usesAccessibilityControlLayout ? 180 : 150
    }

    private var recoveryMessageMaximumHeight: CGFloat {
        usesCompactRecoveryLayout ? 48 : 76
    }

    private var recoveryCardListHeight: CGFloat {
        if usesCompactRecoveryLayout {
            return usesAccessibilityControlLayout ? 96 : 112
        }
        return usesAccessibilityControlLayout ? 132 : 156
    }

    private var cameraOverlaySpacing: CGFloat {
        usesCompactRecoveryLayout ? 6 : 12
    }

    private var cameraOverlayPadding: CGFloat {
        usesCompactRecoveryLayout ? 8 : 16
    }

    private var recoveryActionPanel: some View {
        VStack(spacing: usesCompactRecoveryLayout ? 4 : 8) {
            recoveryMessages

            if usesCompactRecoveryLayout {
                HStack(alignment: .center, spacing: 8) {
                    if !recordingViewModel
                        .recoverableReviewItems.isEmpty {
                        recoverableRecordingCards
                            .layoutPriority(2)
                    }
                    manualReprepareButton
                        .fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(3)
                }
            } else {
                if !recordingViewModel
                    .recoverableReviewItems.isEmpty {
                    recoverableRecordingCards
                }
                manualReprepareButton
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(
            .black.opacity(0.42),
            in: RoundedRectangle(cornerRadius: 16)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("capture.recoveryActionPanel")
    }

    private var recoveryMessages: some View {
        ScrollView(.vertical) {
            VStack(spacing: 4) {
                if let notice = recordingViewModel.interruptionNoticeMessage {
                    recoveryNoticeText(
                        notice,
                        identifier: "capture.interruptionNotice"
                    )
                }
                if let notice = recordingViewModel.noticeMessage {
                    recoveryNoticeText(
                        notice,
                        identifier: "capture.notice"
                    )
                }
            }
        }
        .scrollIndicators(.visible)
        .frame(maxWidth: .infinity)
        .frame(maxHeight: recoveryMessageMaximumHeight)
        .accessibilityIdentifier("capture.recoveryMessages")
    }

    private func recoveryNoticeText(
        _ notice: String,
        identifier: String
    ) -> some View {
        Text(notice)
            .font(.subheadline)
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier(identifier)
    }

    @ViewBuilder
    private var manualReprepareButton: some View {
        if recordingViewModel.shouldShowManualReprepare {
            Button {
                Task {
                    await recordingViewModel.retryPreparation()
                }
            } label: {
                if usesAccessibilityControlLayout {
                    Image(systemName: "arrow.clockwise")
                        .frame(minWidth: 44, minHeight: 44)
                } else {
                    Label(retryButtonTitle, systemImage: "arrow.clockwise")
                        .frame(minHeight: 44)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!recordingViewModel.canRetryPreparation)
            .accessibilityLabel(retryButtonTitle)
            .accessibilityIdentifier("capture.retry")
        }
    }

    private var bottomControls: some View {
        Group {
            if usesAccessibilityControlLayout {
                HStack(spacing: 8) {
                    teleprompterButton
                    recordingButton
                    focusLockButton
                    previewButton
                }
            } else {
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
            }
        }
        .padding(usesAccessibilityControlLayout ? 6 : 10)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(CameraRecordingStrings.controls)
        .accessibilityIdentifier("capture.controls")
    }

    private var teleprompterButton: some View {
        Button {
            teleprompterViewModel.primaryAction()
        } label: {
            if usesAccessibilityControlLayout {
                Image(systemName: teleprompterButtonIcon)
                    .frame(minWidth: 44, minHeight: 44)
            } else {
                Label(
                    teleprompterButtonTitle,
                    systemImage: teleprompterButtonIcon
                )
                .frame(minWidth: 82, minHeight: 44)
            }
        }
        .buttonStyle(.bordered)
        .tint(.white)
        .disabled(teleprompterViewModel.isEmpty)
        .accessibilityLabel(teleprompterButtonTitle)
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
            if usesAccessibilityControlLayout {
                Image(systemName: recordButtonIcon)
                    .frame(minWidth: 44, minHeight: 44)
            } else {
                Label(recordButtonTitle, systemImage: recordButtonIcon)
                    .frame(minWidth: 92, minHeight: 44)
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(recordingViewModel.state.isActivelyRecording ? .red : .blue)
        .disabled(!isRecordButtonEnabled)
        .accessibilityLabel(recordButtonTitle)
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

    private var recoverableRecordingCards: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(recordingViewModel.recoverableReviewItems) { item in
                    recoverableRecordingCard(item)
                    .padding(10)
                    .frame(maxHeight: .infinity)
                    .containerRelativeFrame(
                        .horizontal,
                        count: recoveryCardsPerViewport,
                        span: 1,
                        spacing: 10
                    )
                    .background(
                        .black.opacity(0.72),
                        in: RoundedRectangle(cornerRadius: 14)
                    )
                    .foregroundStyle(.white)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier(
                        "capture.recoveryCard.\(item.id.uuidString)"
                    )
#if DEBUG
                    .onAppear {
                        recordingViewModel.recordRecoveryCardAppeared(
                            recordingID: item.id
                        )
                    }
                    .background {
                        recoveryCardFrameDiagnostic(item.id)
                    }
#endif
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .frame(maxWidth: .infinity)
        .frame(height: recoveryCardListHeight)
        .accessibilityIdentifier("capture.recoveryList")
    }

    private var recoveryCardsPerViewport: Int {
        horizontalSizeClass == .regular && !usesCompactRecoveryLayout ? 2 : 1
    }

    @ViewBuilder
    private func recoverableRecordingCard(
        _ item: RecoverableRecordingReviewItem
    ) -> some View {
        if usesCompactRecoveryLayout || usesAccessibilityControlLayout {
            HStack(alignment: .center, spacing: 8) {
                ScrollView(.vertical) {
                    recoverableRecordingDetails(item, compact: false)
                }
                .scrollIndicators(.visible)
                .frame(maxHeight: .infinity)
                Spacer(minLength: 4)
                recoverableInspectButton(item)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                recoverableRecordingDetails(item, compact: false)
                recoverableInspectButton(item)
            }
        }
    }

    private func recoverableRecordingDetails(
        _ item: RecoverableRecordingReviewItem,
        compact: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(
                CameraRecordingStrings.recoverableCardTitle,
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.subheadline.bold())
            Text(
                CameraRecordingStrings.recoverableReason(
                    item.recording.reason
                )
            )
            .font(.caption)
            .lineLimit(compact ? 1 : nil)
            Text(
                item.recording.discoveredAt.formatted(
                    date: .abbreviated,
                    time: .shortened
                )
            )
            .font(.caption2)
            .foregroundStyle(.secondary)

            if let message = recoveryCardMessage(item.state) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(compact ? 1 : nil)
            }
        }
    }

    private func recoverableInspectButton(
        _ item: RecoverableRecordingReviewItem
    ) -> some View {
        Button {
            inspectRecoverable(item.id)
        } label: {
            if item.state == .validating {
                if usesAccessibilityControlLayout {
                    ProgressView()
                        .frame(minWidth: 44, minHeight: 44)
                } else {
                    ProgressView(CameraRecordingStrings.validatingRecoverable)
                }
            } else if usesAccessibilityControlLayout {
                Image(systemName: "magnifyingglass")
                    .frame(minWidth: 44, minHeight: 44)
            } else {
                Text(CameraRecordingStrings.inspectRecoverable)
                    .frame(minHeight: 44)
            }
        }
        .buttonStyle(.borderedProminent)
        .fixedSize(horizontal: true, vertical: false)
        .disabled(recoveryCardIsBusy(item.state))
        .accessibilityLabel(
            item.state == .validating
                ? CameraRecordingStrings.validatingRecoverable
                : CameraRecordingStrings.inspectRecoverable
        )
        .accessibilityIdentifier(
            "capture.recoveryInspect.\(item.id.uuidString)"
        )
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

    @ViewBuilder
    private var recoverableReview: some View {
        if let recordingID = selectedRecoverableRecordingID,
           let item = recordingViewModel.recoverableItem(
            recordingID: recordingID
           ) {
            RecoverableRecordingReviewView(
                controller: localRecordingPlayer,
                item: item,
                usesFakePreview: usesFakeLocalRecordingPreview,
                onRetain: {
                    await recordingViewModel.retainRecoverableRecording(
                        recordingID: recordingID
                    )
                },
                onDelete: {
                    await recordingViewModel.deleteRecoverableRecording(
                        recordingID: recordingID
                    )
                }
            )
        }
    }

    private var recoverableReviewPresented: Binding<Bool> {
        Binding(
            get: { selectedRecoverableRecordingID != nil },
            set: { isPresented in
                if !isPresented {
                    selectedRecoverableRecordingID = nil
                }
            }
        )
    }

    private func inspectRecoverable(_ recordingID: UUID) {
        Task {
            _ = await recordingViewModel.validateRecoverableRecording(
                recordingID: recordingID
            )
            guard recordingViewModel.recoverableItem(
                recordingID: recordingID
            ) != nil else {
                return
            }
            selectedRecoverableRecordingID = recordingID
        }
    }

    private func recoveryCardIsBusy(
        _ state: RecoverableRecordingReviewState
    ) -> Bool {
        switch state {
        case .validating, .retaining, .deleting:
            true
        default:
            false
        }
    }

    private func recoveryCardMessage(
        _ state: RecoverableRecordingReviewState
    ) -> String? {
        switch state {
        case .damaged(let failure):
            CameraRecordingStrings.recoverableValidationMessage(failure)
        case .retained:
            CameraRecordingStrings.recoverableRetained
        case .operationFailed(let message, _):
            message
        default:
            nil
        }
    }

#if DEBUG
    private func updateRecoverySafeAreaFrame(in geometry: GeometryProxy) {
        let frame = geometry.frame(in: .global)
        let insets = geometry.safeAreaInsets
        recoveryVisibleSafeAreaFrame = CGRect(
            x: frame.minX + insets.leading,
            y: frame.minY + insets.top,
            width: max(0, frame.width - insets.leading - insets.trailing),
            height: max(0, frame.height - insets.top - insets.bottom)
        )
    }

    private func recoveryCardFrameDiagnostic(
        _ recordingID: UUID
    ) -> some View {
        GeometryReader { geometry in
            let globalFrame = geometry.frame(in: .global)
            Color.clear
                .allowsHitTesting(false)
                .onChange(of: globalFrame, initial: true) { _, frame in
                    recordingViewModel.recordRecoveryCardFrame(
                        recordingID: recordingID,
                        globalFrame: frame,
                        safeAreaFrame: recoveryVisibleSafeAreaFrame
                    )
                }
                .onChange(of: recoveryVisibleSafeAreaFrame) { _, safeFrame in
                    recordingViewModel.recordRecoveryCardFrame(
                        recordingID: recordingID,
                        globalFrame: globalFrame,
                        safeAreaFrame: safeFrame
                    )
                }
        }
    }
#endif

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
        if recordingViewModel.requiresManualReprepare
            || {
                if case .recoveryRequired = recordingViewModel.state {
                    return true
                }
                return false
            }() {
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

private struct AudioRouteDetailsView: View {
    let route: AudioInputRoute
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 16) {
                    Label(
                        CameraRecordingStrings.audioInput(route),
                        systemImage: route.isBluetooth
                            ? "wave.3.right"
                            : "mic.fill"
                    )
                    .font(.title3.bold())
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("capture.audioRouteName")

                    Text(CameraRecordingStrings.audioInputExplanation)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .scrollIndicators(.visible)
            .navigationTitle(CameraRecordingStrings.audioInputDevice)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(CameraRecordingStrings.audioInputDetailsDone) {
                        onClose()
                    }
                    .accessibilityIdentifier("capture.audioRouteDone")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("capture.audioRouteDetails")
    }
}

private struct CaptureFocusIndicator: Equatable {
    let id: UUID
    let point: CGPoint
}
