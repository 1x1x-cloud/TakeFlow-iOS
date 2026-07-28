import Foundation

/// An immutable, content-addressed index used by the teleprompter renderer.
///
/// Offsets are Swift extended-grapheme-cluster (`Character`) offsets. Chunks
/// own exact, ordered substrings so the UI never has to scan from the start of
/// a long script to render or locate a distant reading anchor.
struct TeleprompterDocument: Equatable, Sendable {
    static let targetChunkCharacterCount = 1_500
    static let maximumChunkCharacterCount = 2_200

    struct Chunk: Identifiable, Equatable, Sendable {
        let id: Int
        let characterRange: Range<Int>
        let text: String

        var characterCount: Int {
            characterRange.count
        }
    }

    struct Location: Equatable, Sendable {
        let chunkIndex: Int
        let localCharacterOffset: Int
    }

    let contentRevision: UInt64
    let characterCount: Int
    let hasReadableContent: Bool
    let chunks: [Chunk]

    init(
        content: String,
        targetChunkCharacterCount: Int =
            TeleprompterDocument.targetChunkCharacterCount,
        maximumChunkCharacterCount: Int =
            TeleprompterDocument.maximumChunkCharacterCount
    ) {
        let target = max(1, targetChunkCharacterCount)
        let maximum = max(target, maximumChunkCharacterCount)
        var builtChunks: [Chunk] = []
        builtChunks.reserveCapacity(max(1, content.count / target))

        var chunkStart = content.startIndex
        var chunkStartOffset = 0
        var currentIndex = content.startIndex
        var currentOffset = 0
        var charactersInChunk = 0

        while currentIndex < content.endIndex {
            let character = content[currentIndex]
            let nextIndex = content.index(after: currentIndex)
            currentOffset += 1
            charactersInChunk += 1

            let paragraphBoundary =
                character == "\n"
                || character == "\r"
                || character == "\r\n"
            let shouldCloseAtParagraph =
                paragraphBoundary && charactersInChunk >= target
            let shouldCloseAtMaximum = charactersInChunk >= maximum

            if shouldCloseAtParagraph || shouldCloseAtMaximum {
                builtChunks.append(
                    Chunk(
                        id: builtChunks.count,
                        characterRange:
                            chunkStartOffset..<currentOffset,
                        text: String(content[chunkStart..<nextIndex])
                    )
                )
                chunkStart = nextIndex
                chunkStartOffset = currentOffset
                charactersInChunk = 0
            }
            currentIndex = nextIndex
        }

        if chunkStart < content.endIndex {
            builtChunks.append(
                Chunk(
                    id: builtChunks.count,
                    characterRange: chunkStartOffset..<currentOffset,
                    text: String(content[chunkStart..<content.endIndex])
                )
            )
        }

        if builtChunks.isEmpty {
            builtChunks = [
                Chunk(id: 0, characterRange: 0..<0, text: "")
            ]
        }

        contentRevision = Self.revision(for: content)
        characterCount = currentOffset
        hasReadableContent = content.unicodeScalars.contains {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        }
        chunks = builtChunks
    }

    func location(forGlobalCharacterOffset requestedOffset: Int) -> Location {
        let offset = min(max(0, requestedOffset), characterCount)
        guard characterCount > 0 else {
            return Location(chunkIndex: 0, localCharacterOffset: 0)
        }
        if offset == characterCount {
            let lastIndex = chunks.index(before: chunks.endIndex)
            return Location(
                chunkIndex: lastIndex,
                localCharacterOffset: chunks[lastIndex].characterCount
            )
        }

        var lowerBound = 0
        var upperBound = chunks.count
        while lowerBound < upperBound {
            let midpoint = lowerBound + (upperBound - lowerBound) / 2
            let range = chunks[midpoint].characterRange
            if offset < range.lowerBound {
                upperBound = midpoint
            } else if offset >= range.upperBound {
                lowerBound = midpoint + 1
            } else {
                return Location(
                    chunkIndex: midpoint,
                    localCharacterOffset: offset - range.lowerBound
                )
            }
        }

        let lastIndex = chunks.index(before: chunks.endIndex)
        return Location(
            chunkIndex: lastIndex,
            localCharacterOffset: chunks[lastIndex].characterCount
        )
    }

    func globalCharacterOffset(
        chunkIndex: Int,
        localCharacterOffset: Int
    ) -> Int {
        guard chunks.indices.contains(chunkIndex) else {
            return min(max(0, localCharacterOffset), characterCount)
        }
        let chunk = chunks[chunkIndex]
        return min(
            characterCount,
            chunk.characterRange.lowerBound
                + min(max(0, localCharacterOffset), chunk.characterCount)
        )
    }

    func reconstructedContent() -> String {
        chunks.lazy.map(\.text).joined()
    }

    private static func revision(for content: String) -> UInt64 {
        var value: UInt64 = 14_695_981_039_346_656_037
        for byte in content.utf8 {
            value ^= UInt64(byte)
            value &*= 1_099_511_628_211
        }
        value ^= UInt64(content.utf8.count)
        value &*= 1_099_511_628_211
        return value
    }
}

/// A small least-recently-used cache. Rendered text stays bounded even when a
/// user traverses every chunk in a very long script.
struct TeleprompterChunkCache<Value> {
    let capacity: Int
    private(set) var values: [Int: Value] = [:]
    private var recency: [Int] = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    var count: Int {
        values.count
    }

    mutating func value(for key: Int) -> Value? {
        guard let value = values[key] else {
            return nil
        }
        markRecentlyUsed(key)
        return value
    }

    mutating func insert(_ value: Value, for key: Int) {
        values[key] = value
        markRecentlyUsed(key)
        while values.count > capacity, let leastRecent = recency.first {
            recency.removeFirst()
            values.removeValue(forKey: leastRecent)
        }
    }

    mutating func retain(keys: Set<Int>) {
        values = values.filter { keys.contains($0.key) }
        recency.removeAll { !keys.contains($0) }
    }

    mutating func removeAll() {
        values.removeAll(keepingCapacity: true)
        recency.removeAll(keepingCapacity: true)
    }

    private mutating func markRecentlyUsed(_ key: Int) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }
}
