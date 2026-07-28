import Foundation
import SwiftUI

@MainActor
final class TeleprompterViewModel: ObservableObject {
    @Published private(set) var script: Script?
    @Published private(set) var document: TeleprompterDocument?
    @Published private(set) var state: TeleprompterState = .idle
    @Published private(set) var scrollOffset = 0.0
    @Published private(set) var anchor = ScriptReadingAnchor(
        characterOffset: 0
    )
    @Published private(set) var preferences = TeleprompterPreferences()
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published var areControlsVisible = true
    @Published private(set) var layoutRevision = 0

    private let scriptID: UUID
    private let service: any TeleprompterScriptProviding
    private let clock = ContinuousClock()
    private let clockOrigin: ContinuousClock.Instant
    private var machine = TeleprompterPlaybackMachine(
        scrollSpeedPointsPerSecond:
            TeleprompterPreferences.defaultScrollSpeed
    )
    private var persistenceTask: Task<Void, Never>?
    private var didPersistFinishedState = false

    init(
        scriptID: UUID,
        service: any TeleprompterScriptProviding
    ) {
        self.scriptID = scriptID
        self.service = service
        clockOrigin = clock.now
    }

    deinit {
        persistenceTask?.cancel()
    }

    var content: String {
        script?.content ?? ""
    }

