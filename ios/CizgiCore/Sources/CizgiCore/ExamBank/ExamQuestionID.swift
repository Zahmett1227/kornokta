import Foundation

/// A past exam question's stable name, `TUS-2019-1-T-045`, taken apart.
///
/// The id is the one thing every piece of user state keeps (docs/ADR-012):
/// attempts, bridge links and the gap ledger all survive a rebuilt bank
/// because of it. The format is the schema's `question.id` pattern.
public struct ExamQuestionID: Hashable, Sendable, CustomStringConvertible {
    public let year: Int
    /// 1 = İlkbahar, 2 = Sonbahar.
    public let session: Int
    public let test: ExamTest
    public let number: Int

    public init(year: Int, session: Int, test: ExamTest, number: Int) {
        self.year = year
        self.session = session
        self.test = test
        self.number = number
    }

    /// `nil` for anything that is not exactly `TUS-<20yy>-<1|2>-<T|K|T2>-<nnn>`.
    public init?(_ raw: String) {
        let parts = raw.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 5, parts[0] == "TUS",
              parts[1].count == 4, parts[1].hasPrefix("20"), let year = Int(parts[1]),
              parts[2] == "1" || parts[2] == "2", let session = Int(parts[2]),
              let test = ExamTest(rawValue: String(parts[3])),
              parts[4].count == 3, parts[4].allSatisfy(\.isASCIIDigit), let number = Int(parts[4]),
              number >= 1
        else { return nil }
        self.init(year: year, session: session, test: test, number: number)
    }

    public var rawValue: String {
        "\(paperId)-\(String(format: "%03d", number))"
    }

    public var description: String { rawValue }

    /// `TUS-2019-1-T` — the paper the question belongs to.
    public var paperId: String {
        "TUS-\(year)-\(session)-\(test.rawValue)"
    }

    /// `2019/1 T45` — short enough for a list row (plan §7.6).
    public var shortLabel: String {
        "\(year)/\(session) \(test.rawValue)\(number)"
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
