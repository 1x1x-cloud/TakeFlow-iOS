import Foundation

struct CharacterAnchor: Hashable, Comparable, Sendable {
    let offset: Int

    init(offset: Int) {
        self.offset = max(0, offset)
    }

    init(_ readingAnchor: ScriptReadingAnchor) {
        self.init(offset: readingAnchor.characterOffset)
    }

    var readingAnchor: ScriptReadingAnchor {
        ScriptReadingAnchor(characterOffset: offset)
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.offset < rhs.offset
    }
}

/// A half-open range of Swift extended-grapheme-cluster offsets.
struct CharacterRange: Hashable, Sendable {
    let start: Int
    let end: Int

    init(start: Int, end: Int) {
        let safeStart = max(0, start)
        self.start = safeStart
        self.end = max(safeStart, end)
    }

    var count: Int {
        end - start
    }

    var range: Range<Int> {
        start..<end
    }

    func contains(_ anchor: CharacterAnchor) -> Bool {
        anchor.offset >= start && anchor.offset < end
    }

    func clamped(to characterCount: Int) -> Self {
        let limit = max(0, characterCount)
        let lower = min(start, limit)
        return Self(start: lower, end: min(max(lower, end), limit))
    }
}

/// A half-open range in the immutable normalized-unit sequence.
struct SpeechUnitRange: Hashable, Sendable {
    let start: Int
    let end: Int

    init(start: Int, end: Int) {
        let safeStart = max(0, start)
        self.start = safeStart
        self.end = max(safeStart, end)
    }

    var count: Int {
        end - start
    }

    var range: Range<Int> {
        start..<end
    }
}

struct SpeechSegmentID: Hashable, CustomStringConvertible, Sendable {
    let ordinal: Int
    let sourceRange: CharacterRange

    var description: String {
        "segment-\(ordinal)-\(sourceRange.start)-\(sourceRange.end)"
    }
}

enum NormalizedSpeechUnitKind: String, Hashable, Sendable {
    case latinWord
    case number
    case cjkCharacter
    case word
}

struct NormalizedSpeechUnit: Hashable, Sendable {
    let ordinal: Int
    let value: String
    let sourceRange: CharacterRange
    let kind: NormalizedSpeechUnitKind
}

struct SpeechSegment: Identifiable, Hashable, Sendable {
    let id: SpeechSegmentID
    let ordinal: Int
    let sourceRange: CharacterRange
    let unitRange: SpeechUnitRange
    let normalizedUnits: [NormalizedSpeechUnit]
    let previousSegmentID: SpeechSegmentID?
    let nextSegmentID: SpeechSegmentID?

    var startAnchor: CharacterAnchor {
        CharacterAnchor(offset: sourceRange.start)
    }
}

struct SpeechNGram: Hashable, Sendable {
    let first: String
    let second: String

    static func bigrams(
        for units: some Collection<NormalizedSpeechUnit>
    ) -> [Self] {
        let values = units.map(\.value)
        guard values.count >= 2 else {
            return []
        }
        return zip(values, values.dropFirst()).map {
            Self(first: $0.0, second: $0.1)
        }
    }
}

struct SpeechIndexPolicy: Equatable, Sendable {
    static let `default` = Self()

    let previousSegmentCount: Int
    let followingSegmentCount: Int
    let maximumRelocationCandidates: Int
    let maximumSourceCharacters: Int
    let maximumSegments: Int
    let maximumNGramKeys: Int
    let maximumPostingsPerNGram: Int
    let maximumNGramsPerSegment: Int

    init(
        previousSegmentCount: Int = 2,
        followingSegmentCount: Int = 6,
        maximumRelocationCandidates: Int = 8,
        maximumSourceCharacters: Int = 1_000_000,
        maximumSegments: Int = 100_000,
        maximumNGramKeys: Int = 250_000,
        maximumPostingsPerNGram: Int = 100_000,
        maximumNGramsPerSegment: Int = 64
    ) {
        self.previousSegmentCount = max(0, previousSegmentCount)
        self.followingSegmentCount = max(0, followingSegmentCount)
        self.maximumRelocationCandidates = max(
            1,
            maximumRelocationCandidates
        )
        self.maximumSourceCharacters = max(1, maximumSourceCharacters)
        self.maximumSegments = max(1, maximumSegments)
        self.maximumNGramKeys = max(1, maximumNGramKeys)
        self.maximumPostingsPerNGram = max(1, maximumPostingsPerNGram)
        self.maximumNGramsPerSegment = max(1, maximumNGramsPerSegment)
    }
}

