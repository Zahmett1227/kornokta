import Foundation

/// Privacy-safe, counts-only snapshot of one grounding pass — no OCR text,
/// no image bytes, ever (§7.3). Purely diagnostic: nothing in the pipeline
/// branches on this, it exists so a real-device run can be reasoned about
/// after the fact instead of guessed at.
public struct AnnotationGroundingDiagnostics: Sendable, Equatable {
    /// Echoes the backend's `DOCUMENTAI_COMPUTE_STYLE_INFO` for this call.
    /// Without this, "the style add-on ran and genuinely found nothing" and
    /// "the style add-on was never requested" are indistinguishable from the
    /// candidate counts alone — both leave every remote-style count at 0.
    public let styleInfoRequested: Bool
    public let remoteTokenCount: Int
    public let remoteUnderlinedTokenCount: Int
    public let remoteBackgroundColorTokenCount: Int
    public let remoteHandwrittenTokenCount: Int
    public let localTokenCandidateCount: Int
    public let localLineFallbackCandidateCount: Int
    public let remoteUnderlineCandidateCount: Int
    public let remoteBackgroundCandidateCount: Int
    public let mergedGroupCount: Int
    /// Keyed by `AnnotationProvenance.rawValue`, counted after merge (merge
    /// only clusters groups — it never drops or duplicates evidence).
    public let evidenceCountsByProvenance: [String: Int]

    public init(
        styleInfoRequested: Bool,
        remoteTokenCount: Int,
        remoteUnderlinedTokenCount: Int,
        remoteBackgroundColorTokenCount: Int,
        remoteHandwrittenTokenCount: Int,
        localTokenCandidateCount: Int,
        localLineFallbackCandidateCount: Int,
        remoteUnderlineCandidateCount: Int,
        remoteBackgroundCandidateCount: Int,
        mergedGroupCount: Int,
        evidenceCountsByProvenance: [String: Int]
    ) {
        self.styleInfoRequested = styleInfoRequested
        self.remoteTokenCount = remoteTokenCount
        self.remoteUnderlinedTokenCount = remoteUnderlinedTokenCount
        self.remoteBackgroundColorTokenCount = remoteBackgroundColorTokenCount
        self.remoteHandwrittenTokenCount = remoteHandwrittenTokenCount
        self.localTokenCandidateCount = localTokenCandidateCount
        self.localLineFallbackCandidateCount = localLineFallbackCandidateCount
        self.remoteUnderlineCandidateCount = remoteUnderlineCandidateCount
        self.remoteBackgroundCandidateCount = remoteBackgroundCandidateCount
        self.mergedGroupCount = mergedGroupCount
        self.evidenceCountsByProvenance = evidenceCountsByProvenance
    }
}

/// Deterministic page-grounding pass. It intentionally uses only geometry and
/// the OCR snapshot: an LLM may later interpret relationships, but cannot
/// upgrade a missing visual selection into an automatic card (§0.5, §0.8).
public enum AnnotationGrouper {
    /// Builds the counts-only diagnostic snapshot for one `ground(...)` call.
    /// Pure and side-effect free on purpose — logging (DEBUG-only, §7.3) is
    /// the caller's job (`CapturePipeline`), so this stays independently
    /// testable without capturing console output.
    public static func diagnostics(
        initialSelection: MarkerSelectionResult,
        groundedSelection: MarkerSelectionResult,
        remotePage: RemotePage?,
        styleInfoRequested: Bool
    ) -> AnnotationGroundingDiagnostics {
        let remoteTokens = remotePage?.tokens ?? []
        func localCandidateCount(_ provenance: AnnotationProvenance) -> Int {
            initialSelection.evidence.filter { $0.provenance == provenance }.count
        }
        var byProvenance: [String: Int] = [:]
        for item in groundedSelection.evidence {
            byProvenance[item.provenance.rawValue, default: 0] += 1
        }
        return AnnotationGroundingDiagnostics(
            styleInfoRequested: styleInfoRequested,
            remoteTokenCount: remoteTokens.count,
            remoteUnderlinedTokenCount: remoteTokens.filter(\.isUnderlined).count,
            remoteBackgroundColorTokenCount: remoteTokens.filter { $0.backgroundColor != nil }.count,
            remoteHandwrittenTokenCount: remoteTokens.filter(\.isHandwritten).count,
            localTokenCandidateCount: localCandidateCount(.localToken),
            localLineFallbackCandidateCount: localCandidateCount(.localLineFallback),
            remoteUnderlineCandidateCount: byProvenance[AnnotationProvenance.remoteUnderlineStyle.rawValue] ?? 0,
            remoteBackgroundCandidateCount: byProvenance[AnnotationProvenance.remoteBackgroundStyle.rawValue] ?? 0,
            mergedGroupCount: groundedSelection.groups.count,
            evidenceCountsByProvenance: byProvenance
        )
    }

