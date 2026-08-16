import Foundation

struct SpeechDocumentIndexBuilder: SpeechDocumentIndexing {
    func makeIndex(
        segments: [SpeechSegment],
        sourceCharacterCount: Int,
        policy: SpeechIndexPolicy
    ) throws -> SpeechDocumentIndex {
        guard sourceCharacterCount <= policy.maximumSourceCharacters else {
            throw SpeechTrackingError.documentTooLarge(
                limit: policy.maximumSourceCharacters
            )
        }
        guard segments.count <= policy.maximumSegments else {
            throw SpeechTrackingError.tooManySegments(
                limit: policy.maximumSegments
            )
        }

        let unitCount = segments.reduce(0) {
            $0 + $1.normalizedUnits.count
        }
        var unitSourceRanges: [CharacterRange] = []
        var unitSegmentOrdinals: [Int] = []
        unitSourceRanges.reserveCapacity(unitCount)
        unitSegmentOrdinals.reserveCapacity(unitCount)
        var normalizedUTF8Bytes = 0
        for segment in segments {
            for unit in segment.normalizedUnits {
                unitSourceRanges.append(unit.sourceRange)
                unitSegmentOrdinals.append(segment.ordinal)
                normalizedUTF8Bytes += unit.value.utf8.count
            }
        }

        var sourceBounds = Array(
            repeating: SourceUnitBounds(),
            count: sourceCharacterCount
        )
        for (ordinal, range) in unitSourceRanges.enumerated() {
            if ordinal.isMultiple(of: 512) {
                try Task.checkCancellation()
            }
            for sourceOffset in range.clamped(to: sourceCharacterCount).range {
                sourceBounds[sourceOffset].include(ordinal)
            }
        }
        var sourceMappings: [SpeechUnitRange] = []
        sourceMappings.reserveCapacity(sourceCharacterCount + 1)
        var insertionUnit = 0
        for sourceOffset in 0..<sourceCharacterCount {
            while insertionUnit < unitSourceRanges.count,
                  unitSourceRanges[insertionUnit].end <= sourceOffset {
                insertionUnit += 1
            }
            if sourceBounds[sourceOffset].hasValue {
                sourceMappings.append(sourceBounds[sourceOffset].unitRange)
            } else {
                sourceMappings.append(
                    SpeechUnitRange(
                        start: insertionUnit,
                        end: insertionUnit
                    )
                )
            }
        }
        sourceMappings.append(
            SpeechUnitRange(start: unitCount, end: unitCount)
        )

        var postings: [SpeechNGram: [Int]] = [:]
        postings.reserveCapacity(min(unitCount, policy.maximumNGramKeys))
        for segment in segments {
            try Task.checkCancellation()
            var seenInSegment = Set<SpeechNGram>()
            seenInSegment.reserveCapacity(
                min(
                    segment.normalizedUnits.count,
                    policy.maximumNGramsPerSegment
                )
            )
            let upper = min(
                segment.normalizedUnits.count,
                policy.maximumNGramsPerSegment + 1
            )
            guard upper >= 2 else {
                continue
            }
            for index in 1..<upper {
                let gram = SpeechNGram(
                    first: segment.normalizedUnits[index - 1].value,
                    second: segment.normalizedUnits[index].value
                )
                guard seenInSegment.insert(gram).inserted else {
                    continue
                }
                if postings[gram] == nil,
                   postings.count >= policy.maximumNGramKeys {
                    throw SpeechTrackingError.indexCapacityExceeded
                }
                guard (postings[gram]?.count ?? 0)
                    < policy.maximumPostingsPerNGram else {
                    throw SpeechTrackingError.indexCapacityExceeded
                }
                postings[gram, default: []].append(segment.ordinal)
            }
        }

        let postingCount = postings.values.reduce(0) { $0 + $1.count }
        let estimatedBytes =
            sourceMappings.count * MemoryLayout<SpeechUnitRange>.stride
            + unitSourceRanges.count * MemoryLayout<CharacterRange>.stride
            + unitSegmentOrdinals.count * MemoryLayout<Int>.stride
            + segments.count * MemoryLayout<CharacterRange>.stride
            + postings.count * 64
            + postingCount * MemoryLayout<Int>.stride
            + unitCount * 48
            + normalizedUTF8Bytes

        return SpeechDocumentIndex(
            policy: policy,
            segmentSourceRanges: segments.map(\.sourceRange),
            unitSourceRanges: unitSourceRanges,
            normalizedUnitToSegmentOrdinals: unitSegmentOrdinals,
            sourceCharacterToUnitRanges: sourceMappings,
            nGramPostings: postings,
            estimatedStorageBytes: estimatedBytes
        )
    }
}

