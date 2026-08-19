import Foundation

/// One canonical topic the raters called dark, with what they said about it.
public struct DarkZone: Identifiable, Equatable, Sendable {
    /// How many model families flagged this topic.
    ///
    /// A string on the wire and an enum here, the same arrangement
    /// `SecondOpinion.Verdict` uses: an unknown value from a newer server must
    /// degrade to "shown without a badge", never to a decoding failure that
    /// loses the whole map.
    public enum Consensus: String, Sendable {
        /// Both families flagged it independently.
        case confirmed
        /// Exactly one did — or only one family answered at all.
        case disputed
    }

    public enum Yield: String, Sendable {
        case high, medium, low
    }

    public struct Reason: Equatable, Sendable {
        public let family: String
        public let reason: String
    }

    public var id: String { "\(subject)\u{1F}\(topic)" }
    public let subject: String
    public let topic: String
    /// From the deck, never from the model — the one number here that is known.
    ///
    /// `var`, not `let`, precisely *because* it belongs to the deck: the deck
    /// keeps moving after the ranking is paid for. A zone is a model judgement
    /// about a topic, and that judgement stays valid when a card is suspended —
    /// but the count beside it does not. `DarkMapCoverage.reconcile` refreshes
    /// these two and nothing else (Codex, PR #49).
    public var cardCount: Int
    public var weakCardCount: Int
    public let consensus: Consensus?
    public let consensusRaw: String
    /// Which families flagged it, so the screen can name them.
    public let raters: [String]
    /// Mean across the families that flagged it, 1–5.
    public let darkness: Double
    public let tusYield: Yield?
    /// Concrete headings the raters say are missing.
    public let missingConcepts: [String]
    /// One reason per family, kept apart rather than averaged: when two raters
    /// disagree about *why*, that is worth reading.
    public let reasons: [Reason]

    public init(
        subject: String,
        topic: String,
        cardCount: Int,
        weakCardCount: Int,
        consensusRaw: String,
        raters: [String],
        darkness: Double,
        tusYieldRaw: String,
        missingConcepts: [String],
        reasons: [Reason]
    ) {
        self.subject = subject
        self.topic = topic
        self.cardCount = cardCount
        self.weakCardCount = weakCardCount
        self.consensusRaw = consensusRaw
        self.consensus = Consensus(rawValue: consensusRaw)
        self.raters = raters
        self.darkness = darkness
        self.tusYield = Yield(rawValue: tusYieldRaw)
        self.missingConcepts = missingConcepts
        self.reasons = reasons
    }
}

/// A canonical topic with no card at all. Arithmetic, not a model's opinion.
public struct UntouchedTopic: Identifiable, Equatable, Sendable, Hashable {
    public var id: String { "\(subject)\u{1F}\(topic)" }
    public let subject: String
    public let topic: String

    public init(subject: String, topic: String) {
        self.subject = subject
        self.topic = topic
    }
}

public struct DarkMapResult: Equatable, Sendable {
    public struct Totals: Equatable, Sendable {
        public let canonicalTopics: Int
        public let coveredTopics: Int
        public let untouchedTopics: Int
        public let totalCards: Int
    }

    public struct Rater: Equatable, Sendable, Identifiable {
        public var id: String { family }
        public let family: String
        public let model: String
        public let ok: Bool
        public let error: String?
        public let zoneCount: Int
        /// Ratings this family produced for a topic outside the schema. Should
        /// be 0 — the response schema constrains the choice — so a non-zero
        /// value means constrained decoding is not doing what we think.
        public let droppedUnknown: Int
    }

    public let zones: [DarkZone]
    public let untouched: [UntouchedTopic]
    public let totals: Totals
    public let raters: [Rater]
    /// Fewer than two families answered, so nothing could be confirmed.
    ///
    /// The screen must say this out loud. Every zone is then `disputed` for a
    /// reason that has nothing to do with the topics themselves, and a display
    /// that looked like a two-family run would present one model's opinion as
    /// agreement — precisely what the consensus gate exists to prevent.
    public let singleRater: Bool
    public let promptVersion: String?
    public let usage: [ModelRunMetadata]

    public var confirmedZones: [DarkZone] { zones.filter { $0.consensus == .confirmed } }
}

