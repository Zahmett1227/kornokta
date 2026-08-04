import Foundation
import CoreGraphics

/// Codable normalized page geometry shared by local detection, the backend OCR
/// snapshot and SwiftUI. Coordinates always use a top-left origin.
public struct NormalizedRect: Codable, Sendable, Equatable, Hashable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(_ rect: CGRect) {
        self.init(x: Double(rect.minX), y: Double(rect.minY), width: Double(rect.width), height: Double(rect.height))
    }

    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    public func union(_ other: NormalizedRect) -> NormalizedRect {
        NormalizedRect(cgRect.union(other.cgRect))
    }

    public func intersects(_ other: NormalizedRect) -> Bool {
        cgRect.intersects(other.cgRect)
    }

    /// Fraction of the smaller non-empty rectangle that overlaps. This is the
    /// intentionally conservative geometry rule used when local and cloud OCR
    /// have unrelated token ids.
    public func overlapOfSmallerArea(with other: NormalizedRect) -> Double {
        let intersection = cgRect.intersection(other.cgRect)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { return 0 }
        let smaller = min(cgRect.width * cgRect.height, other.cgRect.width * other.cgRect.height)
        guard smaller > 0 else { return 0 }
        return Double(intersection.width * intersection.height / smaller)
    }
}

public enum AnnotationType: String, Codable, Sendable, CaseIterable {
    case highlight
    case underline
    case marginMark = "margin_mark"
    case handwriting
    case manual
}

/// Where one visual claim came from. Kept separate from `AnnotationType`
/// (highlight vs underline, what it looks like) because two different sources
/// can independently claim the same physical mark — a manual box drawn over a
/// spot Apple's own pixel detector also flagged, for instance — and merging
/// them into one group must not erase which of them actually fired (§ see
/// `AnnotationGrouper.ground`, `RemoteAnnotationCandidateBuilder`).
public enum AnnotationProvenance: String, Codable, Sendable, Equatable, CaseIterable {
    /// Local pixel measurement over an Apple Vision word box.
    case localToken = "local_token"
    /// Local pixel measurement over a whole Apple Vision line, used only where
    /// no token-level candidate covered the same area (§9, `DetectedMarkerSelector`).
    case localLineFallback = "local_line_fallback"
    /// Google Document AI's own `styleInfo.underlined` flag on a token.
    case remoteUnderlineStyle = "remote_underline_style"
    /// Google Document AI's own `styleInfo.backgroundColor` on a token, after
    /// the same highlighter hue/saturation/value gate local detection uses.
    case remoteBackgroundStyle = "remote_background_style"
    /// The user's own drawn rectangle.
    case manual
}

public enum AnnotationLayoutKind: String, Codable, Sendable, CaseIterable {
    case paragraph
    /// Generic Document AI layout block. It is distinct on the wire even
    /// though persistence currently treats it as paragraph-like content.
    case block
    case bullet
    case column
    case tableCandidate = "table_candidate"
    case unknown
}

/// The image measurements behind a decision. Kept with the evidence rather
/// than only logged, so a user confirmation can explain why it was requested
/// without exposing page text in telemetry.
public struct AnnotationVisualMeasurements: Codable, Sendable, Equatable {
    public let highlightOverlap: Double
    public let underlineDarkRatio: Double
    public let underlineExtentRatio: Double
    public let confidence: Double

    public init(
        highlightOverlap: Double,
        underlineDarkRatio: Double,
        underlineExtentRatio: Double,
        confidence: Double
    ) {
        self.highlightOverlap = highlightOverlap
        self.underlineDarkRatio = underlineDarkRatio
        self.underlineExtentRatio = underlineExtentRatio
        self.confidence = confidence
    }
}

