import Foundation

/// A decoded bank with the lookups every screen needs (plan §7.2).
///
/// Immutable: the bank is a file the owner imports, never edited on the phone
/// (plan D2). Everything the owner *does* with a question lives in SwiftData
/// under the question's id, so replacing this value with a rebuilt bank needs
/// no migration.
public struct ExamBank: Sendable {
    public let document: ExamBankDocument
    public let questionsById: [String: ExamQuestion]
    public let papersById: [String: ExamPaper]
    /// Each paper's questions in booklet order.
    public let questionIdsByPaper: [String: [String]]
    /// Ids of every question Pratik can score, in bank order.
    public let scoreableIds: Set<String>
    public let counts: Counts
    private let appSubjectByOsym: [String: String]

    public struct Counts: Equatable, Sendable {
        public let questions: Int
        public let scoreable: Int
        public let keyless: Int
        public let cancelled: Int
        public let modified: Int
        public let needsHuman: Int
        public let papers: Int
    }

    public enum ValidationError: Error, Equatable, LocalizedError {
        case duplicateQuestion(String)
        case malformedQuestionId(String)
        case unknownPaper(question: String, paper: String)
        case answerOutOfRange(String)
        case optionCount(String)
        case missingProvenance(String)

        public var errorDescription: String? {
            switch self {
            case .duplicateQuestion(let id): return "Aynı kimlikli iki soru var: \(id)"
            case .malformedQuestionId(let id): return "Soru kimliği biçim dışı: \(id)"
            case .unknownPaper(let question, let paper): return "\(question) bilinmeyen kağıda bağlı: \(paper)"
            case .answerOutOfRange(let id): return "\(id) sorusunun cevabı şıkların dışında"
            case .optionCount(let id): return "\(id) sorusunda beş şık yok"
            case .missingProvenance(let id): return "\(id) sorusunun kitapçıktaki yeri yok"
            }
        }
    }

    /// Checks what would otherwise crash or mislead a screen: two questions
    /// under one id (the dictionaries below would trap), an answer index past
    /// the options, a question with no paper or no place in a booklet. The
    /// Mac pipeline already validated the file against the JSON Schema; this
    /// is the phone refusing to trust a file it did not write.
    public init(document: ExamBankDocument) throws {
        var papers: [String: ExamPaper] = [:]
        for paper in document.papers { papers[paper.id] = paper }

        var questions: [String: ExamQuestion] = [:]
        var byPaper: [String: [ExamQuestion]] = [:]
        var scoreable: Set<String> = []
        var keyless = 0, cancelled = 0, modified = 0, needsHuman = 0
        var appSubjects: [String: String] = [:]
        for question in document.questions {
            guard questions[question.id] == nil else { throw ValidationError.duplicateQuestion(question.id) }
            guard let parsed = ExamQuestionID(question.id),
                  parsed.paperId == question.paperId, parsed.number == question.number
            else { throw ValidationError.malformedQuestionId(question.id) }
            guard papers[question.paperId] != nil else {
                throw ValidationError.unknownPaper(question: question.id, paper: question.paperId)
            }
            guard question.options.isEmpty || question.options.count == 5 else {
                throw ValidationError.optionCount(question.id)
            }
            if let answer = question.answer, !question.options.indices.contains(answer) {
                throw ValidationError.answerOutOfRange(question.id)
            }
            guard !question.provenance.isEmpty else { throw ValidationError.missingProvenance(question.id) }

            questions[question.id] = question
            byPaper[question.paperId, default: []].append(question)
            if question.isScoreable { scoreable.insert(question.id) }
            if let osym = question.osymSubject, let app = question.subject, appSubjects[osym] == nil {
                appSubjects[osym] = app
            }
            switch question.status {
            case .ok: break
            case .keyless: keyless += 1
            case .cancelled: cancelled += 1
            case .modified: modified += 1
            case .needsHuman: needsHuman += 1
            }
        }

        self.document = document
        self.questionsById = questions
        self.papersById = papers
        self.questionIdsByPaper = byPaper.mapValues { $0.sorted { $0.number < $1.number }.map(\.id) }
        self.scoreableIds = scoreable
        self.appSubjectByOsym = appSubjects
        self.counts = Counts(
            questions: document.questions.count,
            scoreable: scoreable.count,
            keyless: keyless,
            cancelled: cancelled,
            modified: modified,
            needsHuman: needsHuman,
            papers: papers.count
        )
    }

    public static func decode(_ data: Data) throws -> ExamBank {
        try ExamBank(document: JSONDecoder().decode(ExamBankDocument.self, from: data))
    }

    public var bankVersion: String { document.bankVersion }
    public var questions: [ExamQuestion] { document.questions }
    public var papers: [ExamPaper] { document.papers }

    public func question(_ id: String) -> ExamQuestion? { questionsById[id] }

    public func paper(of question: ExamQuestion) -> ExamPaper? { papersById[question.paperId] }

    /// ÖSYM subjects that actually occur, in booklet order.
    public var osymSubjects: [String] {
        let present = Set(document.questions.compactMap(\.osymSubject))
        return ExamQuestion.osymSubjects.filter(present.contains)
    }

    /// The app subject whose topic list an ÖSYM subject's questions use.
    ///
    /// Read from the questions themselves rather than kept as a table here:
    /// the pipeline already decided each question's `subject`, and a second
    /// hand-kept copy of that mapping would be one more pair to drift.
    public func appSubject(forOsymSubject osymSubject: String) -> String? {
        appSubjectByOsym[osymSubject]
    }

    /// Question count per paper that the sitting shared a time limit with —
    /// `ExamTimeLimit` splits a sitting's limit by it.
    public func sittingQuestionCount(for paper: ExamPaper) -> Int {
        document.papers
            .filter { $0.year == paper.year && $0.session == paper.session }
            .reduce(0) { $0 + $1.questionCount }
    }
}

extension ExamQuestion {
    /// Questions up to this year are "eski": the key reflects the guidelines of
    /// their day (plan D7). Shown, but badged, and one tap filters them out.
    public static let lastOldYear = 2012

    public var year: Int? { ExamQuestionID(id)?.year }

    public var isOld: Bool { (year ?? Int.max) <= Self.lastOldYear }
}
