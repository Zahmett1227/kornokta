import Foundation
import CoreGraphics

/// Codable normalized page geometry shared by persistence and SwiftUI.
/// Coordinates always use a top-left origin.
///
/// The richer pre-Faz-6 annotation vocabulary (evidence, provenance, visual
/// measurements, `OCRSnapshot`) left with the deterministic pipeline (ADR-005
/// trim, 2026-08-09). What remains is exactly what the vision flow persists:
/// one full-page group per page.
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
}

public enum AnnotationType: String, Codable, Sendable, CaseIterable {
    case highlight
    case underline
    case marginMark = "margin_mark"
    case handwriting
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

/// One independently meaningful marked information unit on a page. In the
/// vision flow there is exactly one per page — the synthetic full-page group
/// `CapturePipeline.fullPageGroup` builds — but persistence
/// (`ProcessingQueue.persist`) still speaks in groups, so the shape stays.
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
}

public struct MarkerSelectionResult: Codable, Sendable, Equatable {
    public let groups: [AnnotationGroup]
    public let autoSelectedGroupIds: [String]

    public init(
        groups: [AnnotationGroup] = [],
        autoSelectedGroupIds: [String] = []
    ) {
        self.groups = groups
        self.autoSelectedGroupIds = autoSelectedGroupIds
    }
}
