import Foundation

/// Real card generation via the backend's `POST /api/cards-vision` (Faz 6 —
/// docs/FAZ6-PLAN.md §5.1). `MockCardProvider` is Faz 1's offline stand-in;
/// this is what replaces it once a backend URL and device token are configured
/// — same seam `BackendClient` already uses for OCR, so Settings does not grow
/// a second on/off switch.
///
/// Faz 6 pivot (docs/ADR-005): the endpoint no longer takes a pre-reconciled
/// `cleanText`; it sends the marked full-page photo and the model reads the
/// highlighted/annotated content itself. The response is the simplified v2
/// contract — no `transcription`/`knowledgeUnits`/source-fidelity fields — and
/// cards go straight to the active deck (no approval step). The gate is now a
/// health check that only ever rejects a structurally broken or over-limit
/// card; it never asks for confirmation.
///
/// Decoded wire types are named `Remote*` for the same reason
/// `BackendClient.swift`'s are: several of the real names (`Card`) already
/// belong to this package's SwiftData models.
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
            // Faz 6: the marked full page IS the input. A request missing it is
            // a wiring bug, not something worth retrying.
            throw CardGenerationError.schemaInvalid("Görüntü olmadan gerçek kart üretimi çağrılamaz.")
        }

        var urlRequest = URLRequest(url: configuration.baseURL.appendingPathComponent("api/cards-vision"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = configuration.timeout
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload = RequestBody(
            jobId: request.jobId,
            mimeType: mimeType,
            imageBase64: imageData.base64EncodedString(),
            // Optional user steer (§5.1). Empty/whitespace is sent as absent.
            hint: request.hint?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
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
    /// gate. `runCardGate` on the server never mutates `output.cards` — a
    /// rejected card is still physically present in the array, and would reach
    /// the deck untouched if this did not filter it out (§0.5, §5.3).
    ///
    /// Faz 6: the v2 gate only ever returns `auto_accept` or `reject`, so a kept
    /// card is always active — there is no approval step any more
    /// (`requiresUserApproval` stays false).
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

        let survivingCards: [GeneratedCard] = decoded.output.cards.compactMap { card in
            // An unscored id defaults to kept: the v2 gate scores every card, so
            // this only happens on a malformed response, and Faz 6 has no
            // confirmation lane to route it into — an active card the user can
            // delete in Bilgilerim is the honest fallback.
            let decision = verdicts[card.id] ?? "auto_accept"
            guard decision != "reject" else { return nil }
            return GeneratedCard(
                type: card.type,
                front: card.front,
                back: card.back,
                explanation: card.explanation.isEmpty ? nil : card.explanation,
                // v2 has no per-card source quote (source-fidelity accounting
                // was removed in Faz 6). Left empty rather than faking one.
                sourceQuote: "",
                riskFlags: [],
                requiresUserApproval: false
            )
        }

        guard !survivingCards.isEmpty else {
            throw CardGenerationError.sourceInsufficient
        }

        // v2 has no `knowledgeUnits`: the whole marked page is one implicit
        // unit. Its claim is the model's read text (or the first card's front
        // when the model returned none), and its tags are the union of the
        // cards' own tags.
        let readText = decoded.output.readText.trimmingCharacters(in: .whitespacesAndNewlines)
        let canonicalClaim = readText.nonEmpty ?? decoded.output.cards.first?.front ?? "Kart destesi"

        var tags: [String] = []
        var seenTags = Set<String>()
        for card in decoded.output.cards {
            for tag in card.tags where !seenTags.contains(tag) {
                seenTags.insert(tag)
                tags.append(tag)
            }
        }

        // Only the gate's page-level warnings remain a "concern" worth
        // surfacing (e.g. cards dropped for the per-passage limit).
        let concern = decoded.gate.warnings.isEmpty ? nil : decoded.gate.warnings.joined(separator: " ")

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
            canonicalClaim: canonicalClaim,
            tags: tags,
            sourceConcern: concern,
            cards: survivingCards,
            modelRun: modelRun
        )
    }

    private struct RequestBody: Encodable {
        let jobId: String
        let mimeType: String
        let imageBase64: String
        let hint: String?
    }

    private struct FailureBody: Decodable {
        let error: String
        let retryable: Bool
    }
}

/// Field names match the server's JSON exactly (Faz 6 v2 contract — docs/FAZ6-PLAN.md §6).
struct RemoteCardsSuccess: Decodable {
    let output: RemoteCardsOutput
    let gate: RemoteCardGateReport
    let cardPromptVersion: String
}

struct RemoteCardsOutput: Decodable {
    let requestId: String
    /// The raw text the model read off the marked content — audit only (§6.3).
    let readText: String
    let cards: [RemoteCard]
    let usage: RemoteUsage
}

struct RemoteCard: Decodable {
    let id: String
    let type: CardType
    let front: String
    let back: String
    let explanation: String
    let difficulty: Int
    let tags: [String]
    /// The model's own "I am unsure" signal (§6). Recorded but does not gate.
    let lowConfidence: Bool
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
/// `?? "auto_accept"` default at the call site is what actually protects
/// against that case.
struct RemoteCardVerdict: Decodable {
    let cardId: String
    let decision: String
}

private extension String {
    /// `nil` when the string is empty, itself otherwise — so an absent hint or
    /// an empty read text collapses to `nil` at the point of use.
    var nonEmpty: String? { isEmpty ? nil : self }
}
