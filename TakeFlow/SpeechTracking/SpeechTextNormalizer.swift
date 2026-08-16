import Foundation

struct SpeechTextNormalizer: SpeechTextNormalizing {
    private static let foldingLocale = Locale(identifier: "en_US_POSIX")

    func normalize(
        _ text: String,
        sourceStart: CharacterAnchor = CharacterAnchor(offset: 0),
        unitStart: Int = 0
    ) throws -> SpeechNormalizationResult {
        let characters = Array(text)
        var drafts: [UnitDraft] = []
        drafts.reserveCapacity(characters.count)
        var pending: PendingToken?

        for (localOffset, sourceCharacter) in characters.enumerated() {
            if localOffset.isMultiple(of: 512) {
                try Task.checkCancellation()
            }
            let sourceOffset = sourceStart.offset + localOffset
            let sourceRange = CharacterRange(
                start: sourceOffset,
                end: sourceOffset + 1
            )

            if let scalar = sourceCharacter.unicodeScalars.first,
               sourceCharacter.unicodeScalars.count == 1,
               scalar.isASCII {
                let value = scalar.value
                if (0x30...0x39).contains(value) {
                    append(
                        sourceCharacter,
                        kind: .number,
                        sourceRange: sourceRange,
                        pending: &pending,
                        drafts: &drafts
                    )
                } else if (0x41...0x5A).contains(value),
                          let lowered = UnicodeScalar(value + 0x20) {
                    append(
                        Character(String(lowered)),
                        kind: .latinWord,
                        sourceRange: sourceRange,
                        pending: &pending,
                        drafts: &drafts
                    )
                } else if (0x61...0x7A).contains(value) {
                    append(
                        sourceCharacter,
                        kind: .latinWord,
                        sourceRange: sourceRange,
                        pending: &pending,
                        drafts: &drafts
                    )
                } else {
                    flush(&pending, into: &drafts)
                }
                continue
            }
            if Self.isSimpleCJK(sourceCharacter) {
                flush(&pending, into: &drafts)
                drafts.append(
                    UnitDraft(
                        value: String(sourceCharacter),
                        sourceRange: sourceRange,
                        kind: .cjkCharacter
                    )
                )
                continue
            }

            let pieces = Self.normalizedPieces(for: sourceCharacter)
            if pieces.isEmpty {
                flush(&pending, into: &drafts)
                continue
            }

            for piece in pieces {
                guard let kind = Self.kind(for: piece) else {
                    flush(&pending, into: &drafts)
                    continue
                }
                if kind == .cjkCharacter {
                    flush(&pending, into: &drafts)
                    drafts.append(
                        UnitDraft(
                            value: String(piece),
                            sourceRange: sourceRange,
                            kind: kind
                        )
                    )
                } else {
                    append(
                        piece,
                        kind: kind,
                        sourceRange: sourceRange,
                        pending: &pending,
                        drafts: &drafts
                    )
                }
            }
        }
        flush(&pending, into: &drafts)

        let units = drafts.enumerated().map { index, draft in
            NormalizedSpeechUnit(
                ordinal: unitStart + index,
                value: draft.value,
                sourceRange: draft.sourceRange,
                kind: draft.kind
            )
        }
        return SpeechNormalizationResult(
            sourceRange: CharacterRange(
                start: sourceStart.offset,
                end: sourceStart.offset + characters.count
            ),
            normalizedUnits: units
        )
    }

    private func flush(
        _ pending: inout PendingToken?,
        into drafts: inout [UnitDraft]
    ) {
        guard let token = pending else {
            return
        }
        drafts.append(
            UnitDraft(
                value: token.value,
                sourceRange: token.sourceRange,
                kind: token.kind
            )
        )
        pending = nil
    }

    private func append(
        _ character: Character,
        kind: NormalizedSpeechUnitKind,
        sourceRange: CharacterRange,
        pending: inout PendingToken?,
        drafts: inout [UnitDraft]
    ) {
        if pending?.kind == kind,
           pending?.sourceRange.end == sourceRange.start {
            let pendingStart = pending?.sourceRange.start
                ?? sourceRange.start
            pending?.value.append(character)
            pending?.sourceRange = CharacterRange(
                start: pendingStart,
                end: sourceRange.end
            )
        } else {
            flush(&pending, into: &drafts)
            pending = PendingToken(
                value: String(character),
                sourceRange: sourceRange,
                kind: kind
            )
        }
    }

    private static func normalizedPieces(
        for character: Character
    ) -> [Character] {
        let source = String(character)
        let normalized: String
        if character.unicodeScalars.allSatisfy({ $0.isASCII }) {
            normalized = source.lowercased(with: foldingLocale)
        } else if isSimpleCJK(character) {
            normalized = source
        } else {
            normalized = source
                .precomposedStringWithCompatibilityMapping
                .lowercased(with: foldingLocale)
        }
        return Array(normalized)
    }

    private static func kind(
        for character: Character
    ) -> NormalizedSpeechUnitKind? {
        let scalars = character.unicodeScalars
        guard !scalars.isEmpty else {
            return nil
        }
        if scalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) }) {
            return .number
        }
        if scalars.allSatisfy({ isLatinLetter($0) || isCombiningMark($0) }) {
            return .latinWord
        }
        if isSimpleCJK(character) {
            return .cjkCharacter
        }
        if scalars.contains(where: { CharacterSet.letters.contains($0) }) {
            return .word
        }
        return nil
    }

    private static func isSimpleCJK(_ character: Character) -> Bool {
        guard let first = character.unicodeScalars.first else {
            return false
        }
        let value = first.value
        return (0x3400...0x4DBF).contains(value)
            || (0x4E00...0x9FFF).contains(value)
            || (0xF900...0xFAFF).contains(value)
            || (0x20000...0x2FA1F).contains(value)
    }

    private static func isLatinLetter(_ scalar: UnicodeScalar) -> Bool {
        guard CharacterSet.letters.contains(scalar) else {
            return false
        }
        let value = scalar.value
        return (0x0041...0x005A).contains(value)
            || (0x0061...0x007A).contains(value)
            || (0x00C0...0x024F).contains(value)
            || (0x1E00...0x1EFF).contains(value)
    }

    private static func isCombiningMark(_ scalar: UnicodeScalar) -> Bool {
        CharacterSet.nonBaseCharacters.contains(scalar)
    }
}

private struct UnitDraft {
    let value: String
    let sourceRange: CharacterRange
    let kind: NormalizedSpeechUnitKind
}

private struct PendingToken {
    var value: String
    var sourceRange: CharacterRange
    let kind: NormalizedSpeechUnitKind
}