public enum DarkMapError: Error, LocalizedError, Equatable {
    case notConfigured
    case schemaUnavailable
    case transport(String)
    /// The server's message travels verbatim — it already names the real
    /// suspect (an exhausted quota, a rejected key) and rewording it here would
    /// undo exactly that.
    ///
    /// `usage` carries what the failed calls cost. Empty for the guard failures
    /// that never reach a model, non-empty when both rankers ran and failed —
    /// and that case is why the associated value exists at all: two rankers can
    /// burn their whole output budget and then truncate, which is billed in
    /// full. An error that dropped the ledger would leave that spend invisible
    /// on Ayarlar → Kullanım, the exact under-reporting `tokenUsage.ts` was
    /// written to end.
    case server(String, retryable: Bool, usage: [ModelRunMetadata])
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Backend ayarlı değil (Ayarlar → Backend)."
        case .schemaUnavailable:
            return "Ders/konu şablonu okunamadı; karanlık harita çıkarılamaz."
        case .transport(let message):
            return "Bağlantı kurulamadı: \(message)"
        case .server(let message, _, _):
            return message
        case .invalidResponse(let message):
            return "Sunucu yanıtı çözümlenemedi: \(message)"
        }
    }

    public var retryable: Bool {
        switch self {
        case .notConfigured, .schemaUnavailable, .invalidResponse: return false
        case .transport: return true
        case .server(_, let retryable, _): return retryable
        }
    }

    /// The ledger a failed request still owes Ayarlar → Kullanım.
    public var usage: [ModelRunMetadata] {
        guard case .server(_, _, let usage) = self else { return [] }
        return usage
    }
}

/// `POST /api/dark-map` — the Karanlık Harita (backend `_darkMap.ts`, ADR-009).
///
/// Sends how many active cards the deck holds under each canonical (ders, konu)
/// pair and gets back two different kinds of answer: the topics with no card at
/// all, which is arithmetic the server does before calling anything, and a
/// ranking among the thin ones, which two model families produce independently.
///
/// Like `SecondOpinionProvider` and unlike `BackendCardProvider`, this is one
/// short synchronous call behind a button — no job row, no queue, no retry
/// machinery. Nothing is spent unless the owner pressed something.
///
/// It sends no image and stores nothing. The only card content that leaves the
/// phone is a handful of question texts per topic, which the server forwards to
/// the model and never logs.
public struct DarkMapProvider: Sendable {
    private let configuration: BackendConfiguration
    private let tokenProvider: @Sendable () -> String?
    private let session: URLSession

    public init(
        configuration: BackendConfiguration,
        tokenProvider: @escaping @Sendable () -> String?,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.tokenProvider = tokenProvider
        self.session = session
    }

