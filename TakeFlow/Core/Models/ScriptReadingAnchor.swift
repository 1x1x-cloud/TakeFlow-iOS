import Foundation

/// A layout-independent location in a script.
///
/// The offset counts Swift `Character` values (extended grapheme clusters),
/// so persisted positions remain stable across font, width, orientation and
/// device changes. UI adapters are responsible for mapping it to layout pixels.
struct ScriptReadingAnchor: Codable, Equatable, Sendable {
    var characterOffset: Int

    init(characterOffset: Int) {
        self.characterOffset = max(0, characterOffset)
    }

    func clamped(to content: String) -> Self {
        clamped(toCharacterCount: content.count)
    }

    func clamped(toCharacterCount characterCount: Int) -> Self {
        Self(
            characterOffset: min(
                characterOffset,
                max(0, characterCount)
            )
        )
    }
}
