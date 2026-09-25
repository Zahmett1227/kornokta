import Foundation

/// One question's line in "Kitaba dönünce", free of SwiftData.
public struct ExamGap: Equatable, Sendable {
    public var status: ExamGapStatus
    public var openedAt: Date?
    public var closedAt: Date?
    /// The card that closed it — kept so a deleted card can reopen the gap.
    public var closedByCardId: UUID?

    public init(
        status: ExamGapStatus = .noGap,
        openedAt: Date? = nil,
        closedAt: Date? = nil,
        closedByCardId: UUID? = nil
    ) {
        self.status = status
        self.openedAt = openedAt
        self.closedAt = closedAt
        self.closedByCardId = closedByCardId
    }
}

/// A card as the "muhtemelen kapandı" check reads it.
public struct ExamGapCard: Equatable, Sendable {
    public let id: UUID
    public let subject: String?
    public let topic: String?
    public let createdAt: Date

    public init(id: UUID, subject: String?, topic: String?, createdAt: Date) {
        self.id = id
        self.subject = subject
        self.topic = topic
        self.createdAt = createdAt
    }
}

/// The rules of "Kitaba dönünce" (plan §7.6): a missed question the owner has
/// no card for, kept until a card for it exists.
///
/// Every transition is a pure function of the old gap, so the screen cannot
/// invent one: a gap opens only from the bridge's "Hiçbiri", closes only when
/// the owner names a card, and is never closed silently — a new card in the
/// same topic only *suggests* closing (`likelyClosers`).
public enum ExamGapLedger {
    /// "Hiçbiri — destemde yok". An already open gap keeps the day it opened;
    /// a dismissed one stays dismissed — the owner said not to ask again. A
    /// closed one opens again: the owner just missed the question with the
    /// closing card in the deck, which is new evidence.
    public static func opening(_ gap: ExamGap, at now: Date) -> ExamGap {
        switch gap.status {
        case .open, .dismissed:
            return gap
        case .noGap, .closed:
            return ExamGap(status: .open, openedAt: now)
        }
    }

    /// "Kart ekledim" or a confirmed suggestion. Only an open gap closes.
    public static func closing(_ gap: ExamGap, byCard cardId: UUID, at now: Date) -> ExamGap {
        guard gap.status == .open else { return gap }
        return ExamGap(status: .closed, openedAt: gap.openedAt, closedAt: now, closedByCardId: cardId)
    }

    /// "Yoksay" — never asked about again.
    public static func dismissing(_ gap: ExamGap) -> ExamGap {
        guard gap.status == .open else { return gap }
        var dismissed = gap
        dismissed.status = .dismissed
        return dismissed
    }

    /// A gap closed by a card that no longer exists is open again: the card
    /// that answered the question is gone, so the question is unanswered.
    public static func reconciled(_ gap: ExamGap, existingCardIds: Set<UUID>) -> ExamGap {
        guard gap.status == .closed, let closer = gap.closedByCardId, !existingCardIds.contains(closer) else {
            return gap
        }
        return ExamGap(status: .open, openedAt: gap.openedAt)
    }

    /// Cards added to the question's subject and topic after the gap opened —
    /// "muhtemelen kapandı", offered for a one-tap confirmation, newest first.
    /// A question without a topic matches on subject alone, which is broader
    /// but still only cards made *after* the miss.
    public static func likelyClosers(
        _ gap: ExamGap,
        subject: String?,
        topic: String?,
        cards: [ExamGapCard]
    ) -> [UUID] {
        guard gap.status == .open, let openedAt = gap.openedAt, let subject else { return [] }
        return cards
            .filter { card in
                card.createdAt > openedAt && card.subject == subject && (topic == nil || card.topic == topic)
            }
            .sorted { $0.createdAt > $1.createdAt }
            .map(\.id)
    }
}
