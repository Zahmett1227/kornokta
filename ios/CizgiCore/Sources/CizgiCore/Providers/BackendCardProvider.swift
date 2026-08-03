import Foundation

/// Real card generation via the backend's `POST /api/cards` (ANA-PLAN §7.2,
/// §14, §25 Faz 3). `MockCardProvider` is Faz 1's offline stand-in; this is
/// what replaces it once a backend URL and device token are configured —
/// same seam `BackendClient` already uses for OCR, so Settings does not grow
/// a second on/off switch.
///
/// Decoded wire types are named `Remote*` for the same reason
/// `BackendClient.swift`'s are: several of the real names (`Card`,
/// `KnowledgeUnit`) already belong to this package's SwiftData models.
public struct BackendCardProvider: CardGenerating {
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

    public func generate(_ request: CardGenerationRequest) async throws -> GeneratedKnowledge {
        guard let token = tokenProvider(), !token.isEmpty else {
            throw CardGenerationError.providerUnavailable("Cihaz anahtarı ayarlanmamış.")
        }
        guard let imageData = request.imageData, let mimeType = request.mimeType else {
            // Every real capture goes through `cloudReading` first (§17), which
            // is the only place that produces these — a request missing them
            // is a wiring bug, not something worth retrying.
            throw CardGenerationError.schemaInvalid("Görüntü olmadan gerçek kart üretimi çağrılamaz.")
        }

        var urlRequest = URLRequest(url: configuration.baseURL.appendingPathComponent("api/cards"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = configuration.timeout
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload = RequestBody(
            jobId: request.jobId,
            mimeType: mimeType,
            imageBase64: imageData.base64EncodedString(),
            cleanText: request.passage,
            selectedLineIds: request.selectedLineIds,
            isHandwritten: request.isHandwritten
        )
        urlRequest.httpBody = try JSONEncoder().encode(payload)

        let started = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            // No connection, DNS failure, timeout: worth another attempt (§17).
            throw CardGenerationError.providerUnavailable(error.localizedDescription)
        }
        let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)

        guard let http = response as? HTTPURLResponse else {
            throw CardGenerationError.providerUnavailable("Beklenmeyen yanıt türü.")
        }

        guard (200..<300).contains(http.statusCode) else {
            let failure = try? JSONDecoder().decode(FailureBody.self, from: data)
            let message = failure?.error ?? "Sunucu hatası (\(http.statusCode))."
            if http.statusCode == 402 {
                // §21.3: the server refused before spending because the
                // estimated cost would exceed the configured ceiling.
                throw CardGenerationError.budgetExceeded
            }
            let retryable = failure?.retryable ?? (http.statusCode >= 500)
            throw retryable
                ? CardGenerationError.providerUnavailable(message)
                : CardGenerationError.schemaInvalid(message)
        }

        let decoded: RemoteCardsSuccess
        do {
            decoded = try JSONDecoder().decode(RemoteCardsSuccess.self, from: data)
        } catch {
            // A reply we cannot parse will not parse on a second attempt
            // either — it is a contract problem, not a blip (§17).
            throw CardGenerationError.schemaInvalid("Sunucu yanıtı çözümlenemedi: \(error)")
        }

        return try Self.map(decoded, elapsedMs: elapsedMs)
    }