struct SpeechDocumentIndex: Equatable, Sendable {
    let policy: SpeechIndexPolicy
    let segmentSourceRanges: [CharacterRange]
    let unitSourceRanges: [CharacterRange]
    let normalizedUnitToSegmentOrdinals: [Int]
    let sourceCharacterToUnitRanges: [SpeechUnitRange]
    let nGramPostings: [SpeechNGram: [Int]]
    let estimatedStorageBytes: Int

    func segmentOrdinal(
        atOrFollowing requestedAnchor: CharacterAnchor
    ) -> Int? {
        guard !segmentSourceRanges.isEmpty else {
            return nil
        }
        let upperLimit = sourceCharacterToUnitRanges.count - 1
        let offset = min(max(0, requestedAnchor.offset), max(0, upperLimit))
        if offset >= segmentSourceRanges[segmentSourceRanges.count - 1].end {
            return segmentSourceRanges.count - 1
        }

        var lower = 0
        var upper = segmentSourceRanges.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if segmentSourceRanges[middle].end <= offset {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return min(lower, segmentSourceRanges.count - 1)
    }

    func normalizedUnitRange(
        forSourceAnchor requestedAnchor: CharacterAnchor
    ) -> SpeechUnitRange {
        guard !sourceCharacterToUnitRanges.isEmpty else {
            return SpeechUnitRange(start: 0, end: 0)
        }
        let index = min(
            max(0, requestedAnchor.offset),
            sourceCharacterToUnitRanges.count - 1
        )
        return sourceCharacterToUnitRanges[index]
    }

    func segmentOrdinal(forNormalizedUnit ordinal: Int) -> Int? {
        guard normalizedUnitToSegmentOrdinals.indices.contains(ordinal) else {
            return nil
        }
        return normalizedUnitToSegmentOrdinals[ordinal]
    }

    func sourceRange(
        forNormalizedUnitRange requestedRange: SpeechUnitRange
    ) -> CharacterRange? {
        let lower = min(max(0, requestedRange.start), unitSourceRanges.count)
        let upper = min(max(lower, requestedRange.end), unitSourceRanges.count)
        guard lower < upper else {
            return nil
        }
        let ranges = unitSourceRanges[lower..<upper]
        guard let first = ranges.first else {
            return nil
        }
        return CharacterRange(
            start: first.start,
            end: ranges.reduce(first.end) { max($0, $1.end) }
        )
    }

    func relocationSegmentOrdinals(
        for nGrams: some Sequence<SpeechNGram>
    ) -> [Int] {
        var ordinals = Set<Int>()
        for nGram in nGrams {
            for ordinal in nGramPostings[nGram] ?? [] {
                ordinals.insert(ordinal)
            }
        }
        return Array(ordinals.sorted().prefix(policy.maximumRelocationCandidates))
    }
}

struct SpeechDocument: Equatable, Sendable {
    let contentRevision: UInt64
    let sourceCharacterCount: Int
    let segments: [SpeechSegment]
    let index: SpeechDocumentIndex

    var hasReadableContent: Bool {
        !segments.isEmpty
    }

    func clampedAnchor(_ anchor: CharacterAnchor) -> CharacterAnchor {
        CharacterAnchor(
            offset: min(max(0, anchor.offset), sourceCharacterCount)
        )
    }
}

struct SpeechCandidateWindow: Equatable, Sendable {
    let requestedAnchor: CharacterAnchor
    let centerSegmentOrdinal: Int?
    let segments: [SpeechSegment]
}

struct SpeechDocumentBuildMetrics: Equatable, Sendable {
    let characterCount: Int
    let segmentCount: Int
    let unitCount: Int
    let nGramKeyCount: Int
    let segmentationMilliseconds: Double
    let normalizationMilliseconds: Double
    let indexingMilliseconds: Double
    let totalMilliseconds: Double
    let estimatedIndexBytes: Int
}

struct SpeechDocumentBuildResult: Equatable, Sendable {
    let document: SpeechDocument
    let metrics: SpeechDocumentBuildMetrics
}

enum SpeechTrackingMode: String, Equatable, Sendable {
    case fixedSpeed
    case speechTracking
}

enum SpeechTrackingAvailability: Equatable, Sendable {
    case unchecked
    case available
    case onDeviceRecognitionUnsupported
    case temporarilyUnavailable
    case authorizationRequired
    case permissionDenied
}

enum SpeechTrackingError: Error, Equatable, Sendable {
    case emptyDocument
    case documentTooLarge(limit: Int)
    case tooManySegments(limit: Int)
    case indexCapacityExceeded
    case invalidCandidate
    case unavailable
}