struct SpeechDocumentBuilder: SpeechDocumentBuilding {
    static let softSplitTokenThreshold = 42
    static let minimumSegmentTokenCount = 4
    static let maximumSegmentTokenCount = 48

    let policy: SpeechIndexPolicy
    private let normalizer: any SpeechTextNormalizing
    private let indexer: any SpeechDocumentIndexing

    init(
        policy: SpeechIndexPolicy = .default,
        normalizer: any SpeechTextNormalizing = SpeechTextNormalizer(),
        indexer: any SpeechDocumentIndexing = SpeechDocumentIndexBuilder()
    ) {
        self.policy = policy
        self.normalizer = normalizer
        self.indexer = indexer
    }

    func buildDocument(
        from content: String,
        contentRevision: UInt64? = nil
    ) async throws -> SpeechDocumentBuildResult {
        let policy = policy
        let normalizer = normalizer
        let indexer = indexer
        let work = Task.detached(priority: .userInitiated) {
            try Self.buildSynchronously(
                content: content,
                contentRevision: contentRevision,
                policy: policy,
                normalizer: normalizer,
                indexer: indexer
            )
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    private static func buildSynchronously(
        content: String,
        contentRevision: UInt64?,
        policy: SpeechIndexPolicy,
        normalizer: any SpeechTextNormalizing,
        indexer: any SpeechDocumentIndexing
    ) throws -> SpeechDocumentBuildResult {
        let totalStart = ContinuousClock.now
        let characters = Array(content)
        guard characters.count <= policy.maximumSourceCharacters else {
            throw SpeechTrackingError.documentTooLarge(
                limit: policy.maximumSourceCharacters
            )
        }

        let segmentationStart = ContinuousClock.now
        let blocks = try makeHardBlocks(from: characters)
        let initialSegmentationMilliseconds = milliseconds(
            from: segmentationStart,
            to: .now
        )

        let normalizationStart = ContinuousClock.now
        let normalization = try normalizer.normalize(
            content,
            sourceStart: CharacterAnchor(offset: 0),
            unitStart: 0
        )
        let normalizationMilliseconds = milliseconds(
            from: normalizationStart,
            to: .now
        )

        let segmentAssemblyStart = ContinuousClock.now
        let drafts = try makeSegmentDrafts(
            from: blocks,
            normalizedUnits: normalization.normalizedUnits,
            characters: characters
        )
        guard drafts.count <= policy.maximumSegments else {
            throw SpeechTrackingError.tooManySegments(
                limit: policy.maximumSegments
            )
        }
        let segments = makeSegments(from: drafts)
        let segmentationMilliseconds = initialSegmentationMilliseconds
            + milliseconds(from: segmentAssemblyStart, to: .now)

        let indexingStart = ContinuousClock.now
        let index = try indexer.makeIndex(
            segments: segments,
            sourceCharacterCount: characters.count,
            policy: policy
        )
        let indexingMilliseconds = milliseconds(
            from: indexingStart,
            to: .now
        )
        let revision = contentRevision ?? stableRevision(for: content)
        let document = SpeechDocument(
            contentRevision: revision,
            sourceCharacterCount: characters.count,
            segments: segments,
            index: index
        )
        let totalMilliseconds = milliseconds(from: totalStart, to: .now)
        let unitCount = segments.reduce(0) {
            $0 + $1.normalizedUnits.count
        }
        return SpeechDocumentBuildResult(
            document: document,
            metrics: SpeechDocumentBuildMetrics(
                characterCount: characters.count,
                segmentCount: segments.count,
                unitCount: unitCount,
                nGramKeyCount: index.nGramPostings.count,
                segmentationMilliseconds: segmentationMilliseconds,
                normalizationMilliseconds: normalizationMilliseconds,
                indexingMilliseconds: indexingMilliseconds,
                totalMilliseconds: totalMilliseconds,
                estimatedIndexBytes: index.estimatedStorageBytes
            )
        )
    }

    private static func makeHardBlocks(
        from characters: [Character]
    ) throws -> [HardBlock] {
        var blocks: [HardBlock] = []
        var paragraphOrdinal = 0
        var blockStart = 0
        var index = 0

        while index < characters.count {
            if index.isMultiple(of: 512) {
                try Task.checkCancellation()
            }
            if isNewline(characters[index]) {
                appendBlock(
                    start: blockStart,
                    end: index,
                    paragraphOrdinal: paragraphOrdinal,
                    to: &blocks
                )
                paragraphOrdinal += 1
                index += 1
                blockStart = index
                continue
            }
            if isHardTerminator(characters[index]) {
                var end = index + 1
                while end < characters.count,
                      isTrailingSentenceMark(characters[end]) {
                    end += 1
                }
                appendBlock(
                    start: blockStart,
                    end: end,
                    paragraphOrdinal: paragraphOrdinal,
                    to: &blocks
                )
                blockStart = end
                index = end
                continue
            }
            index += 1
        }
        appendBlock(
            start: blockStart,
            end: characters.count,
            paragraphOrdinal: paragraphOrdinal,
            to: &blocks
        )
        return blocks
    }

    private static func appendBlock(
        start: Int,
        end: Int,
        paragraphOrdinal: Int,
        to blocks: inout [HardBlock]
    ) {
        guard start < end else {
            return
        }
        blocks.append(
            HardBlock(
                sourceRange: CharacterRange(start: start, end: end),
                paragraphOrdinal: paragraphOrdinal
            )
        )
    }

    private static func makeSegmentDrafts(
        from blocks: [HardBlock],
        normalizedUnits: [NormalizedSpeechUnit],
        characters: [Character]
    ) throws -> [SegmentDraft] {
        var result: [SegmentDraft] = []
        var paragraphDrafts: [SegmentDraft] = []
        var paragraphOrdinal: Int?
        var leadingIgnoredStart: Int?
        var unitIndex = 0

        func flushParagraph() {
            guard !paragraphDrafts.isEmpty else {
                leadingIgnoredStart = nil
                return
            }
            result.append(contentsOf: mergeShortSegments(paragraphDrafts))
            paragraphDrafts.removeAll(keepingCapacity: true)
            leadingIgnoredStart = nil
        }

        for block in blocks {
            try Task.checkCancellation()
            if paragraphOrdinal != block.paragraphOrdinal {
                flushParagraph()
                paragraphOrdinal = block.paragraphOrdinal
            }
            while unitIndex < normalizedUnits.count,
                  normalizedUnits[unitIndex].sourceRange.end
                    <= block.sourceRange.start {
                unitIndex += 1
            }
            let blockUnitStart = unitIndex
            while unitIndex < normalizedUnits.count,
                  normalizedUnits[unitIndex].sourceRange.start
                    < block.sourceRange.end {
                unitIndex += 1
            }
            var drafts = split(
                block: block,
                units: normalizedUnits[blockUnitStart..<unitIndex],
                characters: characters
            )
            if drafts.isEmpty {
                if paragraphDrafts.isEmpty {
                    leadingIgnoredStart = min(
                        leadingIgnoredStart ?? block.sourceRange.start,
                        block.sourceRange.start
                    )
                } else if let last = paragraphDrafts.popLast() {
                    paragraphDrafts.append(
                        last.expandingRangeEnd(to: block.sourceRange.end)
                    )
                }
                continue
            }
            if let ignoredStart = leadingIgnoredStart {
                drafts[0] = drafts[0].expandingRangeStart(
                    to: ignoredStart
                )
                leadingIgnoredStart = nil
            }
            paragraphDrafts.append(contentsOf: drafts)
        }
        flushParagraph()
        return result
    }

    private static func split(
        block: HardBlock,
        units: ArraySlice<NormalizedSpeechUnit>,
        characters: [Character]
    ) -> [SegmentDraft] {
        guard !units.isEmpty else {
            return []
        }
        var rawRanges = [block.sourceRange]
        if units.count > softSplitTokenThreshold {
            rawRanges = []
            var start = block.sourceRange.start
            for offset in block.sourceRange.range
            where isSoftTerminator(characters[offset]) {
                rawRanges.append(
                    CharacterRange(start: start, end: offset + 1)
                )
                start = offset + 1
            }
            if start < block.sourceRange.end {
                rawRanges.append(
                    CharacterRange(start: start, end: block.sourceRange.end)
                )
            }
            if rawRanges.isEmpty {
                rawRanges = [block.sourceRange]
            }
        }

        var drafts: [SegmentDraft] = []
        var unitIndex = units.startIndex
        for rawRange in rawRanges {
            while unitIndex < units.endIndex,
                  units[unitIndex].sourceRange.end <= rawRange.start {
                unitIndex += 1
            }
            let rangeUnitStart = unitIndex
            while unitIndex < units.endIndex,
                  units[unitIndex].sourceRange.start < rawRange.end {
                unitIndex += 1
            }
            guard rangeUnitStart < unitIndex else {
                if let last = drafts.popLast() {
                    drafts.append(last.expandingRangeEnd(to: rawRange.end))
                }
                continue
            }
            appendChunks(
                units: units[rangeUnitStart..<unitIndex],
                sourceRange: rawRange,
                paragraphOrdinal: block.paragraphOrdinal,
                to: &drafts
            )
        }
        return drafts
    }

    private static func appendChunks(
        units: ArraySlice<NormalizedSpeechUnit>,
        sourceRange: CharacterRange,
        paragraphOrdinal: Int,
        to drafts: inout [SegmentDraft]
    ) {
        var start = units.startIndex
        var chunkSourceStart = sourceRange.start
        while start < units.endIndex {
            var end = min(
                start + maximumSegmentTokenCount,
                units.endIndex
            )
            if end < units.endIndex,
               units[end - 1].sourceRange == units[end].sourceRange {
                while end > start,
                      units[end - 1].sourceRange == units[end].sourceRange {
                    end -= 1
                }
                if end == start {
                    end = min(
                        start + maximumSegmentTokenCount,
                        units.endIndex
                    )
                    while end < units.endIndex,
                          units[end - 1].sourceRange == units[end].sourceRange {
                        end += 1
                    }
                }
            }
            let chunkSourceEnd = end == units.endIndex
                ? sourceRange.end
                : units[end].sourceRange.start
            drafts.append(
                SegmentDraft(
                    sourceRange: CharacterRange(
                        start: chunkSourceStart,
                        end: chunkSourceEnd
                    ),
                    paragraphOrdinal: paragraphOrdinal,
                    units: Array(units[start..<end])
                )
            )
            chunkSourceStart = chunkSourceEnd
            start = end
        }
    }

    private static func mergeShortSegments(
        _ drafts: [SegmentDraft]
    ) -> [SegmentDraft] {
        var merged: [SegmentDraft] = []
        for draft in drafts {
            if let last = merged.last,
               (last.units.count < minimumSegmentTokenCount
                    || draft.units.count < minimumSegmentTokenCount),
               last.units.count + draft.units.count
                    <= maximumSegmentTokenCount {
                merged.removeLast()
                merged.append(last.merging(with: draft))
            } else {
                merged.append(draft)
            }
        }
        if merged.count >= 2,
           let last = merged.last,
           last.units.count < minimumSegmentTokenCount {
            let previous = merged[merged.count - 2]
            if previous.units.count + last.units.count
                <= maximumSegmentTokenCount {
                merged.removeLast(2)
                merged.append(previous.merging(with: last))
            }
        }
        return merged
    }

    private static func makeSegments(
        from drafts: [SegmentDraft]
    ) -> [SpeechSegment] {
        var unitOrdinal = 0
        let ids = drafts.enumerated().map {
            SpeechSegmentID(
                ordinal: $0.offset,
                sourceRange: $0.element.sourceRange
            )
        }
        var segments: [SpeechSegment] = []
        segments.reserveCapacity(drafts.count)
        for (segmentOrdinal, draft) in drafts.enumerated() {
            let start = unitOrdinal
            var units: [NormalizedSpeechUnit] = []
            units.reserveCapacity(draft.units.count)
            for unit in draft.units {
                units.append(
                    NormalizedSpeechUnit(
                    ordinal: unitOrdinal,
                    value: unit.value,
                    sourceRange: unit.sourceRange,
                    kind: unit.kind
                    )
                )
                unitOrdinal += 1
            }
            segments.append(
                SpeechSegment(
                    id: ids[segmentOrdinal],
                    ordinal: segmentOrdinal,
                    sourceRange: draft.sourceRange,
                    unitRange: SpeechUnitRange(
                        start: start,
                        end: unitOrdinal
                    ),
                    normalizedUnits: units,
                    previousSegmentID: segmentOrdinal > 0
                        ? ids[segmentOrdinal - 1]
                        : nil,
                    nextSegmentID: segmentOrdinal + 1 < ids.count
                        ? ids[segmentOrdinal + 1]
                        : nil
                )
            )
        }
        return segments
    }

    private static func isNewline(_ character: Character) -> Bool {
        character == "\n" || character == "\r" || character == "\r\n"
    }

    private static func isHardTerminator(_ character: Character) -> Bool {
        "。！？!?；;.".contains(character)
    }

    private static func isSoftTerminator(_ character: Character) -> Bool {
        "，,、：:".contains(character)
    }

    private static func isTrailingSentenceMark(
        _ character: Character
    ) -> Bool {
        isHardTerminator(character)
            || isSoftTerminator(character)
            || "”’\"'」』）》】〕〉》".contains(character)
    }

    private static func stableRevision(for content: String) -> UInt64 {
        var value: UInt64 = 14_695_981_039_346_656_037
        for byte in content.utf8 {
            value ^= UInt64(byte)
            value &*= 1_099_511_628_211
        }
        value ^= UInt64(content.utf8.count)
        value &*= 1_099_511_628_211
        return value
    }

    private static func milliseconds(
        from start: ContinuousClock.Instant,
        to end: ContinuousClock.Instant
    ) -> Double {
        let components = start.duration(to: end).components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1e15
    }
}

private struct SourceUnitBounds {
    private(set) var lower = Int.max
    private(set) var upper = Int.min

    var hasValue: Bool {
        lower != Int.max
    }

    var unitRange: SpeechUnitRange {
        SpeechUnitRange(start: lower, end: upper + 1)
    }

    mutating func include(_ ordinal: Int) {
        lower = min(lower, ordinal)
        upper = max(upper, ordinal)
    }
}

private struct HardBlock {
    let sourceRange: CharacterRange
    let paragraphOrdinal: Int
}

private struct SegmentDraft {
    let sourceRange: CharacterRange
    let paragraphOrdinal: Int
    let units: [NormalizedSpeechUnit]

    func expandingRangeStart(to start: Int) -> Self {
        Self(
            sourceRange: CharacterRange(start: start, end: sourceRange.end),
            paragraphOrdinal: paragraphOrdinal,
            units: units
        )
    }

    func expandingRangeEnd(to end: Int) -> Self {
        Self(
            sourceRange: CharacterRange(start: sourceRange.start, end: end),
            paragraphOrdinal: paragraphOrdinal,
            units: units
        )
    }

    func merging(with other: Self) -> Self {
        Self(
            sourceRange: CharacterRange(
                start: min(sourceRange.start, other.sourceRange.start),
                end: max(sourceRange.end, other.sourceRange.end)
            ),
            paragraphOrdinal: paragraphOrdinal,
            units: units + other.units
        )
    }
}
