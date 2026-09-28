import Foundation
@testable import CizgiCore

/// A small synthetic bank for the Çıkmış tests (plan §12: "sentetik küçük
/// banka fikstürü"). Invented questions — no booklet text is committed.
enum ExamBankFixture {
    static let pdfA = "pdf/" + String(repeating: "a", count: 64) + ".pdf"
    static let pdfB = "pdf/" + String(repeating: "b", count: 64) + ".pdf"

    static func paper(
        _ id: String,
        penalty: ExamPenalty = .quarter,
        sourceKind: ExamSourceKind = .osym,
        questionCount: Int = 120,
        timeLimitMinutes: Int? = nil,
        sessionTimeLimitMinutes: Int? = nil
    ) -> ExamPaper {
        let parsed = ExamQuestionID(id + "-001")!
        return ExamPaper(
            id: id,
            year: parsed.year,
            session: parsed.session,
            test: parsed.test,
            questionCount: questionCount,
            timeLimitMinutes: timeLimitMinutes,
            sessionTimeLimitMinutes: sessionTimeLimitMinutes,
            penalty: penalty,
            sourceKind: sourceKind,
            keySource: .osym,
            sources: [ExamPaperSource(pdf: pdfA, family: .f3, sourceKind: sourceKind, keySource: .osym)]
        )
    }

    static func question(
        _ id: String,
        stem: String = "Aşağıdakilerden hangisi doğrudur?",
        options: [String] = ["a", "b", "c", "d", "e"],
        answer: Int? = 2,
        status: ExamQuestionStatus = .ok,
        osymSubject: String? = "Farmakoloji",
        subject: String? = nil,
        topic: String? = nil,
        figure: ExamFigure = .absent,
        similarTo: [String] = [],
        pdf: String = pdfA
    ) -> ExamQuestion {
        let parsed = ExamQuestionID(id)!
        return ExamQuestion(
            id: id,
            paperId: parsed.paperId,
            number: parsed.number,
            stem: stem,
            options: options,
            answer: answer,
            answerSource: answer == nil ? nil : .osym,
            status: status,
            osymSubject: osymSubject,
            subject: subject ?? osymSubject.map { $0 == "Histoloji-Embriyoloji" ? "Fizyoloji" : $0 },
            topic: topic,
            figure: figure,
            provenance: [ExamRegion(pdf: pdf, page: 3, bbox: [40, 100, 295, 200])],
            similarTo: similarTo
        )
    }

    static func document(
        papers: [ExamPaper]? = nil,
        questions: [ExamQuestion],
        version: String = "2026-09-25.1"
    ) -> ExamBankDocument {
        let paperIds = Set(questions.map(\.paperId))
        return ExamBankDocument(
            bankVersion: version,
            builtAt: "2026-09-25T20:00:00+00:00",
            papers: papers ?? paperIds.sorted().map { paper($0) },
            questions: questions
        )
    }

    /// A handful of questions across two papers, subjects and states.
    static var standard: ExamBankDocument {
        document(questions: [
            question("TUS-2019-1-T-001", osymSubject: "Anatomi", topic: "Nöroanatomi"),
            question("TUS-2019-1-T-002", osymSubject: "Histoloji-Embriyoloji"),
            question("TUS-2019-1-T-050", osymSubject: "Farmakoloji", topic: "Otonom Sinir Sistemi"),
            question("TUS-2019-1-T-051", osymSubject: "Farmakoloji", figure: .required),
            question("TUS-2019-1-T-052", options: [], answer: nil, status: .cancelled),
            question("TUS-2011-1-T2-010", osymSubject: "Biyokimya"),
            question("TUS-2007-2-K-003", answer: nil, status: .keyless, osymSubject: "Dahiliye"),
            question("TUS-2024-2-K-101", status: .modified, osymSubject: "Pediatri"),
        ])
    }

    static func json(_ document: ExamBankDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(document)
    }
}

/// xorshift, seeded — the `ExerciseSessionTests` generator.
struct ExamSeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 2_862_933_555_777_941_757 &+ 3_037_000_493 }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