/// A concrete visual mark. This is deliberately richer than the former
/// `[String]` selection seam: choosing a token must not erase which visual
/// claim selected it, how certain that claim was, or where it occurred.
public struct AnnotationEvidence: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let type: AnnotationType
    public let boundingBox: NormalizedRect
    public let lineIds: [String]
    public let tokenIds: [String]
    public let confidence: Double
    public let decision: MarkerDecision
    public let measurements: AnnotationVisualMeasurements?
    public let provenance: AnnotationProvenance

    public init(
        id: String,
        type: AnnotationType,
        boundingBox: NormalizedRect,
        lineIds: [String],
        tokenIds: [String] = [],
        confidence: Double,
        decision: MarkerDecision,
        measurements: AnnotationVisualMeasurements? = nil,
        provenance: AnnotationProvenance = .localToken
    ) {
        self.id = id
        self.type = type
        self.boundingBox = boundingBox
        self.lineIds = lineIds
        self.tokenIds = tokenIds
        self.confidence = confidence
        self.decision = decision
        self.measurements = measurements
        self.provenance = provenance
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decode(AnnotationType.self, forKey: .type)
        boundingBox = try container.decode(NormalizedRect.self, forKey: .boundingBox)
        lineIds = try container.decode([String].self, forKey: .lineIds)
        tokenIds = try container.decodeIfPresent([String].self, forKey: .tokenIds) ?? []
        confidence = try container.decode(Double.self, forKey: .confidence)
        decision = try container.decode(MarkerDecision.self, forKey: .decision)
        measurements = try container.decodeIfPresent(AnnotationVisualMeasurements.self, forKey: .measurements)
        // Absent on any OCRSnapshot persisted before provenance existed. Every
        // evidence produced before this change came from local token-level
        // detection, so defaulting there reproduces its old, already-tested
        // gating exactly instead of guessing at a new one.
        provenance = try container.decodeIfPresent(AnnotationProvenance.self, forKey: .provenance) ?? .localToken
    }
}

/// One independently meaningful marked information unit on a page. `selected`
/// is kept separate from `context`: a short underline such as “hipoksi” is not
/// inflated into the full sentence, yet the generator receives enough source
/// text to make an unambiguous card.
public struct AnnotationGroup: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let evidenceIds: [String]
    public let selectedLineIds: [String]
    public let contextLineIds: [String]
    public let selectedTokenIds: [String]
    public let contextTokenIds: [String]
    public let handwrittenNoteIds: [String]
    public let boundingBox: NormalizedRect
    public let parentHeading: String?
    public let layoutKind: AnnotationLayoutKind
    public let confidence: Double
    public let needsConfirmation: Bool
    public let selectionType: AnnotationType
    public let selectedText: String
    public let contextText: String
    public let handwrittenNotes: [String]

    public init(
        id: String,
        evidenceIds: [String],
        selectedLineIds: [String],
        contextLineIds: [String],
        selectedTokenIds: [String] = [],
        contextTokenIds: [String] = [],
        handwrittenNoteIds: [String] = [],
        boundingBox: NormalizedRect,
        parentHeading: String? = nil,
        layoutKind: AnnotationLayoutKind = .unknown,
        confidence: Double,
        needsConfirmation: Bool,
        selectionType: AnnotationType,
        selectedText: String = "",
        contextText: String = "",
        handwrittenNotes: [String] = []
    ) {
        self.id = id
        self.evidenceIds = evidenceIds
        self.selectedLineIds = selectedLineIds
        self.contextLineIds = contextLineIds
        self.selectedTokenIds = selectedTokenIds
        self.contextTokenIds = contextTokenIds
        self.handwrittenNoteIds = handwrittenNoteIds
        self.boundingBox = boundingBox
        self.parentHeading = parentHeading
        self.layoutKind = layoutKind
        self.confidence = confidence
        self.needsConfirmation = needsConfirmation
        self.selectionType = selectionType
        self.selectedText = selectedText
        self.contextText = contextText
        self.handwrittenNotes = handwrittenNotes
    }

    public func with(
        selectedLineIds: [String]? = nil,
        contextLineIds: [String]? = nil,
        selectedText: String,
        contextText: String,
        selectedTokenIds: [String],
        contextTokenIds: [String],
        handwrittenNoteIds: [String] = [],
        handwrittenNotes: [String] = [],
        parentHeading: String? = nil,
        layoutKind: AnnotationLayoutKind? = nil,
        needsConfirmation: Bool? = nil
    ) -> AnnotationGroup {
        AnnotationGroup(
            id: id,
            evidenceIds: evidenceIds,
            selectedLineIds: selectedLineIds ?? self.selectedLineIds,
            contextLineIds: contextLineIds ?? self.contextLineIds,
            selectedTokenIds: selectedTokenIds,
            contextTokenIds: contextTokenIds,
            handwrittenNoteIds: handwrittenNoteIds,
            boundingBox: boundingBox,
            parentHeading: parentHeading ?? self.parentHeading,
            layoutKind: layoutKind ?? self.layoutKind,
            confidence: confidence,
            needsConfirmation: needsConfirmation ?? self.needsConfirmation,
            selectionType: selectionType,
            selectedText: selectedText,
            contextText: contextText,
            handwrittenNotes: handwrittenNotes
        )
    }

    public func markedConfirmed() -> AnnotationGroup {
        AnnotationGroup(
            id: id,
            evidenceIds: evidenceIds,
            selectedLineIds: selectedLineIds,
            contextLineIds: contextLineIds,
            selectedTokenIds: selectedTokenIds,
            contextTokenIds: contextTokenIds,
            handwrittenNoteIds: handwrittenNoteIds,
            boundingBox: boundingBox,
            parentHeading: parentHeading,
            layoutKind: layoutKind,
            confidence: confidence,
            needsConfirmation: false,
            selectionType: selectionType,
            selectedText: selectedText,
            contextText: contextText,
            handwrittenNotes: handwrittenNotes
        )
    }
}

