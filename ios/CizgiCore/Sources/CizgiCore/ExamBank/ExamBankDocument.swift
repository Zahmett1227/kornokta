import Foundation

// `bank.json` as the phone reads it (docs/PLAN-cikmis-soru-bankasi.md §6).
//
// The Codable twin of `tools/exam_bank/exam_bank.schema.json`, which the Mac
// pipeline validates every package against. The two are one fact written in
// two languages, so `evals/tests/test_exam_bank_contract_sync.py` reads this
// file as text and fails if a property or an enum value exists on one side
// only — the pattern `test_swift_contract_sync.py` set for the card schema.
//
// Enums decode strictly: an unknown status or test would throw and stop the
// import with a message, rather than being mapped to a guess. A new value is a
// new `schemaVersion`, and `ExamBankStore` refuses a version it does not know
// before it gets this far. Unknown *keys* are ignored, as `Codable` always
// does — an added optional field must not break an older build.

public struct ExamBankDocument: Codable, Equatable, Sendable {
    /// The only `schemaVersion` this build understands.
    public static let supportedSchemaVersion = 1

    public let schemaVersion: Int
    /// `2026-09-25.2` — the day it was built and a counter for that day.
    public let bankVersion: String
    /// Version of `subject_topics.json` the topic labels were chosen from.
    public let subjectSchemaVersion: Int
    public let builtAt: String
    public let papers: [ExamPaper]
    public let questions: [ExamQuestion]

    public init(
        schemaVersion: Int = ExamBankDocument.supportedSchemaVersion,
        bankVersion: String,
        subjectSchemaVersion: Int = 1,
        builtAt: String,
        papers: [ExamPaper],
        questions: [ExamQuestion]
    ) {
        self.schemaVersion = schemaVersion
        self.bankVersion = bankVersion
        self.subjectSchemaVersion = subjectSchemaVersion
        self.builtAt = builtAt
        self.papers = papers
        self.questions = questions
    }
}

/// Which booklet of an exam day: Temel, Klinik, or the second Temel test that
/// 2011 İlkbahar and 2012 İlkbahar printed.
public enum ExamTest: String, Codable, CaseIterable, Sendable {
    case temel = "T"
    case klinik = "K"
    case temel2 = "T2"
}

/// "Yanlışların dörtte biri doğruları götürür" is printed in the 2009–2015
/// booklets only; for the rest the rule is assumed and says so (§7.2).
public enum ExamPenalty: String, Codable, CaseIterable, Sendable {
    case quarter
    case unknown
}

public enum ExamSourceKind: String, Codable, CaseIterable, Sendable {
    case osym
    /// ÖSYM's official booklet with ~10% of its questions visible (2022–2026).
    case osymPartial
    case tusdata
    /// The 2026/2 retypeset set of unknown origin.
    case reconstruction
}

public enum ExamKeySource: String, Codable, CaseIterable, Sendable {
    case osym
    case tusdata
    case reconstruction
    /// Spelled out rather than `none`: `.none` on an enum reads as
    /// `Optional.none` wherever the value travels as an optional.
    case missing = "none"
}

public enum ExamAnswerSource: String, Codable, CaseIterable, Sendable {
    case osym
    case tusdata
    case reconstruction
}

public enum ExamQuestionStatus: String, Codable, CaseIterable, Sendable {
    case ok
    case cancelled
    /// 2006–2008 and most of 2024/1: the question is real, no key exists.
    case keyless
    /// The compiler rewrote the question ("modifiye edilmiştir"); ÖSYM's own
    /// text is not what the bank carries.
    case modified
    case needsHuman
}

public enum ExamFigure: String, Codable, CaseIterable, Sendable {
    /// `none` in the file; see `ExamKeySource.missing` for the name.
    case absent = "none"
    /// The text points at a figure ("yukarıdaki grafikte") but none was found
    /// inside the question's box.
    case reference
    /// A figure is printed inside the question: the text alone cannot be
    /// answered, the crop has to be shown.
    case required
}

public enum ExamTextQuality: String, Codable, CaseIterable, Sendable {
    case native
    case repaired
    case vision
}

public enum ExamTextSource: String, Codable, CaseIterable, Sendable {
    case osym
    case tusdata
    case reconstruction
}

public enum ExamSourceFamily: String, Codable, CaseIterable, Sendable {
    case f1 = "F1", f2 = "F2", f3 = "F3", f4 = "F4", f5 = "F5", f6 = "F6"
}

public struct ExamPaperSource: Codable, Equatable, Sendable {
    /// `pdf/<sha256>.pdf`, relative to the package.
    public let pdf: String
    public let family: ExamSourceFamily
    public let sourceKind: ExamSourceKind
    public let keySource: ExamKeySource

    public init(pdf: String, family: ExamSourceFamily, sourceKind: ExamSourceKind, keySource: ExamKeySource) {
        self.pdf = pdf
        self.family = family
        self.sourceKind = sourceKind
        self.keySource = keySource
    }
}

public struct ExamPaper: Codable, Equatable, Sendable, Identifiable {
    /// `TUS-2019-1-T`.
    public let id: String
    public let year: Int
    /// 1 = İlkbahar, 2 = Sonbahar.
    public let session: Int
    public let test: ExamTest
    /// `2019-02-24`, when the booklet prints it.
    public let date: String?
    public let questionCount: Int
    /// This test's own limit, when the booklet states one (2012–2015).
    public let timeLimitMinutes: Int?
    /// The whole sitting's limit, when only that is stated (2009–2011: 210
    /// minutes for the Temel and Klinik tests together).
    public let sessionTimeLimitMinutes: Int?
    public let penalty: ExamPenalty
    public let sourceKind: ExamSourceKind
    public let keySource: ExamKeySource
    public let sources: [ExamPaperSource]

