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
}

public enum CardStatus: String, Codable, Sendable {
    case active
    case suspended
    case draft
    case needsReview = "needs_review"
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
