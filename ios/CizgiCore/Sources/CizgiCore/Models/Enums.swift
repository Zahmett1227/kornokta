import Foundation

/// Job states for a captured page (ANA-PLAN §17).
///
/// The order here is the happy path; `ProcessingState.canTransition(to:)` is the
/// authority on which moves are legal.
public enum ProcessingState: String, Codable, Sendable, CaseIterable {
    case captured
    case localPreprocessing = "local_preprocessing"
    case localOCR = "local_ocr"
    case markerDetection = "marker_detection"
    case cloudOCR = "cloud_ocr"
    case transcriptionReconciliation = "transcription_reconciliation"
    case confirmationRequired = "confirmation_required"
    case cardGeneration = "card_generation"
    case qualityValidation = "quality_validation"
    case ready
    case temporaryFailure = "temporary_failure"
    case permanentFailure = "permanent_failure"
    case cancelled

    /// A state the queue will not advance on its own.
    public var isTerminal: Bool {
        switch self {
        case .ready, .permanentFailure, .cancelled: return true
        default: return false
        }
    }

    /// Waiting on the user, not on the machine (§6.4).
    public var needsUser: Bool {
        self == .confirmationRequired || self == .permanentFailure
    }
}

/// How a passage was marked (§16.3).
public enum SelectionType: String, Codable, Sendable {
    case underline
    case highlight
    case marginMark = "margin_mark"
    case handwriting
    case manual
}

public enum LayoutKind: String, Codable, Sendable {
    case paragraph
    case bullet
    case column
    case tableCandidate = "table_candidate"
    case unknown
}

/// MVP card types (§13.1). Multiple choice is deliberately absent — §13.3 keeps
/// it off by default for the first release.
public enum CardType: String, Codable, Sendable, CaseIterable {
    case directRecall = "direct_recall"
    case cloze
    case mechanism
    case distinction
    case exceptionTrap = "exception_trap"
    /// Five options, exactly one correct (ANA-PLAN §13.3). Schema v2.1.
    ///
    /// Cards of every other type stay exactly as they were; this one carries
    /// `Card.optionsRaw`/`correctOptionIndex` alongside the usual front/back.
    case multipleChoice = "multiple_choice"
}

public enum CardStatus: String, Codable, Sendable {
    case active
    case suspended
    case draft
    case needsReview = "needs_review"
}

/// A mark's tier, from the canonical §14 contract (schema v2.3,
/// docs/PLAN-kapsama-sozlesmesi.md).
///
/// The fourth "same facts in three languages" pair in this repo: this enum, the
/// schema's `marks.items.kind` enum and `MARK_KINDS` in `llmOutputTypes.ts` are
/// one list, locked by `evals/tests/test_swift_contract_sync.py` and its TS
/// sibling. Both readers — the generator's own register and the independent
/// auditor — speak it, which is what makes their two answers mergeable.
///
/// **Declaration order is the priority ladder** of prompt rule 3: a handwritten
/// note is the most valuable thing the model can skip, a highlighter stroke the
/// least. `PageCoverage` sorts by it, so reordering these cases reorders what
/// the owner is shown first.
///
/// Deliberately separate from `SelectionType`, which looks similar and is not:
/// that one records how a *stored passage* was selected (including `.manual`,
/// which no model ever reports) and predates the vision pivot. Merging them
/// would tie a wire contract to a SwiftData column's history.
public enum MarkKind: String, Codable, Sendable, CaseIterable {
    /// The student's own margin/interline note — the most valuable tier.
    case handwriting
    /// Star, plus, exclamation, arrow, circle, box or frame — the prompt's
    /// `SEMBOL İŞARETLERİ` tier, named once there and once here.
    case symbol
    case underline
    case highlight

    /// Turkish label for the coverage list.
    public var label: String {
        switch self {
        case .handwriting: return "El yazısı"
        case .symbol: return "Sembol"
        case .underline: return "Altı çizili"
        case .highlight: return "Fosforlu"
        }
    }

    /// SF Symbol for the row, matching the tone of the rest of the app.
    public var icon: String {
        switch self {
        case .handwriting: return "hand.draw"
        case .symbol: return "star"
        case .underline: return "underline"
        case .highlight: return "highlighter"
        }
    }
}

/// The four grades the user gives during review (§18.2).
public enum ReviewRating: String, Codable, Sendable, CaseIterable {
    case again
    case hard
    case good
    case easy

    /// Turkish labels shown in the UI.
    public var label: String {
        switch self {
        case .again: return "Unuttum"
        case .hard: return "Zor"
        case .good: return "Bildim"
        case .easy: return "Kolay"
        }
    }
}

/// Risk flags from the canonical LLM contract (§14).
public enum RiskFlag: String, Codable, Sendable, CaseIterable {
    case ocrDisagreement = "ocr_disagreement"
    case handwritingUncertain = "handwriting_uncertain"
    case criticalNumber = "critical_number"
    case criticalUnit = "critical_unit"
    case negationRisk = "negation_risk"
    case symbolRisk = "symbol_risk"
    case drugNameRisk = "drug_name_risk"
    case organismNameRisk = "organism_name_risk"
    case sourceInsufficient = "source_insufficient"
    case sourcePossibleError = "source_possible_error"
    case modelAddedInformation = "model_added_information"
    case duplicateCard = "duplicate_card"
    case ambiguousQuestion = "ambiguous_question"
    case multiplePossibleAnswers = "multiple_possible_answers"
}