    var isEmpty: Bool {
        !(document?.hasReadableContent ?? false)
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let loaded = try await service.teleprompterScript(id: scriptID)
            let indexedDocument = await Self.prepareDocument(
                content: loaded.content
            )
            install(loaded, document: indexedDocument)
        } catch {
            present(error)
        }
    }

    func reload() async {
        await load()
    }

    func tick() {
        machine.tick(at: monotonicTime())
        synchronizeFromMachine()
        if state == .finished, !didPersistFinishedState {
            didPersistFinishedState = true
            schedulePersistence(immediate: true)
        }
    }

    func primaryAction() {
        let now = monotonicTime()
        switch state {
        case .idle, .finished:
            if state == .finished {
                machine.restart()
            }
            machine.start(
                at: now,
                countdownSeconds: preferences.countdownSeconds,
                hasReadableContent: !isEmpty
            )
        case .running:
            machine.pause(at: now)
            schedulePersistence(immediate: true)
        case .paused:
            machine.resume(at: now)
        case .countingDown:
            machine.cancelCountdown()
        case .userDragging, .error:
            break
        }
        synchronizeFromMachine()
    }

    func restart() {
        machine.restart()
        didPersistFinishedState = false
        synchronizeFromMachine()
        schedulePersistence(immediate: true)
    }

    func beginDragging() {
        machine.beginDragging(at: monotonicTime())
        synchronizeFromMachine()
    }

    func updateDragging(
        offset: Double,
        characterOffset: Int
    ) {
        machine.updateDrag(
            offset: offset,
            anchor: ScriptReadingAnchor(
                characterOffset: characterOffset
            ).clamped(toCharacterCount: documentCharacterCount)
        )
        synchronizeFromMachine()
    }

    func endDragging(
        offset: Double,
        characterOffset: Int
    ) {
        machine.endDragging(
            at: monotonicTime(),
            offset: offset,
            anchor: ScriptReadingAnchor(
                characterOffset: characterOffset
            ).clamped(toCharacterCount: documentCharacterCount)
        )
        synchronizeFromMachine()
        schedulePersistence(immediate: true)
    }

    func visibleAnchorChanged(characterOffset: Int) {
        machine.updateVisibleAnchor(
            ScriptReadingAnchor(
                characterOffset: characterOffset
            ).clamped(toCharacterCount: documentCharacterCount)
        )
        anchor = machine.anchor
    }

    func layoutResolved(
        maximumOffset: Double,
        restoredOffset: Double,
        characterOffset: Int
    ) {
        machine.updateLayout(
            maximumOffset: maximumOffset,
            restoredOffset: restoredOffset,
            anchor: ScriptReadingAnchor(
                characterOffset: characterOffset
            ).clamped(toCharacterCount: documentCharacterCount)
        )
        synchronizeFromMachine()
    }

    func updatePreferences(
        _ transform: (inout TeleprompterPreferences) -> Void
    ) {
        var updated = preferences
        transform(&updated)
        updated = TeleprompterPreferences(
            fontSize: updated.fontSize,
            lineSpacing: updated.lineSpacing,
            scrollSpeedPointsPerSecond:
                updated.scrollSpeedPointsPerSecond,
            horizontalMargin: updated.horizontalMargin,
            textAreaWidthFraction: updated.textAreaWidthFraction,
            verticalPosition: updated.verticalPosition,
            appearance: updated.appearance,
            isHorizontallyMirrored:
                updated.isHorizontallyMirrored,
            isVerticallyMirrored: updated.isVerticallyMirrored,
            countdownSeconds: updated.countdownSeconds
        )

        let now = monotonicTime()
        machine.updateScrollSpeed(
            updated.scrollSpeedPointsPerSecond,
            at: now
        )
        preferences = updated
        layoutRevision += 1
        synchronizeFromMachine()
        schedulePersistence(immediate: false)
    }

    func sceneDidEnterBackground() {
        persistenceTask?.cancel()
        machine.enterBackground(at: monotonicTime())
        synchronizeFromMachine()
        schedulePersistence(immediate: true)
    }

    func sceneDidBecomeActive() async {
        machine.returnToForeground(at: monotonicTime())
        synchronizeFromMachine()

        do {
            let latest = try await service.teleprompterScript(id: scriptID)
            guard let script else {
                let indexedDocument = await Self.prepareDocument(
                    content: latest.content
                )
                install(latest, document: indexedDocument)
                return
            }
            guard latest.content == script.content else {
                document = nil
                machine.fail(.scriptChangedDuringTeleprompter)
                synchronizeFromMachine()
                errorMessage =
                    AppError.scriptChangedDuringTeleprompter.errorDescription
                return
            }
            self.script = latest
        } catch {
            present(error)
        }
    }

    func viewDidDisappear() {
        schedulePersistence(immediate: true)
    }

    func dismissError() {
        errorMessage = nil
    }

    private func install(
        _ loaded: Script,
        document: TeleprompterDocument
    ) {
        script = loaded
        self.document = document
        preferences = TeleprompterPreferences(script: loaded)
        anchor = ScriptReadingAnchor(
            characterOffset: loaded.lastReadPosition
        ).clamped(toCharacterCount: document.characterCount)
        machine = TeleprompterPlaybackMachine(
            scrollSpeedPointsPerSecond:
                preferences.scrollSpeedPointsPerSecond
        )
        machine.configure(
            initialAnchor: anchor,
            maximumOffset: 0
        )
        if isEmpty {
            machine.fail(.emptyScript)
        }
        errorMessage = nil
        didPersistFinishedState = false
        layoutRevision += 1
        synchronizeFromMachine()
    }

    private func schedulePersistence(immediate: Bool) {
        guard script != nil else {
            return
        }
        persistenceTask?.cancel()
        let delay = immediate ? Duration.zero : .milliseconds(300)
        let anchor = machine.anchor
        let preferences = preferences

        persistenceTask = Task { [weak self, service, scriptID] in
            do {
                if delay != .zero {
                    try await Task.sleep(for: delay)
                }
                try Task.checkCancellation()
                let saved = try await service.saveTeleprompterState(
                    scriptID: scriptID,
                    anchor: anchor,
                    preferences: preferences
                )
                guard !Task.isCancelled else {
                    return
                }
                self?.script = saved
            } catch is CancellationError {
                return
            } catch {
                self?.present(error)
            }
        }
    }

    private func synchronizeFromMachine() {
        state = machine.state
        scrollOffset = machine.scrollOffset
        anchor = machine.anchor
    }

    private var documentCharacterCount: Int {
        document?.characterCount ?? 0
    }

    private func monotonicTime() -> TimeInterval {
        let duration = clockOrigin.duration(to: clock.now)
        let components = duration.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1e18
    }

    private func present(_ error: Error) {
        let appError = error as? AppError ?? .persistenceUnavailable
        machine.fail(appError)
        synchronizeFromMachine()
        errorMessage = appError.errorDescription
    }

    private nonisolated static func prepareDocument(
        content: String
    ) async -> TeleprompterDocument {
        await Task.detached(priority: .userInitiated) {
            TeleprompterDocument(content: content)
        }.value
    }
}