    /// Resolves local marker evidence against the primary (Google) OCR result,
    /// merges nearby evidence into independent information groups and keeps
    /// uncertain handwriting as a confirmation candidate.
    ///
    /// - Parameter config: Forwarded to `RemoteAnnotationCandidateBuilder` for
    ///   its backgroundColor highlighter gate. `nil` simply skips
    ///   backgroundColor-based candidates for this run (see that type's doc
    ///   comment) — `isUnderlined`-based candidates are unaffected.
    public static func ground(
        selection: MarkerSelectionResult,
        localPage: RecognizedPage,
        remotePage: RemotePage?,
        discoverHandwriting: Bool = true,
        config: MarkerConfig? = nil
    ) -> MarkerSelectionResult {
        guard let remotePage else {
            return groundLocally(selection: selection, page: localPage)
        }

        // Google's own style signals (isUnderlined, backgroundColor) become
        // ordinary candidate groups here, alongside whatever Apple/local pixel
        // detection already found — so a mark Apple never tokenized (it
        // cannot read Turkish reliably, ADR-002) still reaches the merge step
        // instead of only being usable to ground a *pre-existing* group.
        let remoteCandidates = RemoteAnnotationCandidateBuilder.build(from: remotePage, config: config)
        let combinedEvidence = selection.evidence + remoteCandidates.evidence
        let evidenceById = Dictionary(uniqueKeysWithValues: combinedEvidence.map { ($0.id, $0) })

        var groups = merge(selection.groups + remoteCandidates.groups, evidenceById: evidenceById)
        groups = groups.map { group in
            let selectedTokens = matchingTokens(for: group.boundingBox, tokens: remotePage.tokens)
            let directLines = matchingLines(for: group.boundingBox, lines: remotePage.lines)
            // A short underline may only cover the end of its source line. Token
            // membership is then a stronger grounding signal than box overlap.
            let selectedLines = directLines.isEmpty
                ? remotePage.lines.filter { line in
                    selectedTokens.contains { token in line.tokenIds.contains(token.tokenId) }
                }
                : directLines
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
            // No line or token resolved at all — including a manual box that
            // missed every line by more than a genuine overlap — must never
            // read as a silently-grounded passage (§0.5). It stays in the
            // result with its bounding box intact and forced to
            // confirmation, rather than guessing at the nearest line or
            // vanishing from the submission (found via real device use,
            // 2026-08-04; superseded here — a wrong guess is worse than
            // asking, and the crop itself is preserved for a future
            // photo-based/manual-text review instead).
            let unresolved = selectedLines.isEmpty && selectedTokens.isEmpty
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
                needsConfirmation: unresolved || group.needsConfirmation || (discoverHandwriting && !handNotes.isEmpty)
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
        return MarkerSelectionResult(evidence: combinedEvidence, groups: groups, autoSelectedGroupIds: auto)
    }

    private static func groundLocally(
        selection: MarkerSelectionResult,
        page: RecognizedPage
    ) -> MarkerSelectionResult {
        let lines = Dictionary(uniqueKeysWithValues: page.lines.map { ($0.id, $0) })
        let evidenceById = Dictionary(uniqueKeysWithValues: selection.evidence.map { ($0.id, $0) })
        let groups = merge(selection.groups, evidenceById: evidenceById).map { group in
            let explicit = group.selectedLineIds.compactMap { lines[$0] }
            // A freehand confirmation rectangle has no line id. Ground it
            // against local Vision geometry so offline confirmation is usable.
            let overlapping = explicit.isEmpty
                ? page.lines.filter { line in
                    group.boundingBox.overlapOfSmallerArea(with: NormalizedRect(line.box)) >= 0.25
                        || contains(group.boundingBox, NormalizedRect(line.box).center)
                }
                : explicit
            // No meaningful local overlap at all: same rule as the remote
            // path above — never guess at the nearest line, keep the group
            // around unresolved and forced to confirmation instead.
            let unresolved = overlapping.isEmpty
            return group.with(
                selectedLineIds: overlapping.map(\.id),
                contextLineIds: overlapping.map(\.id),
                selectedText: overlapping.map(\.text).joined(separator: " "),
                contextText: overlapping.map(\.text).joined(separator: " "),
                selectedTokenIds: overlapping.flatMap { $0.tokens.map(\.id) },
                contextTokenIds: overlapping.flatMap { $0.tokens.map(\.id) },
                needsConfirmation: unresolved || group.needsConfirmation
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
    ///
    /// A candidate joins a cluster only when it satisfies `shouldMerge`
    /// against **every** current member (complete-linkage), not just the
    /// cluster's overall bounding envelope or any single member. Checking
    /// only the envelope (or only the nearest member, single-linkage) is
    /// exactly what lets a transitive chain form: an unrelated third mark can
    /// sit close enough to a cluster's *aggregate* extent, or to one lone
    /// member, without actually being near the other real marks already in
    /// it. Requiring agreement with every member ties cluster growth to real
    /// content, not to a geometric average nobody's mark actually occupies.
    private static func merge(_ input: [AnnotationGroup], evidenceById: [String: AnnotationEvidence]) -> [AnnotationGroup] {
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
                var index = 0
                while index < remaining.count {
                    let candidate = remaining[index]
                    let eligible = cluster.allSatisfy({ $0.selectionType != .manual }) && candidate.selectionType != .manual
                    if eligible && cluster.allSatisfy({ shouldMerge($0.boundingBox, candidate.boundingBox) }) {
                        cluster.append(remaining.remove(at: index))
                        changed = true
                    } else {
                        index += 1
                    }
                }
            }
            let bounds = cluster.map(\.boundingBox).reduce(first.boundingBox) { $0.union($1) }
            let confidence = cluster.map(\.confidence).reduce(0, +) / Double(cluster.count)
            // A cluster made up *only* of not-yet-calibrated Google-style
            // candidates (no local pixel-verified member at all) must never
            // read as confident just because none of its members individually
            // asked for confirmation for the same reason — there is no real
            // calibration behind that signal yet (§19.2). A cluster that
            // includes at least one local (Apple/manual pixel-measured)
            // candidate keeps exactly its previous, already-tested pessimistic
            // OR across those local members: a remote-style member merely
            // corroborating that spot cannot drag an already-qualified local
            // group back into needing confirmation, but it also cannot grant
            // one on its own.
            let localMembers = cluster.filter { !isRemoteStyleOnly($0, evidenceById: evidenceById) }
            let needsConfirmation = localMembers.isEmpty ? true : localMembers.contains(where: \.needsConfirmation)
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
                    needsConfirmation: needsConfirmation,
                    selectionType: first.selectionType
                )
            )
        }
        return result
    }

