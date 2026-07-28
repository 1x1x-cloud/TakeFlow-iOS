import SwiftUI
import UIKit

struct TeleprompterTextView: UIViewRepresentable {
    let document: TeleprompterDocument
    let preferences: TeleprompterPreferences
    let targetOffset: Double
    let anchor: ScriptReadingAnchor
    let layoutRevision: Int
    let foregroundColor: UIColor
    let onTapped: () -> Void
    let onDragStarted: () -> Void
    let onDragChanged: (_ offset: Double, _ characterOffset: Int) -> Void
    let onDragEnded: (_ offset: Double, _ characterOffset: Int) -> Void
    let onVisibleAnchorChanged: (_ characterOffset: Int) -> Void
    let onLayoutResolved:
        (_ maximumOffset: Double, _ restoredOffset: Double, _ characterOffset: Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UICollectionView {
        context.coordinator.makeCollectionView()
    }

    func updateUIView(
        _ collectionView: UICollectionView,
        context: Context
    ) {
        context.coordinator.update(parent: self)

        let documentChanged =
            context.coordinator.appliedContentRevision
                != document.contentRevision
        let layoutChanged =
            context.coordinator.appliedLayoutRevision != layoutRevision
        let sizeChanged = context.coordinator.hasSizeChanged(collectionView)
        if documentChanged || layoutChanged || sizeChanged {
            context.coordinator.applyDocument(
                to: collectionView,
                restoring: anchor
            )
        } else if !collectionView.isDragging,
                  !collectionView.isDecelerating {
            context.coordinator.applyProgrammaticOffset(
                targetOffset,
                to: collectionView
            )
        }
    }

    @MainActor
    final class Coordinator:
        NSObject,
        UICollectionViewDataSource,
        UICollectionViewDelegate,
        UICollectionViewDataSourcePrefetching
    {
        static let textCacheCapacity = 8

        private var parent: TeleprompterTextView
        private var document: TeleprompterDocument
        fileprivate var appliedContentRevision: UInt64?
        fileprivate var appliedLayoutRevision = -1
        private var textCache =
            TeleprompterChunkCache<NSAttributedString>(
                capacity: textCacheCapacity
            )
        private weak var collectionView: UICollectionView?
        private var isApplyingProgrammaticOffset = false
        private var lastLayoutSize = CGSize.zero
        private var lastReportedOffset = -Double.infinity
        private var lastReportedMaximumOffset = -Double.infinity

        var cachedChunkIndices: Set<Int> {
            Set(textCache.values.keys)
        }

        init(parent: TeleprompterTextView) {
            self.parent = parent
            document = parent.document
            super.init()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleMemoryWarning),
                name: UIApplication.didReceiveMemoryWarningNotification,
                object: nil
            )
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func makeCollectionView() -> UICollectionView {
            let collectionView = UICollectionView(
                frame: .zero,
                collectionViewLayout: makeLayout(viewportSize: .zero)
            )
            collectionView.backgroundColor = .clear
            collectionView.alwaysBounceVertical = true
            collectionView.showsVerticalScrollIndicator = false
            collectionView.dataSource = self
            collectionView.delegate = self
            collectionView.prefetchDataSource = self
            collectionView.register(
                TeleprompterChunkCell.self,
                forCellWithReuseIdentifier:
                    TeleprompterChunkCell.reuseIdentifier
            )
            collectionView.accessibilityLabel = TeleprompterStrings.title
            collectionView.accessibilityHint =
                TeleprompterStrings.hideControlsHint
            collectionView.accessibilityIdentifier = "teleprompter.text"

            let tapRecognizer = UITapGestureRecognizer(
                target: self,
                action: #selector(Coordinator.handleTap)
            )
            tapRecognizer.cancelsTouchesInView = false
            collectionView.addGestureRecognizer(tapRecognizer)
            attach(to: collectionView)
            return collectionView
        }

        func attach(to collectionView: UICollectionView) {
            self.collectionView = collectionView
        }

        func update(parent: TeleprompterTextView) {
            self.parent = parent
        }

        @objc func handleTap() {
            parent.onTapped()
        }

        @objc private func handleMemoryWarning() {
            guard let collectionView else {
                textCache.removeAll()
                return
            }
            let visibleKeys = Set(
                collectionView.indexPathsForVisibleItems.map(\.item)
            )
            textCache.retain(keys: visibleKeys)
        }

        func hasSizeChanged(_ collectionView: UICollectionView) -> Bool {
            abs(lastLayoutSize.width - collectionView.bounds.width) > 0.5
                || abs(
                    lastLayoutSize.height - collectionView.bounds.height
                ) > 0.5
        }

        func applyDocument(
            to collectionView: UICollectionView,
            restoring anchor: ScriptReadingAnchor
        ) {
            document = parent.document
            appliedContentRevision = document.contentRevision
            appliedLayoutRevision = parent.layoutRevision
            lastLayoutSize = collectionView.bounds.size
            lastReportedOffset = -Double.infinity
            lastReportedMaximumOffset = -Double.infinity
            textCache.removeAll()

            collectionView.setCollectionViewLayout(
                makeLayout(viewportSize: collectionView.bounds.size),
                animated: false
            )
            collectionView.reloadData()
            collectionView.layoutIfNeeded()
            restoreAnchor(anchor, in: collectionView)
        }

        func makeLayout(
            viewportSize: CGSize
        ) -> UICollectionViewLayout {
            let estimatedHeight = estimatedChunkHeight(
                viewportWidth: viewportSize.width
            )
            let itemSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1),
                heightDimension: .estimated(estimatedHeight)
            )
            let item = NSCollectionLayoutItem(layoutSize: itemSize)
            let group = NSCollectionLayoutGroup.vertical(
                layoutSize: itemSize,
                subitems: [item]
            )
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = 0
            section.contentInsets = NSDirectionalEdgeInsets(
                top: 32,
                leading: 0,
                bottom: max(80, viewportSize.height * 0.45),
                trailing: 0
            )
            return UICollectionViewCompositionalLayout(section: section)
        }

        func collectionView(
            _ collectionView: UICollectionView,
            numberOfItemsInSection section: Int
        ) -> Int {
            document.chunks.count
        }

        func collectionView(
            _ collectionView: UICollectionView,
            cellForItemAt indexPath: IndexPath
        ) -> UICollectionViewCell {
            guard let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: TeleprompterChunkCell.reuseIdentifier,
                for: indexPath
            ) as? TeleprompterChunkCell else {
                return UICollectionViewCell()
            }
            configure(cell, at: indexPath.item)
            return cell
        }

        func collectionView(
            _ collectionView: UICollectionView,
            prefetchItemsAt indexPaths: [IndexPath]
        ) {
            for indexPath in indexPaths
            where document.chunks.indices.contains(indexPath.item) {
                _ = attributedText(for: indexPath.item)
            }
        }

        func collectionView(
            _ collectionView: UICollectionView,
            willDisplay cell: UICollectionViewCell,
            forItemAt indexPath: IndexPath
        ) {
            preloadChunks(around: indexPath.item)
            reportLayoutIfNeeded(in: collectionView)
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            parent.onDragStarted()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let collectionView = scrollView as? UICollectionView else {
                return
            }
            let offset = Double(max(0, scrollView.contentOffset.y))
            let characterOffset = visibleCharacterOffset(
                in: collectionView,
                exact: false
            )

            if scrollView.isDragging || scrollView.isDecelerating {
                parent.onDragChanged(offset, characterOffset)
            } else if !isApplyingProgrammaticOffset,
                      abs(offset - lastReportedOffset) >= 32 {
                lastReportedOffset = offset
                let callback = parent.onVisibleAnchorChanged
                Task { @MainActor in
                    await Task.yield()
                    callback(characterOffset)
                }
            }
            reportLayoutIfNeeded(in: collectionView)
        }

        func scrollViewDidEndDragging(
            _ scrollView: UIScrollView,
            willDecelerate decelerate: Bool
        ) {
            guard !decelerate,
                  let collectionView = scrollView as? UICollectionView else {
                return
            }
            finishDragging(collectionView)
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            guard let collectionView = scrollView as? UICollectionView else {
                return
            }
            finishDragging(collectionView)
        }

        func applyProgrammaticOffset(
            _ requestedOffset: Double,
            to collectionView: UICollectionView
        ) {
            let maximumOffset = max(
                0,
                collectionView.collectionViewLayout
                    .collectionViewContentSize.height
                    - collectionView.bounds.height
            )
            let clamped = min(max(0, requestedOffset), Double(maximumOffset))
            guard abs(Double(collectionView.contentOffset.y) - clamped) > 0.25
            else {
                return
            }
            isApplyingProgrammaticOffset = true
            collectionView.setContentOffset(
                CGPoint(x: 0, y: clamped),
                animated: false
            )
            isApplyingProgrammaticOffset = false

            if abs(clamped - lastReportedOffset) >= 32 {
                lastReportedOffset = clamped
                let characterOffset = visibleCharacterOffset(
                    in: collectionView,
                    exact: true
                )
                let callback = parent.onVisibleAnchorChanged
                Task { @MainActor in
                    await Task.yield()
                    callback(characterOffset)
                }
            }
        }

        private func configure(
            _ cell: TeleprompterChunkCell,
            at chunkIndex: Int
        ) {
            guard document.chunks.indices.contains(chunkIndex) else {
                return
            }
            let chunk = document.chunks[chunkIndex]
            cell.apply(
                attributedText: attributedText(for: chunkIndex),
                chunkIndex: chunkIndex,
                horizontalMargin: parent.preferences.horizontalMargin,
                accessibilityValue: chunk.text
            )
        }

        private func attributedText(
            for chunkIndex: Int
        ) -> NSAttributedString {
            if let cached = textCache.value(for: chunkIndex) {
                return cached
            }
            let chunk = document.chunks[chunkIndex]
            let baseFont = UIFont.systemFont(
                ofSize: parent.preferences.fontSize,
                weight: .regular
            )
            let font = UIFontMetrics(forTextStyle: .body).scaledFont(
                for: baseFont
            )
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = parent.preferences.lineSpacing
            paragraph.alignment = .natural
            let attributed = NSAttributedString(
                string: chunk.text,
                attributes: [
                    .font: font,
                    .foregroundColor: parent.foregroundColor,
                    .paragraphStyle: paragraph
                ]
            )
            textCache.insert(attributed, for: chunkIndex)
            return attributed
        }

        private func preloadChunks(around chunkIndex: Int) {
            let lowerBound = max(0, chunkIndex - 1)
            let upperBound = min(
                document.chunks.count - 1,
                chunkIndex + 2
            )
            guard lowerBound <= upperBound else {
                return
            }
            for index in lowerBound...upperBound {
                _ = attributedText(for: index)
            }
        }

        private func restoreAnchor(
            _ anchor: ScriptReadingAnchor,
            in collectionView: UICollectionView
        ) {
            let location = document.location(
                forGlobalCharacterOffset: anchor.characterOffset
            )
            let indexPath = IndexPath(
                item: location.chunkIndex,
                section: 0
            )
            collectionView.scrollToItem(
                at: indexPath,
                at: .top,
                animated: false
            )
            collectionView.layoutIfNeeded()

            var requestedOffset: Double
            if let cell = collectionView.cellForItem(
                at: indexPath
            ) as? TeleprompterChunkCell,
               let attributes = collectionView.layoutAttributesForItem(
                at: indexPath
               ) {
                let caret = cell.caretRect(
                    forLocalCharacterOffset:
                        location.localCharacterOffset
                )
                requestedOffset = Double(
                    attributes.frame.minY + caret.minY - 32
                )
            } else if let attributes =
                collectionView.layoutAttributesForItem(at: indexPath) {
                let chunk = document.chunks[location.chunkIndex]
                let fraction = chunk.characterCount > 0
                    ? Double(location.localCharacterOffset)
                        / Double(chunk.characterCount)
                    : 0
                requestedOffset = Double(
                    attributes.frame.minY
                        + attributes.frame.height * fraction
                        - 32
                )
            } else {
                requestedOffset = 0
            }

            applyProgrammaticOffset(
                requestedOffset,
                to: collectionView
            )
            reportLayout(
                collectionView,
                characterOffset: anchor.characterOffset
            )
        }

        private func finishDragging(_ collectionView: UICollectionView) {
            let characterOffset = visibleCharacterOffset(
                in: collectionView,
                exact: true
            )
            parent.onDragEnded(
                Double(max(0, collectionView.contentOffset.y)),
                characterOffset
            )
        }

        private func visibleCharacterOffset(
            in collectionView: UICollectionView,
            exact: Bool
        ) -> Int {
            let visibleY = collectionView.contentOffset.y + 33
            let probeRect = CGRect(
                x: 0,
                y: visibleY,
                width: max(1, collectionView.bounds.width),
                height: 1
            )
            let attributes = collectionView.collectionViewLayout
                .layoutAttributesForElements(in: probeRect)?
                .first { $0.representedElementCategory == .cell }
            guard let attributes else {
                return min(
                    max(0, parent.anchor.characterOffset),
                    document.characterCount
                )
            }
            let chunkIndex = attributes.indexPath.item
            guard document.chunks.indices.contains(chunkIndex) else {
                return 0
            }

            if exact,
               let cell = collectionView.cellForItem(
                at: attributes.indexPath
               ) as? TeleprompterChunkCell {
                let localPoint = collectionView.convert(
                    CGPoint(
                        x: max(
                            1,
                            parent.preferences.horizontalMargin + 1
                        ),
                        y: visibleY
                    ),
                    to: cell.textView
                )
                let localOffset = cell.localCharacterOffset(
                    closestTo: localPoint
                )
                return document.globalCharacterOffset(
                    chunkIndex: chunkIndex,
                    localCharacterOffset: localOffset
                )
            }

            let chunk = document.chunks[chunkIndex]
            let localY = min(
                max(0, visibleY - attributes.frame.minY),
                attributes.frame.height
            )
            let fraction = attributes.frame.height > 0
                ? localY / attributes.frame.height
                : 0
            return document.globalCharacterOffset(
                chunkIndex: chunkIndex,
                localCharacterOffset: Int(
                    (CGFloat(chunk.characterCount) * fraction).rounded()
                )
            )
        }

        private func reportLayoutIfNeeded(
            in collectionView: UICollectionView
        ) {
            let maximumOffset = Double(
                max(
                    0,
                    collectionView.collectionViewLayout
                        .collectionViewContentSize.height
                        - collectionView.bounds.height
                )
            )
            guard abs(maximumOffset - lastReportedMaximumOffset) > 1 else {
                return
            }
            lastReportedMaximumOffset = maximumOffset
            reportLayout(
                collectionView,
                characterOffset: visibleCharacterOffset(
                    in: collectionView,
                    exact: true
                )
            )
        }

        private func reportLayout(
            _ collectionView: UICollectionView,
            characterOffset: Int
        ) {
            let maximumOffset = Double(
                max(
                    0,
                    collectionView.collectionViewLayout
                        .collectionViewContentSize.height
                        - collectionView.bounds.height
                )
            )
            let restoredOffset = Double(
                max(0, collectionView.contentOffset.y)
            )
            let callback = parent.onLayoutResolved
            Task { @MainActor in
                await Task.yield()
                callback(
                    maximumOffset,
                    restoredOffset,
                    min(max(0, characterOffset), document.characterCount)
                )
            }
        }

        private func estimatedChunkHeight(
            viewportWidth: CGFloat
        ) -> CGFloat {
            let width = max(
                200,
                viewportWidth
                    - CGFloat(parent.preferences.horizontalMargin * 2)
            )
            let baseFont = UIFont.systemFont(
                ofSize: parent.preferences.fontSize
            )
            let font = UIFontMetrics(forTextStyle: .body).scaledFont(
                for: baseFont
            )
            let approximateCharacterWidth = max(1, font.pointSize * 0.75)
            let charactersPerLine = max(
                1,
                floor(width / approximateCharacterWidth)
            )
            let lines = ceil(
                CGFloat(
                    TeleprompterDocument.targetChunkCharacterCount
                ) / charactersPerLine
            )
            return max(
                120,
                lines
                    * (font.lineHeight + parent.preferences.lineSpacing)
                    + 24
            )
        }
    }
}

