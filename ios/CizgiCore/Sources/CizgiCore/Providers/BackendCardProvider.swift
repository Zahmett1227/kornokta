import Foundation

/// Real card generation via the backend's asynchronous job queue
/// (docs/ADR-006). `MockCardProvider` is Faz 1's offline stand-in; this is what
/// replaces it once a backend URL and device token are configured — same seam
/// `BackendClient` already uses for OCR, so Settings does not grow a second
/// on/off switch.
///
/// Faz 6 pivot (docs/ADR-005): the marked full-page photo is the input and the
/// model reads the highlighted/annotated content itself. The response is the
/// simplified v2 contract — no `transcription`/`knowledgeUnits`/source-fidelity
/// fields — and cards go straight to the active deck (no approval step).
///
/// ADR-006 changed *how* that call is made, not what it returns. The old
/// `POST /api/cards-vision` asked this phone to hold one connection open for the
/// one to five minutes the model takes, which no phone can be relied on to do:
/// the screen auto-locks after 30 s, iOS suspends the app, and the upload dies
/// as a timeout. Now the page is submitted, the backend generates in its own
/// time, and this collects the answer. Every HTTP call here is seconds long, so
/// an interruption costs one poll rather than the whole page.
///
/// `generate()` still returns only when the cards exist, because that is the
/// contract `CapturePipeline` is built on. What changed is that being
/// interrupted no longer destroys the work: the job id **is** the page id, so a
/// later attempt — even after the app was killed and relaunched — finds the
/// finished job and collects it instead of paying for a second generation.
///
/// Decoded wire types are named `Remote*` for the same reason
/// `BackendClient.swift`'s are: several of the real names (`Card`) already
/// belong to this package's SwiftData models.
public struct BackendCardProvider: CardGenerating {
    private let configuration: BackendConfiguration
    private let tokenProvider: @Sendable () -> String?
    private let session: URLSession
    /// Injected so tests can drive the wait without really sleeping.
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    public init(
        configuration: BackendConfiguration,
        tokenProvider: @escaping @Sendable () -> String?,
        session: URLSession = .shared,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        self.configuration = configuration
        self.tokenProvider = tokenProvider
        self.session = session
        self.sleep = sleep
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

        let started = Date()
        let hint = request.hint?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty

        // Asked about before being sent. A page interrupted mid-wait — app
        // backgrounded past its assertion, killed, or simply retried by the
        // queue — is almost always already finished on the server by the time
        // anything asks again, and this collects it without re-uploading three
        // megabytes or paying for a second generation.
        var view = try await poll(jobId: request.jobId, token: token)

        switch Self.action(for: view) {
        case .submit, .failTransiently:
            // Two states mean "send the page": the server has never heard of it,
            // and it holds only a failure worth retrying. The second one is not
            // an answer to report — reporting it here would deadlock the page,
            // because every later attempt would poll, find the same old failure
            // and fail again without ever re-uploading. `POST` re-arms the
            // existing row rather than opening a second job, so this stays one
            // job per page.
            view = try await submit(
                jobId: request.jobId,
                imageData: imageData,
                mimeType: mimeType,
                hint: hint,
                maxCards: request.maxCards,
                token: token
            )
        case .useResult, .wait, .failPermanently:
            break
        }

        var waited: TimeInterval = 0
        while true {
            switch Self.action(for: view) {
            case .useResult:
                guard let result = view?.result else {
                    // `useResult` is only ever returned for a view that has one;
                    // this is unreachable and would be a bug in `action(for:)`.
                    throw CardGenerationError.schemaInvalid("Biten işte sonuç yok.")
                }
                return try Self.map(result, elapsedMs: Int(Date().timeIntervalSince(started) * 1000))

            case .failPermanently(let message):
                throw CardGenerationError.schemaInvalid(message)

            case .failTransiently(let message):
                throw CardGenerationError.providerUnavailable(message)

            case .submit:
                // The job vanished between the submit and this poll — nothing
                // sensible left to wait for, and re-uploading from inside the
                // wait loop would risk looping forever. The queue's own retry
                // starts cleanly from the top.
                throw CardGenerationError.providerUnavailable("İş kaydı bulunamadı; tekrar denenecek.")

            case .wait:
                let interval = Self.pollInterval(afterWaiting: waited)
                guard waited + interval <= configuration.jobDeadline else {
                    // Not a lost page: the job is still running on the server and
                    // its answer will be waiting for whoever asks next. Reported
                    // as transient so the queue retries rather than gives up.
                    throw CardGenerationError.providerUnavailable(
                        "Kart üretimi sürüyor; sonuç bir sonraki denemede alınacak."
                    )
                }
                try await sleepOrFail(interval)
                waited += interval
                view = try await poll(jobId: request.jobId, token: token)
            }
        }
    }

    /// `Task.sleep` throws on cancellation; that is a cancelled pipeline run,
    /// not a provider failure, and must not be reported as one.
    private func sleepOrFail(_ interval: TimeInterval) async throws {
        do {
            // Qualified: unqualified `sleep` would also match the C library's
            // global of that name.
            try await self.sleep(interval)
        } catch {
            throw CancellationError()
        }
    }