    public func request(
        requestId: String,
        coverage: [DarkMapCoverage.Row],
        subjects: [String] = [],
        maxZones: Int? = nil
    ) async throws -> DarkMapResult {
        guard let token = tokenProvider(), !token.isEmpty else {
            throw DarkMapError.notConfigured
        }

        var urlRequest = URLRequest(url: configuration.baseURL.appendingPathComponent("api/dark-map"))
        urlRequest.httpMethod = "POST"
        // The server aborts both provider calls at DARK_MAP_TIMEOUT_MS (120 s)
        // and runs them concurrently, so this only needs to outlive one of them.
        urlRequest.timeoutInterval = configuration.timeout
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(
            RequestBody(
                requestId: requestId,
                coverage: coverage,
                // Omitted rather than sent empty: an empty array and an absent
                // key mean the same thing to the server ("all subjects"), and
                // sending the empty one invites a future reader to think it
                // means "no subjects".
                subjects: subjects.isEmpty ? nil : subjects,
                maxZones: maxZones
            )
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw DarkMapError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw DarkMapError.transport("Beklenmeyen yanıt türü.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let failure = try? JSONDecoder().decode(FailureBody.self, from: data)
            throw DarkMapError.server(
                failure?.error ?? "Sunucu hatası (\(http.statusCode)).",
                retryable: failure?.retryable ?? (http.statusCode >= 500),
                usage: Self.ledger(requestId: requestId, entries: failure?.usage ?? [])
            )
        }
        return try Self.parse(data)
    }

    /// Split out of `request` because it is the one decision worth testing and
    /// this package has no HTTP stub — same constraint that keeps
    /// `SecondOpinionProvider.parse` internal rather than private.
    static func parse(_ data: Data) throws -> DarkMapResult {
        let decoded: RemoteDarkMap
        do {
            decoded = try JSONDecoder().decode(RemoteDarkMap.self, from: data)
        } catch {
            throw DarkMapError.invalidResponse("\(error)")
        }

        return DarkMapResult(
            zones: decoded.zones.map { zone in
                DarkZone(
                    subject: zone.subject,
                    topic: zone.topic,
                    cardCount: zone.cardCount,
                    weakCardCount: zone.weakCardCount ?? 0,
                    consensusRaw: zone.consensus,
                    raters: zone.raters ?? [],
                    darkness: zone.darkness,
                    tusYieldRaw: zone.tusYield,
                    missingConcepts: zone.missingConcepts ?? [],
                    reasons: (zone.reasons ?? []).map {
                        DarkZone.Reason(family: $0.family, reason: $0.reason)
                    }
                )
            },
            untouched: decoded.untouched.map {
                UntouchedTopic(subject: $0.subject, topic: $0.topic)
            },
            totals: DarkMapResult.Totals(
                canonicalTopics: decoded.totals.canonicalTopics,
                coveredTopics: decoded.totals.coveredTopics,
                untouchedTopics: decoded.totals.untouchedTopics,
                totalCards: decoded.totals.totalCards
            ),
            raters: (decoded.raters ?? []).map {
                DarkMapResult.Rater(
                    family: $0.family,
                    model: $0.model,
                    ok: $0.ok,
                    error: $0.error,
                    zoneCount: $0.zoneCount ?? 0,
                    droppedUnknown: $0.droppedUnknown ?? 0
                )
            },
            // Defaults to `true` when the server did not say, which is the
            // cautious direction: an unlabelled map is treated as unconfirmed
            // rather than silently presented as agreement.
            singleRater: decoded.singleRater ?? true,
            promptVersion: decoded.promptVersion,
            // Both calls are billed whatever the verdict, so both have to reach
            // Ayarlar → Kullanım. A paid call that never lands there
            // permanently under-reports cost (Codex, PR #39).
            usage: ledger(requestId: decoded.requestId, entries: decoded.usage ?? [])
        )
    }

    /// Shared by the success and failure paths, because the ledger is owed on
    /// both. Kept as one function so a future field cannot be mapped on one path
    /// and forgotten on the other — which is how the accounting holes this
    /// project already closed came about.
    static func ledger(requestId: String, entries: [RemoteCallAccounting]) -> [ModelRunMetadata] {
        entries.map { entry in
            ModelRunMetadata(
                requestId: requestId,
                attempt: entry.attempt,
                provider: entry.provider,
                model: entry.model,
                purpose: entry.purpose,
                promptVersion: entry.promptVersion,
                latencyMs: entry.latencyMs,
                inputTokens: entry.usage.inputTokens,
                cachedInputTokens: entry.usage.cachedInputTokens,
                outputTokens: entry.usage.outputTokens,
                reasoningTokens: entry.usage.reasoningTokens,
                estimatedCostUSD: entry.estimatedCostUSD,
                success: entry.outcome == "success",
                billing: entry.billing,
                failureReason: entry.failureReason
            )
        }
    }

    private struct RequestBody: Encodable {
        let requestId: String
        let coverage: [DarkMapCoverage.Row]
        let subjects: [String]?
        let maxZones: Int?
    }

    private struct FailureBody: Decodable {
        let error: String
        let retryable: Bool
        /// Absent on the guard failures that reach no model; present when both
        /// rankers ran and failed. See `DarkMapError.server`.
        let usage: [RemoteCallAccounting]?
    }
}

/// Field names match the server's JSON exactly (`_darkMap.ts`).
///
/// Everything the screen can live without is optional, so a server that grows a
/// field or drops one it no longer needs cannot take the whole map down with a
/// decoding error. The four that are required — zones, untouched, totals and
/// each zone's identity — are the ones with no sensible default: a map missing
/// those is not a degraded map, it is a wrong one.
struct RemoteDarkMap: Decodable {
    struct Zone: Decodable {
        let subject: String
        let topic: String
        let cardCount: Int
        let weakCardCount: Int?
        let consensus: String
        let raters: [String]?
        let darkness: Double
        let tusYield: String
        let missingConcepts: [String]?
        let reasons: [Reason]?

        struct Reason: Decodable {
            let family: String
            let reason: String
        }
    }

    struct Untouched: Decodable {
        let subject: String
        let topic: String
    }

    struct Totals: Decodable {
        let canonicalTopics: Int
        let coveredTopics: Int
        let untouchedTopics: Int
        let totalCards: Int
    }

    struct Rater: Decodable {
        let family: String
        let model: String
        let ok: Bool
        let error: String?
        let zoneCount: Int?
        let droppedUnknown: Int?
    }

    let requestId: String
    let promptVersion: String?
    let zones: [Zone]
    let untouched: [Untouched]
    let totals: Totals
    let raters: [Rater]?
    let singleRater: Bool?
    /// Reuses card generation's own wire type rather than declaring a near-copy:
    /// the server sends the identical `CallAccounting` shape on both endpoints,
    /// and a second decoder for it would be one more pair to hand-sync.
    let usage: [RemoteCallAccounting]?
}
