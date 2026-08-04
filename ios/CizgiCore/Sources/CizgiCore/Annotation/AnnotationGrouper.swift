import Foundation

/// Deterministic page-grounding pass. It intentionally uses only geometry and
/// the OCR snapshot: an LLM may later interpret relationships, but cannot
/// upgrade a missing visual selection into an automatic card (§0.5, §0.8).
public enum AnnotationGrouper {
    /// Resolves local marker evidence against the primary (Google) OCR result,
    /// merges nearby evidence into independent information groups and keeps
    /// uncertain handwriting as a confirmation candidate.
    public static func ground(
        selection: MarkerSelectionResult,
        localPage: RecognizedPage,
        remotePage: RemotePage?,
        discoverHandwriting: Bool = true
    ) -> MarkerSelectionResult {
        guard let remotePage else {
            return groundLocally(selection: selection, page: localPage)
        }

        var groups = merge(selection.groups)
        groups = groups.map { group in
            let selectedTokens = matchingTokens(for: group.boundingBox, tokens: remotePage.tokens)
            let directLines = matchingLines(for: group.boundingBox, lines: remotePage.lines)
            // A short underline may only cover the end of its source line. Token
            // membership is then a stronger grounding signal than box overlap.
            let tokenLines = directLines.isEmpty
                ? remotePage.lines.filter { line in
                    selectedTokens.contains { token in line.tokenIds.contains(token.tokenId) }
                }
                : directLines
            // A manual box is a deliberate, explicit user selection, not a
            // guess to be filtered by the same overlap threshold that guards
            // automatic detection against false positives. If it missed
            // every line/token by a hair, ground it to the nearest line
            // rather than bouncing the whole submission with an empty
            // passage (found via real device use, 2026-08-04).
            let selectedLines = tokenLines.isEmpty && group.selectionType == .manual
                ? nearestLine(to: group.boundingBox, in: remotePage.lines).map { [$0] } ?? []
                : tokenLines
            let selectedText = selectedTokens.isEmpty
                ? selectedLines.map(\.text).joined(separator: " ")
                : selectedTokens.map(\.text).joined(separator: " ")
            let contextLines = context(for: selectedLines, group: group, all: remotePage.lines)
            let contextTokens = remotePage.tokens.filter { token in
                contextLines.contains { $0.tokenIds.contains(token.tokenId) }
            }
            // Confirmation passes the user's chosen groups back in. Re-running
            // discovery there would resurrect a handwriting candidate they
            // explicitly rejected.
            let handNotes = discoverHandwriting
                ? nearbyHandwrittenTokens(for: group, from: remotePage.tokens)
                : remotePage.tokens.filter { group.handwrittenNoteIds.contains($0.tokenId) }
            let layoutKind = layoutKind(for: group, lines: contextLines, tables: remotePage.tables)
            let heading = parentHeading(for: group, lines: remotePage.lines)
            return group.with(
                selectedLineIds: selectedLines.map(\.lineId),
                contextLineIds: contextLines.map(\.lineId),
                selectedText: selectedText,
                contextText: contextLines.map(\.text).joined(separator: " "),
                selectedTokenIds: selectedTokens.map(\.tokenId),
                contextTokenIds: contextTokens.map(\.tokenId),
                handwrittenNoteIds: handNotes.map(\.tokenId),
                handwrittenNotes: handNotes.map(\.text),
                parentHeading: heading,
                layoutKind: layoutKind,
                // A handwriting relationship is an explicitly uncertain
                // visual claim until the user attaches or rejects it.
                needsConfirmation: group.needsConfirmation || (discoverHandwriting && !handNotes.isEmpty)
            )
        }

        // A margin note far from all marked information stays a separate,
        // pending candidate rather than being attached to a random paragraph.
        let attachedHandwriting = Set(groups.flatMap(\.handwrittenNoteIds))
        for token in remotePage.tokens where discoverHandwriting && token.isHandwritten && !attachedHandwriting.contains(token.tokenId) {
            let box = token.boundingBox
            groups.append(
                AnnotationGroup(
                    id: "handwriting_\(token.tokenId)",
                    evidenceIds: [],
                    selectedLineIds: [],
                    contextLineIds: [],
                    selectedTokenIds: [],
                    contextTokenIds: [],
                    handwrittenNoteIds: [token.tokenId],
                    boundingBox: box,
                    layoutKind: .unknown,
                    confidence: token.confidence,
                    needsConfirmation: true,
                    selectionType: .handwriting,
                    selectedText: "",
                    contextText: "",
                    handwrittenNotes: [token.text]
                )
            )
        }

        let auto = groups
            .filter { !$0.needsConfirmation && $0.selectionType != .handwriting }
            .map(\.id)
        return MarkerSelectionResult(evidence: selection.evidence, groups: groups, autoSelectedGroupIds: auto)
    }