    /// Cross-references the model's cards against the server's deterministic
    /// §19 gate. `runCardGate` on the server never mutates `output.cards` — a
    /// rejected card is still physically present in the array, and would
    /// reach the deck untouched if this did not filter it out (§0.5, §19.3).
    ///
    /// Internal rather than private: this is the one piece of `generate()`
    /// worth testing directly (no HTTP mocking in this package, same as
    /// `BackendClient` — see `BackendCardProviderTests.swift`).
    static func map(_ decoded: RemoteCardsSuccess, elapsedMs: Int) throws -> GeneratedKnowledge {
        // Built with `reduce`, not `Dictionary(uniqueKeysWithValues:)`: card
        // ids come from a model response, and a duplicate must not crash the
        // app — it is untrusted input, not a contract this package controls.
        let verdicts = decoded.gate.verdicts.reduce(into: [String: String]()) { acc, verdict in
            acc[verdict.cardId] = verdict.decision
        }

        // §11.3/config.ts: one request's knowledge units and cards are
        // treated as belonging to one call. Cards are kept or dropped purely
        // by the gate's verdict, not filtered by `knowledgeUnitId`, so a rare
        // second knowledge unit's cards are still kept rather than silently
        // dropped — only their own claim/tags are not separately represented.
        guard let firstUnit = decoded.output.knowledgeUnits.first else {
            throw CardGenerationError.sourceInsufficient
        }

        let survivingCards: [GeneratedCard] = decoded.output.cards.compactMap { card in
            // An id the gate never scored is never trusted silently.
            let decision = verdicts[card.id] ?? "quick_confirm"
            guard decision != "reject" else { return nil }
            return GeneratedCard(
                type: card.type,
                front: card.front,
                back: card.back,
                explanation: card.explanation.isEmpty ? nil : card.explanation,
                sourceQuote: card.sourceQuote,
                riskFlags: card.riskFlags,
                // ADR-001's floor-not-ceiling rule, same as the server side:
                // the gate can only escalate to needing confirmation, never
                // relax the model's own `requiresUserApproval`.
                requiresUserApproval: card.requiresUserApproval || decision == "quick_confirm"
            )
        }

        guard !survivingCards.isEmpty else {
            throw CardGenerationError.sourceInsufficient
        }

        // Merged into one field because `GeneratedKnowledge` has a single
        // `sourceConcern` slot — every reason the model or the gate had for
        // wanting a second look surfaces here rather than only the first one.
        var concernParts = [String]()
        if let sourceConcern = firstUnit.sourceConcern { concernParts.append(sourceConcern) }
        if firstUnit.requiresUserApproval { concernParts.append("Bilgi birimi onay istiyor.") }
        concernParts.append(contentsOf: decoded.gate.warnings)
        let concern = concernParts.isEmpty ? nil : concernParts.joined(separator: " ")

        let modelRun = ModelRunMetadata(
            requestId: decoded.output.requestId,
            provider: decoded.output.usage.provider,
            model: decoded.output.usage.model,
            purpose: "card_generation",
            promptVersion: decoded.cardPromptVersion,
            latencyMs: elapsedMs,
            inputTokens: decoded.output.usage.inputTokens,
            outputTokens: decoded.output.usage.outputTokens,
            estimatedCostUSD: decoded.output.usage.estimatedCostUSD
        )

        return GeneratedKnowledge(
            canonicalClaim: firstUnit.canonicalClaim,
            tags: firstUnit.tags,
            sourceConcern: concern,
            cards: survivingCards,
            modelRun: modelRun
        )
    }

    private struct RequestBody: Encodable {
        let jobId: String
        let mimeType: String
        let imageBase64: String
        let cleanText: String
        let selectedLineIds: [String]
        let isHandwritten: Bool
    }

    private struct FailureBody: Decodable {
        let error: String
        let retryable: Bool
    }
}

/// Field names match the server's JSON exactly (ANA-PLAN §14).
struct RemoteCardsSuccess: Decodable {
    let output: RemoteCardsOutput
    let gate: RemoteCardGateReport
    let cardPromptVersion: String
}

struct RemoteCardsOutput: Decodable {
    let requestId: String
    let knowledgeUnits: [RemoteKnowledgeUnit]
    let cards: [RemoteCard]
    let usage: RemoteUsage
}

struct RemoteKnowledgeUnit: Decodable {
    let canonicalClaim: String
    let tags: [String]
    let sourceConcern: String?
    let requiresUserApproval: Bool
}

struct RemoteCard: Decodable {
    let id: String
    let type: CardType
    let front: String
    let back: String
    let explanation: String
    let sourceQuote: String
    let riskFlags: [RiskFlag]
    let requiresUserApproval: Bool
}

struct RemoteUsage: Decodable {
    let provider: String
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let estimatedCostUSD: Double
}

struct RemoteCardGateReport: Decodable {
    let verdicts: [RemoteCardVerdict]
    let warnings: [String]
}

/// `decision` is decoded as a plain string, not a Swift enum: it comes from
/// the server's own deterministic gate rather than the model, but treating
/// an unrecognized value as a hard decode failure would fail the whole
/// response over one new decision the client does not know about yet. The
/// `?? "quick_confirm"` default at the call site is what actually protects
/// against that case.
struct RemoteCardVerdict: Decodable {
    let cardId: String
    let decision: String
}
