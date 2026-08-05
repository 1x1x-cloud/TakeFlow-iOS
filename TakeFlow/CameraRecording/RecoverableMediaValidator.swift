import AVFoundation
import Foundation

struct AVFoundationRecoverableMediaValidator: RecoverableMediaValidating {
    func validate(
        _ recording: RecoverableRecording
    ) async -> RecoverableMediaValidationResult {
        guard FileManager.default.fileExists(
            atPath: recording.fileURL.path
        ) else {
            return .invalid(.fileMissing)
        }

        let asset = AVURLAsset(url: recording.fileURL)
        do {
            async let durationValue = asset.load(.duration)
            async let playableValue = asset.load(.isPlayable)
            async let videoTracks = asset.loadTracks(withMediaType: .video)
            async let audioTracks = asset.loadTracks(withMediaType: .audio)
            let (duration, isPlayable, videos, audios) = try await (
                durationValue,
                playableValue,
                videoTracks,
                audioTracks
            )
            let seconds = duration.seconds
            guard seconds.isFinite, seconds > 0 else {
                return .invalid(.durationInvalid)
            }
            guard !videos.isEmpty else {
                return .invalid(.videoTrackMissing)
            }
            guard isPlayable else {
                return .invalid(.notPlayable)
            }
            return .playable(
                RecoverableMediaInfo(
                    duration: seconds,
                    hasAudioTrack: !audios.isEmpty
                )
            )
        } catch {
            return .invalid(.containerUnrecognized)
        }
    }
}
