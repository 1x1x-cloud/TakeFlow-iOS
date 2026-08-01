import AVKit
import SwiftUI
import UIKit

enum LocalRecordingPlaybackState: Equatable {
    case inactive
    case paused
    case waiting
    case playing
    case ended
    case failed

    var isActivelyPlaying: Bool {
        self == .playing || self == .waiting
    }
}

enum LocalRecordingPhotoSaveState: Equatable {
    case idle
    case saving
    case saved
    case permissionDenied
    case failed

    var statusMessage: String? {
        switch self {
        case .idle:
            nil
        case .saving:
            CameraRecordingStrings.savingToPhotos
        case .saved:
            CameraRecordingStrings.savedToPhotos
        case .permissionDenied:
            CaptureError.photoPermissionDenied.errorDescription
        case .failed:
            CaptureError.photoSaveFailed.errorDescription
        }
    }

    var buttonTitle: String {
        switch self {
        case .idle:
            CameraRecordingStrings.saveToPhotos
        case .saving:
            CameraRecordingStrings.savingToPhotos
        case .saved:
            CameraRecordingStrings.saved
        case .permissionDenied, .failed:
            CameraRecordingStrings.retrySaveToPhotos
        }
    }

    var allowsSaveRequest: Bool {
        switch self {
        case .idle, .permissionDenied, .failed:
            true
        case .saving, .saved:
            false
        }
    }
}

@MainActor
protocol LocalRecordingPlaybackSession: AnyObject {
    var player: AVPlayer? { get }
    var state: LocalRecordingPlaybackState { get }
    var stateDidChange:
        ((LocalRecordingPlaybackState) -> Void)? { get set }

    func play()
    func pause()
    func release()
}

@MainActor
protocol LocalRecordingPlayerCreating {
    func makeSession(
        for fileURL: URL
    ) -> any LocalRecordingPlaybackSession
}

@MainActor
struct SystemLocalRecordingPlayerFactory:
    LocalRecordingPlayerCreating
{
    func makeSession(
        for fileURL: URL
    ) -> any LocalRecordingPlaybackSession {
        SystemLocalRecordingPlaybackSession(fileURL: fileURL)
    }
}

@MainActor
final class LocalRecordingPlayerController: ObservableObject {
    @Published private(set)
    var playbackState: LocalRecordingPlaybackState = .inactive
    @Published private(set) var recordingID: UUID?
    @Published private(set) var fileURL: URL?
#if DEBUG
    @Published private(set) var sessionCreationCount = 0
#endif
    @Published private(set)
    var photoSaveState: LocalRecordingPhotoSaveState = .idle

    private let factory: any LocalRecordingPlayerCreating
    private let photos: any PhotoLibrarySaving
    private var session: (any LocalRecordingPlaybackSession)?
    private var sessionGeneration: UInt64 = 0
    private var photoSaveGeneration: UInt64 = 0
    private var photoSaveTask: Task<Void, Never>?

    init(
        factory: any LocalRecordingPlayerCreating,
        photos: any PhotoLibrarySaving = SystemPhotoLibraryService()
    ) {
        self.factory = factory
        self.photos = photos
    }

    convenience init() {
        self.init(
            factory: SystemLocalRecordingPlayerFactory(),
            photos: SystemPhotoLibraryService()
        )
    }

    var player: AVPlayer? {
        session?.player
    }

    var activeSessionCount: Int {
        session == nil ? 0 : 1
    }

    var canControlPlayback: Bool {
        session != nil
            && playbackState != .failed
            && photoSaveState != .saving
    }

    var canSaveToPhotos: Bool {
        session != nil && photoSaveState.allowsSaveRequest
    }

    func open(_ recording: CompletedRecording) {
        let normalizedURL = recording.fileURL.standardizedFileURL
        guard
            session == nil
                || recordingID != recording.recordingID
                || fileURL != normalizedURL
        else {
            return
        }

        invalidatePhotoSave()
        releaseCurrentSession()
        sessionGeneration &+= 1
        let generation = sessionGeneration
        let newSession = factory.makeSession(for: normalizedURL)
        newSession.stateDidChange = { [weak self] state in
            guard
                let self,
                generation == self.sessionGeneration
            else {
                return
            }
            self.playbackState = state
        }
        session = newSession
        recordingID = recording.recordingID
        fileURL = normalizedURL
        playbackState = newSession.state
#if DEBUG
        sessionCreationCount += 1
#endif
    }

    func togglePlayback() {
        guard let session else {
            return
        }
        if playbackState.isActivelyPlaying {
            session.pause()
        } else {
            session.play()
        }
    }

    func pauseForExternalAction() {
        session?.pause()
    }

