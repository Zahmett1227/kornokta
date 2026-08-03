import Foundation

/// A stable, versioned and provider-neutral backup format (ANA-PLAN §24.6).
/// Images are intentionally excluded: the JSON contains the learning data and
/// source quotations, while original copyrighted pages remain on the device.
public enum BackupExporter {
    public static let formatVersion = 1

    public struct CardRecord: Codable, Sendable, Equatable {
        public let id: UUID
        public let type: String
        public let front: String
        public let back: String
        public let explanation: String?
        public let sourceQuote: String?
        public let subject: String?
        public let status: String
        public let dueDate: Date
        public let stability: Double
        public let difficulty: Double
        public let reviewCount: Int
        public let lapseCount: Int

        public init(id: UUID, type: String, front: String, back: String,
                    explanation: String?, sourceQuote: String?, subject: String?,
                    status: String, dueDate: Date, stability: Double,
                    difficulty: Double, reviewCount: Int, lapseCount: Int) {
            self.id = id; self.type = type; self.front = front; self.back = back
            self.explanation = explanation; self.sourceQuote = sourceQuote
            self.subject = subject; self.status = status; self.dueDate = dueDate
            self.stability = stability; self.difficulty = difficulty
            self.reviewCount = reviewCount; self.lapseCount = lapseCount
        }
    }

    private struct Document: Codable {
        let formatVersion: Int
        let exportedAt: Date
        let cards: [CardRecord]
    }

    public static func encode(cards: [CardRecord], exportedAt: Date = .now) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Document(
            formatVersion: formatVersion,
            exportedAt: exportedAt,
            cards: cards.sorted { $0.id.uuidString < $1.id.uuidString }
        ))
    }
}
