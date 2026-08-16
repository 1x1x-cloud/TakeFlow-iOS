import Foundation

enum SpeechAuthorizationState: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
    case restricted
}

struct OnDeviceSpeechCapability: Equatable, Sendable {
    let localeIdentifier: String
    let isSupported: Bool
    let isAvailable: Bool
}

/// Framework-neutral input for a later iOS 17 recognizer adapter. The
/// on-device requirement is an invariant rather than a caller preference.
struct SpeechRecognitionConfiguration: Equatable, Sendable {
    let localeIdentifier: String
    let requiresOnDeviceRecognition = true

    init(localeIdentifier: String = "zh-CN") {
        self.localeIdentifier = localeIdentifier
    }
}

/// Ephemeral PCM owned by one recognition task. 4D will enforce the frozen
/// two-second aggregate buffer limit and lifecycle cleanup rules.
struct TransientSpeechAudioFrame: Equatable, Sendable {
    let sequence: UInt64
    let sampleRate: Double
    let channelCount: Int
    let samples: [Float]
}

struct SpeechAudioSourceIdentity: Equatable, Sendable {
    let sourceID: UUID
    let captureSessionID: UUID?
    let generation: UInt64
}

/// A transient hypothesis only. No implementation may persist or log text.
struct TransientSpeechRecognitionResult: Equatable, Sendable {
    let generation: UInt64
    let sequence: UInt64
    let transcript: String
    let isFinal: Bool
}

enum VoiceTrackingAccess: Equatable, Sendable {
    case allowed
    case unavailable
}

enum VoiceTrackingUsageEvent: Equatable, Sendable {
    case sessionStarted
    case sessionEnded
}

struct SpeechNormalizationResult: Equatable, Sendable {
    let sourceRange: CharacterRange
    let normalizedUnits: [NormalizedSpeechUnit]
}

protocol SpeechTextNormalizing: Sendable {
    func normalize(
        _ text: String,
        sourceStart: CharacterAnchor,
        unitStart: Int
    ) throws -> SpeechNormalizationResult
}

protocol SpeechDocumentIndexing: Sendable {
    func makeIndex(
        segments: [SpeechSegment],
        sourceCharacterCount: Int,
        policy: SpeechIndexPolicy
    ) throws -> SpeechDocumentIndex
}

protocol SpeechDocumentBuilding: Sendable {
    func buildDocument(
        from content: String,
        contentRevision: UInt64?
    ) async throws -> SpeechDocumentBuildResult
}

protocol SpeechCandidateProviding: Sendable {
    func candidateWindow(
        in document: SpeechDocument,
        around anchor: CharacterAnchor
    ) -> SpeechCandidateWindow

    func relocationCandidates(
        in document: SpeechDocument,
        for nGrams: [SpeechNGram]
    ) -> [SpeechSegment]
}

/// A later matcher may propose a layout-independent anchor, but it never owns
/// scrolling or mutates the teleprompter state machine directly.
protocol SpeechAnchorProposing: Sendable {
    func proposeAnchor(
        in document: SpeechDocument,
        from candidateWindow: SpeechCandidateWindow
    ) async throws -> CharacterAnchor?
}

protocol SpeechRecognitionAuthorizing: Sendable {
    func authorizationState() async -> SpeechAuthorizationState
    func requestAuthorization() async -> SpeechAuthorizationState
}

protocol OnDeviceSpeechRecognizing: Sendable {
    func capability(
        for localeIdentifier: String
    ) async -> OnDeviceSpeechCapability

    func results(
        configuration: SpeechRecognitionConfiguration,
        audio: AsyncThrowingStream<TransientSpeechAudioFrame, any Error>
    ) async throws -> AsyncThrowingStream<
        TransientSpeechRecognitionResult,
        any Error
    >

    func cancel(generation: UInt64) async
}

protocol SpeechAudioSource: Sendable {
    func identity() async -> SpeechAudioSourceIdentity

    func frames() async throws -> AsyncThrowingStream<
        TransientSpeechAudioFrame,
        any Error
    >

    func stop() async
}

protocol VoiceTrackingAccessChecking: Sendable {
    func access() async -> VoiceTrackingAccess
}

/// Non-content session boundary only. No quota, StoreKit, or persistence is
/// implemented in 4B.
protocol VoiceTrackingUsageObserving: Sendable {
    func observe(_ event: VoiceTrackingUsageEvent) async
}

struct IndexedSpeechCandidateProvider: SpeechCandidateProviding {
    func candidateWindow(
        in document: SpeechDocument,
        around requestedAnchor: CharacterAnchor
    ) -> SpeechCandidateWindow {
        let anchor = document.clampedAnchor(requestedAnchor)
        guard let center = document.index.segmentOrdinal(
            atOrFollowing: anchor
        ) else {
            return SpeechCandidateWindow(
                requestedAnchor: anchor,
                centerSegmentOrdinal: nil,
                segments: []
            )
        }
        let lower = max(
            0,
            center - document.index.policy.previousSegmentCount
        )
        let upper = min(
            document.segments.count,
            center + document.index.policy.followingSegmentCount + 1
        )
        return SpeechCandidateWindow(
            requestedAnchor: anchor,
            centerSegmentOrdinal: center,
            segments: Array(document.segments[lower..<upper])
        )
    }

    func relocationCandidates(
        in document: SpeechDocument,
        for nGrams: [SpeechNGram]
    ) -> [SpeechSegment] {
        document.index.relocationSegmentOrdinals(for: nGrams).compactMap {
            document.segments.indices.contains($0)
                ? document.segments[$0]
                : nil
        }
    }
}