    func saveToPhotos() {
        guard
            canSaveToPhotos,
            let recordingID,
            let fileURL
        else {
            return
        }

        session?.pause()
        photoSaveGeneration &+= 1
        let generation = photoSaveGeneration
        photoSaveState = .saving
        let photos = self.photos
        photoSaveTask = Task { [weak self] in
            let result = await photos.saveVideo(at: fileURL)
            guard
                !Task.isCancelled,
                let self,
                generation == self.photoSaveGeneration,
                recordingID == self.recordingID,
                fileURL == self.fileURL
            else {
                return
            }

            self.photoSaveTask = nil
            self.session?.pause()
            self.photoSaveState =
                switch result {
                case .saved:
                    .saved
                case .permissionDenied:
                    .permissionDenied
                case .failed:
                    .failed
                }
        }
    }

#if DEBUG
    func completeFakePhotoSaveForUITesting() {
        guard let photos = photos as? FakePhotoLibraryService else {
            return
        }
        Task {
            await photos.completeNextSave(with: .saved)
        }
    }
#endif

    func close() {
        invalidatePhotoSave()
        releaseCurrentSession()
        recordingID = nil
        fileURL = nil
        playbackState = .inactive
    }

    private func releaseCurrentSession() {
        sessionGeneration &+= 1
        session?.stateDidChange = nil
        session?.pause()
        session?.release()
        session = nil
    }

    private func invalidatePhotoSave() {
        photoSaveGeneration &+= 1
        photoSaveTask?.cancel()
        photoSaveTask = nil
        photoSaveState = .idle
    }
}

@MainActor
private final class SystemLocalRecordingPlaybackSession:
    LocalRecordingPlaybackSession
{
    let player: AVPlayer?
    private(set) var state: LocalRecordingPlaybackState = .paused
    var stateDidChange: ((LocalRecordingPlaybackState) -> Void)?

    private var timeControlObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    private var playbackEndedObserver: NSObjectProtocol?
    private var isReleased = false

    init(fileURL: URL) {
        let item = AVPlayerItem(url: fileURL)
        let player = AVPlayer(playerItem: item)
        self.player = player

        timeControlObservation = player.observe(
            \.timeControlStatus,
            options: [.initial, .new]
        ) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.refreshStateFromPlayer()
            }
        }
        itemStatusObservation = item.observe(
            \.status,
            options: [.initial, .new]
        ) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.refreshStateFromPlayer()
            }
        }
        playbackEndedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.publish(.ended)
            }
        }
        refreshStateFromPlayer()
    }

    func play() {
        guard !isReleased, let player, player.currentItem != nil else {
            return
        }
        if state == .ended {
            player.seek(to: .zero)
        }
        player.play()
        refreshStateFromPlayer()
    }

    func pause() {
        guard !isReleased else {
            return
        }
        player?.pause()
        refreshStateFromPlayer()
    }

    func release() {
        guard !isReleased else {
            return
        }
        player?.pause()
        timeControlObservation?.invalidate()
        itemStatusObservation?.invalidate()
        timeControlObservation = nil
        itemStatusObservation = nil
        if let playbackEndedObserver {
            NotificationCenter.default.removeObserver(playbackEndedObserver)
        }
        playbackEndedObserver = nil
        player?.replaceCurrentItem(with: nil)
        isReleased = true
        publish(.inactive)
        stateDidChange = nil
    }

    private func refreshStateFromPlayer() {
        guard !isReleased, let player else {
            publish(.inactive)
            return
        }
        if player.currentItem?.status == .failed {
            publish(.failed)
            return
        }
        let newState: LocalRecordingPlaybackState =
            switch player.timeControlStatus {
            case .paused:
                state == .ended ? .ended : .paused
            case .waitingToPlayAtSpecifiedRate:
                .waiting
            case .playing:
                .playing
            @unknown default:
                .paused
            }
        publish(newState)
    }

    private func publish(_ newState: LocalRecordingPlaybackState) {
        guard state != newState else {
            return
        }
        state = newState
        stateDidChange?(newState)
    }
}

#if DEBUG
@MainActor
final class FakeLocalRecordingPlayerFactory:
    LocalRecordingPlayerCreating
{
    func makeSession(
        for fileURL: URL
    ) -> any LocalRecordingPlaybackSession {
        FakeLocalRecordingPlaybackSession()
    }
}

@MainActor
private final class FakeLocalRecordingPlaybackSession:
    LocalRecordingPlaybackSession
{
    let player: AVPlayer? = nil
    private(set) var state: LocalRecordingPlaybackState = .paused
    var stateDidChange: ((LocalRecordingPlaybackState) -> Void)?
    private var isReleased = false

    func play() {
        guard !isReleased else {
            return
        }
        publish(.playing)
    }

    func pause() {
        guard !isReleased else {
            return
        }
        publish(.paused)
    }

    func release() {
        guard !isReleased else {
            return
        }
        isReleased = true
        publish(.inactive)
        stateDidChange = nil
    }

    private func publish(_ newState: LocalRecordingPlaybackState) {
        state = newState
        stateDidChange?(newState)
    }
}
#endif