    /// What the job state the server just reported *means*.
    ///
    /// Deliberately a description, not a plan: whether a transient failure is
    /// worth another upload depends on where in the flow it was seen (before the
    /// submit it is a reason to send the page; during the wait it is a reason to
    /// hand back to the queue), and that policy lives at those two call sites
    /// rather than being baked in here.
    ///
    /// Split out from `generate()` because it is the whole decision the async
    /// flow rests on, and because it is the one piece of it that can be tested
    /// without an HTTP stub (this package has none — same constraint that keeps
    /// `map` internal rather than private).
    enum JobAction: Equatable {
        /// Finished; the cards are on the view.
        case useResult
        /// Nothing on the server knows about this page yet.
        case submit
        /// Queued or running — ask again shortly.
        case wait
        /// Trying again would reproduce it (§17).
        case failPermanently(String)
        /// Worth another attempt later (§17).
        case failTransiently(String)
    }

    static func action(for view: RemoteJobView?) -> JobAction {
        guard let view else { return .submit }
        switch view.status {
        case "ready":
            // A "ready" job with no result is a broken row rather than a
            // finished one; waiting for it forever would be worse than saying so.
            return view.result == nil
                ? .failPermanently("Biten işte sonuç yok.")
                : .useResult
        case "queued", "processing":
            return .wait
        case "failed":
            let message = view.error ?? "Kart üretimi başarısız."
            // The server decides what is worth retrying, so the rule lives in
            // one place rather than being re-derived here (§17).
            return (view.retryable ?? false) ? .failTransiently(message) : .failPermanently(message)
        default:
            // A status this build does not know about. Treated as transient:
            // an older client must not turn a server-side addition into a
            // permanently failed page.
            return .failTransiently("Bilinmeyen iş durumu: \(view.status)")
        }
    }

    /// Short at first because most pages finish in about a minute, then longer
    /// so a slow one does not cost dozens of pointless round trips.
    static func pollInterval(afterWaiting waited: TimeInterval) -> TimeInterval {
        switch waited {
        case ..<30: return 3
        case ..<120: return 5
        default: return 10
        }
    }

    private func submit(
        jobId: String,
        imageData: Data,
        mimeType: String,
        hint: String?,
        maxCards: Int,
        token: String
    ) async throws -> RemoteJobView? {
        var urlRequest = URLRequest(url: configuration.baseURL.appendingPathComponent("api/jobs"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = configuration.timeout
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(
            RequestBody(
                jobId: jobId,
                mimeType: mimeType,
                imageBase64: imageData.base64EncodedString(),
                hint: hint,
                // Sent at last. `CapturePipeline` has been putting the user's
                // setting on the request since Faz 3 and this method never wrote
                // it to the wire, so the server always used its own ceiling and
                // the Ayarlar control did nothing.
                maxCards: maxCards
            )
        )

        let data = try await send(urlRequest)
        do {
            return try JSONDecoder().decode(RemoteJobView.self, from: data)
        } catch {
            throw CardGenerationError.schemaInvalid("Sunucu yanıtı çözümlenemedi: \(error)")
        }
    }

    /// `nil` when the server has no such job — an unknown id is simply absent
    /// from the array, which is what tells `action(for:)` to submit.
    private func poll(jobId: String, token: String) async throws -> RemoteJobView? {
        var components = URLComponents(
            url: configuration.baseURL.appendingPathComponent("api/jobs"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "ids", value: jobId)]
        guard let url = components?.url else {
            throw CardGenerationError.schemaInvalid("Geçersiz backend adresi.")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "GET"
        urlRequest.timeoutInterval = configuration.timeout
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let data = try await send(urlRequest)
        do {
            return try JSONDecoder().decode(RemoteJobsResponse.self, from: data).jobs.first
        } catch {
            throw CardGenerationError.schemaInvalid("Sunucu yanıtı çözümlenemedi: \(error)")
        }
    }

    /// The transport half both calls share: HTTP status handling only, no
    /// decoding, so the two of them cannot drift on what a 402 or a 503 means.
    private func send(_ urlRequest: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            // No connection, DNS failure, timeout: worth another attempt (§17).
            throw CardGenerationError.providerUnavailable(error.localizedDescription)
        }

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
        return data
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
        /// The server clamps this to its own ceiling, so it can only ask for
        /// fewer cards than the deployment allows.
        let maxCards: Int
    }

    private struct FailureBody: Decodable {
        let error: String
        let retryable: Bool
    }
}

/// One job as `/api/jobs` reports it (docs/ADR-006).
///
/// `status` is decoded as a plain string rather than an enum for the same
/// reason `RemoteCardVerdict.decision` is: a value this build has not heard of
/// must not fail the whole response. `action(for:)` is where an unknown one is
/// given a safe meaning.
struct RemoteJobView: Decodable {
    let jobId: String
    let status: String
    /// Present only once `status` is `ready`. Exactly the body the synchronous
    /// `/api/cards-vision` returns, so this decoder is the same one.
    let result: RemoteCardsSuccess?
    let error: String?
    let retryable: Bool?
}

struct RemoteJobsResponse: Decodable {
    let jobs: [RemoteJobView]
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