    private static func groundLocally(
        selection: MarkerSelectionResult,
        page: RecognizedPage
    ) -> MarkerSelectionResult {
        let lines = Dictionary(uniqueKeysWithValues: page.lines.map { ($0.id, $0) })
        let groups = merge(selection.groups).map { group in
            let explicit = group.selectedLineIds.compactMap { lines[$0] }
            // A freehand confirmation rectangle has no line id. Ground it
            // against local Vision geometry so offline confirmation is usable.
            let overlapping = explicit.isEmpty
                ? page.lines.filter { line in
                    group.boundingBox.overlapOfSmallerArea(with: NormalizedRect(line.box)) >= 0.25
                        || contains(group.boundingBox, NormalizedRect(line.box).center)
                }
                : explicit
            // Same reasoning as the remote path above: a manual box always
            // grounds to something rather than coming back empty.
            let selected = overlapping.isEmpty && group.selectionType == .manual
                ? nearestLocalLine(to: group.boundingBox, in: page.lines).map { [$0] } ?? []
                : overlapping
            return group.with(
                selectedLineIds: selected.map(\.id),
                contextLineIds: selected.map(\.id),
                selectedText: selected.map(\.text).joined(separator: " "),
                contextText: selected.map(\.text).joined(separator: " "),
                selectedTokenIds: selected.flatMap { $0.tokens.map(\.id) },
                contextTokenIds: selected.flatMap { $0.tokens.map(\.id) }
            )
        }
        return MarkerSelectionResult(
            evidence: selection.evidence,
            groups: groups,
            autoSelectedGroupIds: groups.filter { !$0.needsConfirmation }.map(\.id)
        )
    }

    /// Merge only visually contiguous evidence in the same horizontal region.
    /// This joins a three-line mechanism list while preserving two instances
    /// of the same phrase in distant reversible/irreversible boxes.
    private static func merge(_ input: [AnnotationGroup]) -> [AnnotationGroup] {
        var remaining = input.sorted {
            $0.boundingBox.y == $1.boundingBox.y
                ? $0.boundingBox.x < $1.boundingBox.x
                : $0.boundingBox.y < $1.boundingBox.y
        }
        var result: [AnnotationGroup] = []
        while let first = remaining.first {
            remaining.removeFirst()
            var cluster = [first]
            var changed = true
            while changed {
                changed = false
                let clusterBounds = cluster.map(\.boundingBox).reduce(first.boundingBox) { $0.union($1) }
                var index = 0
                while index < remaining.count {
                    if cluster.allSatisfy({ $0.selectionType != .manual })
                        && remaining[index].selectionType != .manual
                        && shouldMerge(clusterBounds, remaining[index].boundingBox) {
                        cluster.append(remaining.remove(at: index))
                        changed = true
                    } else {
                        index += 1
                    }
                }
            }
            let bounds = cluster.map(\.boundingBox).reduce(first.boundingBox) { $0.union($1) }
            let confidence = cluster.map(\.confidence).reduce(0, +) / Double(cluster.count)
            result.append(
                AnnotationGroup(
                    id: first.id,
                    evidenceIds: cluster.flatMap(\.evidenceIds),
                    selectedLineIds: unique(cluster.flatMap(\.selectedLineIds)),
                    contextLineIds: unique(cluster.flatMap(\.contextLineIds)),
                    selectedTokenIds: unique(cluster.flatMap(\.selectedTokenIds)),
                    contextTokenIds: unique(cluster.flatMap(\.contextTokenIds)),
                    boundingBox: bounds,
                    confidence: confidence,
                    needsConfirmation: cluster.contains(where: \.needsConfirmation),
                    selectionType: first.selectionType
                )
            )
        }
        return result
    }

    private static func shouldMerge(_ lhs: NormalizedRect, _ rhs: NormalizedRect) -> Bool {
        let lhsCenter = lhs.x + lhs.width / 2
        let rhsCenter = rhs.x + rhs.width / 2
        guard abs(lhsCenter - rhsCenter) < 0.34 else { return false }
        let verticalGap = max(lhs.y, rhs.y) - min(lhs.y + lhs.height, rhs.y + rhs.height)
        return verticalGap <= 0.045
    }

    /// Same nearness radius `nearbyHandwrittenTokens` uses below for "close
    /// enough to belong together" — far enough to absorb a manual box that
    /// merely missed its target line's overlap threshold, not so far that a
    /// cloud reading with no relevant content at all gets matched to some
    /// unrelated line elsewhere on the page (that must still bounce to
    /// confirmation instead of silently shipping the wrong text).
    private static let manualFallbackMaxDistance = 0.16