struct LocalRecordingPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var controller: LocalRecordingPlayerController

    let recording: CompletedRecording
    let usesFakePreview: Bool

    @State private var showsShareSheet = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityLabel(
                        CameraRecordingStrings.localPreview
                    )
                    .accessibilityIdentifier("capture.previewScreen")

                playerSurface

                Button {
                    controller.togglePlayback()
                } label: {
                    Label(
                        playbackButtonTitle,
                        systemImage:
                            controller.playbackState.isActivelyPlaying
                            ? "pause.fill" : "play.fill"
                    )
                }
                .buttonStyle(.bordered)
                .disabled(!controller.canControlPlayback)
                .accessibilityLabel(playbackButtonTitle)
                .accessibilityValue(playbackStateDescription)
                .accessibilityIdentifier("capture.previewPlayback")

                if let photoSaveStatus =
                    controller.photoSaveState.statusMessage {
                    Label(
                        photoSaveStatus,
                        systemImage: photoSaveStatusIcon
                    )
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(photoSaveStatusColor)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(photoSaveStatus)
                    .accessibilityIdentifier(
                        "capture.photoSaveStatus"
                    )
                }

                HStack {
                    Button {
                        controller.saveToPhotos()
                    } label: {
                        HStack(spacing: 8) {
                            if controller.photoSaveState == .saving {
                                ProgressView()
                                    .accessibilityHidden(true)
                            }
                            Text(controller.photoSaveState.buttonTitle)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!controller.canSaveToPhotos)
                    .accessibilityLabel(
                        controller.photoSaveState.buttonTitle
                    )
                    .accessibilityValue(
                        controller.photoSaveState.statusMessage ?? ""
                    )
                    .accessibilityIdentifier("capture.savePhotos")

                    Button {
                        controller.pauseForExternalAction()
                        showsShareSheet = true
                    } label: {
                        Label(
                            CameraRecordingStrings.share,
                            systemImage: "square.and.arrow.up"
                        )
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("capture.share")
                }

#if DEBUG
                if usesFakePreview,
                   controller.photoSaveState == .saving {
                    Button("完成照片保存测试") {
                        controller.completeFakePhotoSaveForUITesting()
                    }
                    .accessibilityIdentifier(
                        "capture.completePhotoSave"
                    )
                }

                Text(
                    "活动播放器 \(controller.activeSessionCount)，"
                        + "已创建 \(controller.sessionCreationCount)"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("capture.previewPlayerMetrics")
#endif
            }
            .padding()
            .navigationTitle(CameraRecordingStrings.localPreview)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(CameraRecordingStrings.previewClose) {
                        controller.close()
                        dismiss()
                    }
                    .accessibilityIdentifier("capture.previewClose")
                }
            }
        }
        .onAppear {
            controller.open(recording)
        }
        .onChange(of: recording) { _, newRecording in
            controller.open(newRecording)
        }
        .sheet(isPresented: $showsShareSheet) {
            LocalRecordingActivityView(
                activityItems: [recording.fileURL]
            )
        }
        .onChange(of: showsShareSheet) { _, isPresented in
            if !isPresented {
                controller.pauseForExternalAction()
            }
        }
        .onChange(of: controller.photoSaveState) {
            guard
                let message =
                    controller.photoSaveState.statusMessage
            else {
                return
            }
            UIAccessibility.post(
                notification: .announcement,
                argument: message
            )
        }
    }

    @ViewBuilder
    private var playerSurface: some View {
#if DEBUG
        if usesFakePreview {
            VStack(spacing: 12) {
                Label(
                    CameraRecordingStrings.localPreview,
                    systemImage: "checkmark.circle"
                )
                .font(.title2.bold())
                Text(CameraRecordingStrings.fakePreview)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: 240)
        } else {
            systemPlayerSurface
        }
#else
        systemPlayerSurface
#endif
    }

    @ViewBuilder
    private var systemPlayerSurface: some View {
        if let player = controller.player {
            VideoPlayer(player: player)
                .aspectRatio(9 / 16, contentMode: .fit)
        } else {
            ContentUnavailableView(
                CameraRecordingStrings.previewUnavailable,
                systemImage: "video.slash"
            )
        }
    }

    private var playbackButtonTitle: String {
        controller.playbackState.isActivelyPlaying
            ? CameraRecordingStrings.pausePreview
            : CameraRecordingStrings.playPreview
    }

    private var playbackStateDescription: String {
        switch controller.playbackState {
        case .inactive:
            CameraRecordingStrings.previewInactive
        case .paused:
            CameraRecordingStrings.previewPaused
        case .waiting:
            CameraRecordingStrings.previewWaiting
        case .playing:
            CameraRecordingStrings.previewPlaying
        case .ended:
            CameraRecordingStrings.previewEnded
        case .failed:
            CameraRecordingStrings.previewUnavailable
        }
    }

    private var photoSaveStatusIcon: String {
        switch controller.photoSaveState {
        case .idle:
            "photo"
        case .saving:
            "arrow.down.circle"
        case .saved:
            "checkmark.circle.fill"
        case .permissionDenied, .failed:
            "exclamationmark.triangle.fill"
        }
    }

    private var photoSaveStatusColor: Color {
        switch controller.photoSaveState {
        case .idle, .saving:
            .secondary
        case .saved:
            .green
        case .permissionDenied, .failed:
            .orange
        }
    }
}

private struct LocalRecordingActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(
        context: Context
    ) -> UIActivityViewController {
        UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: nil
        )
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}
}