    public init(
        id: String,
        year: Int,
        session: Int,
        test: ExamTest,
        date: String? = nil,
        questionCount: Int,
        timeLimitMinutes: Int? = nil,
        sessionTimeLimitMinutes: Int? = nil,
        penalty: ExamPenalty = .unknown,
        sourceKind: ExamSourceKind = .osym,
        keySource: ExamKeySource = .osym,
        sources: [ExamPaperSource] = []
    ) {
        self.id = id
        self.year = year
        self.session = session
        self.test = test
        self.date = date
        self.questionCount = questionCount
        self.timeLimitMinutes = timeLimitMinutes
        self.sessionTimeLimitMinutes = sessionTimeLimitMinutes
        self.penalty = penalty
        self.sourceKind = sourceKind
        self.keySource = keySource
        self.sources = sources
    }
}

/// Where a question sits in a packaged PDF.
public struct ExamRegion: Codable, Equatable, Hashable, Sendable {
    /// `pdf/<sha256>.pdf`, relative to the package.
    public let pdf: String
    /// 1-based page of the *packaged* PDF (ÖSYM's partial booklets were cut to
    /// their visible pages, and their regions renumbered with them).
    public let page: Int
    /// `[x0, top, x1, bottom]` in points, top-left origin — pdfplumber's
    /// convention. `ExamPageGeometry` turns it into PDFKit's.
    public let bbox: [Double]

    public init(pdf: String, page: Int, bbox: [Double]) {
        self.pdf = pdf
        self.page = page
        self.bbox = bbox
    }
}

public struct ExamQuestion: Codable, Equatable, Sendable, Identifiable {
    /// `TUS-2019-1-T-045`. Stable: once given, never given to another
    /// question — every piece of user state hangs off it (docs/ADR-012).
    public let id: String
    public let paperId: String
    public let number: Int
    public let stem: String
    /// A–E in order; empty only for a cancelled slot whose text the booklet
    /// replaced with "Bu soru iptal edilmiştir."
    public let options: [String]
    /// 0…4, or `nil` when there is no key.
    public let answer: Int?
    public let answerSource: ExamAnswerSource?
    public let status: ExamQuestionStatus
    /// ÖSYM's subject name — twelve of them, Histoloji-Embriyoloji included.
    public let osymSubject: String?
    /// The app's canonical subject (`subject_topics.json`), whose topic list
    /// `topic` comes from. Histoloji-Embriyoloji maps to Fizyoloji (plan Ek C).
    public let subject: String?
    public let topic: String?
    public let figure: ExamFigure
    public let provenance: [ExamRegion]
    /// The same question in another source (a compilation beside ÖSYM's own
    /// booklet). Shown on request, never instead of `provenance`.
    public let altProvenance: [ExamRegion]
    public let textQuality: ExamTextQuality
    public let textSource: ExamTextSource
    /// The number the booklet actually printed, when it misprinted it.
    public let printedAs: Int?
    /// Near-identical questions from other years; never queued together.
    public let similarTo: [String]

    public init(
        id: String,
        paperId: String,
        number: Int,
        stem: String,
        options: [String],
        answer: Int?,
        answerSource: ExamAnswerSource? = .osym,
        status: ExamQuestionStatus = .ok,
        osymSubject: String? = nil,
        subject: String? = nil,
        topic: String? = nil,
        figure: ExamFigure = .absent,
        provenance: [ExamRegion] = [],
        altProvenance: [ExamRegion] = [],
        textQuality: ExamTextQuality = .native,
        textSource: ExamTextSource = .osym,
        printedAs: Int? = nil,
        similarTo: [String] = []
    ) {
        self.id = id
        self.paperId = paperId
        self.number = number
        self.stem = stem
        self.options = options
        self.answer = answer
        self.answerSource = answerSource
        self.status = status
        self.osymSubject = osymSubject
        self.subject = subject
        self.topic = topic
        self.figure = figure
        self.provenance = provenance
        self.altProvenance = altProvenance
        self.textQuality = textQuality
        self.textSource = textSource
        self.printedAs = printedAs
        self.similarTo = similarTo
    }

    /// ÖSYM's twelve subjects in booklet order: the seven Temel subjects, then
    /// the five Klinik ones. The same list, in the same order, is the schema's
    /// `osymSubject` enum — the contract test holds them together.
    public static let osymSubjects = [
        "Anatomi", "Histoloji-Embriyoloji", "Fizyoloji", "Biyokimya", "Mikrobiyoloji", "Patoloji",
        "Farmakoloji", "Dahiliye", "Pediatri", "Genel Cerrahi", "Kadın Hastalıkları ve Doğum",
        "Küçük Stajlar",
    ]

    /// Can be answered and marked right or wrong: an ordinary question with
    /// its five options and a key. Everything Pratik scores comes from here.
    public var isScoreable: Bool {
        status == .ok && options.count == 5 && answer.map { (0..<5).contains($0) } == true
    }

    /// Answerable but not markable — shown only under "Anahtarsız — yalnız
    /// oku" (plan D6).
    public var isReadOnly: Bool {
        status == .keyless && options.count == 5
    }

    /// The correct option's text, when there is a key.
    public var correctOptionText: String? {
        guard let answer, options.indices.contains(answer) else { return nil }
        return options[answer]
    }

    /// The figure is part of what has to be looked at.
    public var hasFigure: Bool { figure != .absent }
}