@MainActor
final class TeleprompterChunkCell: UICollectionViewCell {
    static let reuseIdentifier = "TeleprompterChunkCell"

    let textView = UITextView(usingTextLayoutManager: true)
    private var representedChunkIndex: Int?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = false
        textView.isScrollEnabled = false
        textView.isUserInteractionEnabled = false
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = true
        contentView.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor
            ),
            textView.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor
            ),
            textView.topAnchor.constraint(equalTo: contentView.topAnchor),
            textView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    func apply(
        attributedText: NSAttributedString,
        chunkIndex: Int,
        horizontalMargin: Double,
        accessibilityValue: String
    ) {
        textView.textContainerInset = UIEdgeInsets(
            top: 12,
            left: horizontalMargin,
            bottom: 12,
            right: horizontalMargin
        )
        if representedChunkIndex != chunkIndex
            || textView.attributedText != attributedText {
            representedChunkIndex = chunkIndex
            textView.attributedText = attributedText
        }
        textView.accessibilityLabel = TeleprompterStrings.title
        textView.accessibilityValue = accessibilityValue
    }

    func caretRect(
        forLocalCharacterOffset requestedOffset: Int
    ) -> CGRect {
        let content = textView.text ?? ""
        let offset = min(max(0, requestedOffset), content.count)
        let index = content.index(
            content.startIndex,
            offsetBy: offset
        )
        let utf16Offset = index.utf16Offset(in: content)
        guard let position = textView.position(
            from: textView.beginningOfDocument,
            offset: utf16Offset
        ) else {
            return .zero
        }
        return textView.caretRect(for: position)
    }

    func localCharacterOffset(closestTo point: CGPoint) -> Int {
        let content = textView.text ?? ""
        guard let position = textView.closestPosition(to: point) else {
            return 0
        }
        let utf16Offset = max(
            0,
            textView.offset(
                from: textView.beginningOfDocument,
                to: position
            )
        )
        let utf16 = content.utf16
        var safeOffset = min(utf16Offset, utf16.count)
        var stringIndex: String.Index?
        while stringIndex == nil, safeOffset > 0 {
            let utf16Index = utf16.index(
                utf16.startIndex,
                offsetBy: safeOffset
            )
            stringIndex = String.Index(utf16Index, within: content)
            if stringIndex == nil {
                safeOffset -= 1
            }
        }
        return content.distance(
            from: content.startIndex,
            to: stringIndex ?? content.startIndex
        )
    }
}