    /// Whether every evidence id behind `group` traces back to a Google
    /// style-only candidate (`RemoteAnnotationCandidateBuilder`), as opposed
    /// to any locally/manually sourced one. A group with no evidence ids at
    /// all (should not occur for a real candidate) is treated as local —
    /// never silently treated as "corroborated" from nothing.
    private static func isRemoteStyleOnly(_ group: AnnotationGroup, evidenceById: [String: AnnotationEvidence]) -> Bool {
        guard !group.evidenceIds.isEmpty else { return false }
        return group.evidenceIds.allSatisfy { id in
            switch evidenceById[id]?.provenance {
            case .remoteUnderlineStyle, .remoteBackgroundStyle: return true
            default: return false
            }
        }
    }

    private static func shouldMerge(_ lhs: NormalizedRect, _ rhs: NormalizedRect) -> Bool {
        let lhsCenter = lhs.x + lhs.width / 2
        let rhsCenter = rhs.x + rhs.width / 2
        guard abs(lhsCenter - rhsCenter) < 0.34 else { return false }
        let verticalGap = max(lhs.y, rhs.y) - min(lhs.y + lhs.height, rhs.y + rhs.height)
        return verticalGap <= 0.045
    }

    /// Radius `nearbyHandwrittenTokens` uses for "close enough to belong
    /// together" between a marked region and a handwritten margin note.
    private static let manualFallbackMaxDistance = 0.16

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
            return (dx * dx + dy * dy).squareRoot() <= manualFallbackMaxDistance
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