    private static func nearestLine(to box: NormalizedRect, in lines: [RemoteLine]) -> RemoteLine? {
        let center = box.center
        return lines
            .map { ($0, distanceSquared(rect(of: $0).center, center)) }
            .filter { $0.1 <= manualFallbackMaxDistance * manualFallbackMaxDistance }
            .min { $0.1 < $1.1 }?.0
    }

    private static func nearestLocalLine(to box: NormalizedRect, in lines: [RecognizedLine]) -> RecognizedLine? {
        let center = box.center
        return lines
            .map { ($0, distanceSquared(NormalizedRect($0.box).center, center)) }
            .filter { $0.1 <= manualFallbackMaxDistance * manualFallbackMaxDistance }
            .min { $0.1 < $1.1 }?.0
    }

    private static func distanceSquared(_ a: (x: Double, y: Double), _ b: (x: Double, y: Double)) -> Double {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return dx * dx + dy * dy
    }

    private static func matchingLines(for box: NormalizedRect, lines: [RemoteLine]) -> [RemoteLine] {
        lines.filter { line in
            box.overlapOfSmallerArea(with: rect(of: line)) >= 0.3 || contains(box, rect(of: line).center)
        }
    }

    private static func matchingTokens(for box: NormalizedRect, tokens: [RemoteToken]) -> [RemoteToken] {
        tokens.filter { token in
            box.overlapOfSmallerArea(with: token.boundingBox) >= 0.25 || contains(box, token.boundingBox.center)
        }
    }

    private static func context(
        for selected: [RemoteLine],
        group: AnnotationGroup,
        all lines: [RemoteLine]
    ) -> [RemoteLine] {
        guard !selected.isEmpty else { return [] }
        // A selected word expands to its own OCR line, not arbitrary adjacent
        // lines. Several marked lines are already merged as one group above;
        // adding neighbours here would silently pull an unmarked heading or a
        // second bullet into a card.
        guard group.selectionType != .manual else { return selected }
        let selectedBounds = selected.map(rect(of:)).reduce(rect(of: selected[0])) { $0.union($1) }
        let center = selectedBounds.center.x
        let verticalPadding = 0.008
        return lines.filter { line in
            let rect = rect(of: line)
            let sameColumn = abs(rect.center.x - center) < 0.34
            let verticallyRelevant = rect.y + rect.height >= selectedBounds.y - verticalPadding
                && rect.y <= selectedBounds.y + selectedBounds.height + verticalPadding
            return sameColumn && verticallyRelevant
        }
    }

    private static func nearbyHandwrittenTokens(for group: AnnotationGroup, from tokens: [RemoteToken]) -> [RemoteToken] {
        let center = group.boundingBox.center
        return tokens.filter { token in
            guard token.isHandwritten else { return false }
            let other = token.boundingBox.center
            let dx = other.x - center.x
            let dy = other.y - center.y
            return (dx * dx + dy * dy).squareRoot() <= 0.16
        }
    }

    private static func layoutKind(
        for group: AnnotationGroup,
        lines: [RemoteLine],
        tables: [RemoteLayoutRegion]
    ) -> AnnotationLayoutKind {
        if tables.contains(where: { $0.boundingBox.overlapOfSmallerArea(with: group.boundingBox) >= 0.2 }) {
            return .tableCandidate
        }
        if lines.contains(where: { $0.text.trimmingCharacters(in: .whitespaces).hasPrefix("•") || $0.text.trimmingCharacters(in: .whitespaces).hasPrefix("-") }) {
            return .bullet
        }
        return .paragraph
    }

    private static func parentHeading(for group: AnnotationGroup, lines: [RemoteLine]) -> String? {
        let center = group.boundingBox.center.x
        return lines
            .filter { line in
                let box = rect(of: line)
                return box.y + box.height <= group.boundingBox.y
                    && group.boundingBox.y - (box.y + box.height) < 0.10
                    && abs(box.center.x - center) < 0.34
                    && line.text.count <= 90
            }
            .max { rect(of: $0).y < rect(of: $1).y }?
            .text
    }

    private static func rect(of line: RemoteLine) -> NormalizedRect {
        NormalizedRect(x: line.x, y: line.y, width: line.width, height: line.height)
    }

    private static func contains(_ rect: NormalizedRect, _ point: (x: Double, y: Double)) -> Bool {
        point.x >= rect.x && point.x <= rect.x + rect.width && point.y >= rect.y && point.y <= rect.y + rect.height
    }

    private static func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }
}

private extension NormalizedRect {
    var center: (x: Double, y: Double) { (x + width / 2, y + height / 2) }
}