public struct MarkerSelectionResult: Codable, Sendable, Equatable {
    public let evidence: [AnnotationEvidence]
    public let groups: [AnnotationGroup]
    public let autoSelectedGroupIds: [String]

    public init(
        evidence: [AnnotationEvidence] = [],
        groups: [AnnotationGroup] = [],
        autoSelectedGroupIds: [String] = []
    ) {
        self.evidence = evidence
        self.groups = groups
        self.autoSelectedGroupIds = autoSelectedGroupIds
    }

    public var selectedLineIds: [String] {
        let ids = Set(autoSelectedGroupIds)
        return groups.filter { ids.contains($0.id) }.flatMap(\.selectedLineIds)
    }

    public var needsConfirmation: Bool {
        groups.contains(where: \.needsConfirmation)
    }
}

/// A device-local, JSON-encoded OCR checkpoint. It makes confirmation a
/// continuation of a completed OCR run, rather than a second paid Document AI
/// call (or an incorrect Apple Vision re-read).
public struct OCRSnapshot: Codable, Sendable, Equatable {
    public let localLines: [LocalLine]
    public let remote: RemoteRecognition?
    public let selection: MarkerSelectionResult
    public let createdAt: Date
    /// Set only by an explicit photo-based confirmation action. It never
    /// relaxes deterministic token gates on its own; it only prevents the same
    /// already-answered visual question from reappearing on resume.
    public let userConfirmed: Bool

    public init(
        localLines: [LocalLine],
        remote: RemoteRecognition?,
        selection: MarkerSelectionResult,
        createdAt: Date = .now,
        userConfirmed: Bool = false
    ) {
        self.localLines = localLines
        self.remote = remote
        self.selection = selection
        self.createdAt = createdAt
        self.userConfirmed = userConfirmed
    }

    public var recognizedPage: RecognizedPage {
        RecognizedPage(
            lines: localLines.map(RecognizedLine.init),
            elapsed: 0
        )
    }

    public static func == (lhs: OCRSnapshot, rhs: OCRSnapshot) -> Bool {
        // Capture time is auditing metadata, not OCR content. Excluding it
        // keeps an idempotent pipeline replay equal to its first result.
        lhs.localLines == rhs.localLines
            && lhs.remote == rhs.remote
            && lhs.selection == rhs.selection
            && lhs.userConfirmed == rhs.userConfirmed
    }
}
