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
                multipleChoiceMode: request.multipleChoiceMode,
                subject: request.subject,
                force: request.forceResubmit,
                token: token
            )
        case .failPermanently where request.forceResubmit:
            // The user asked again for a page the server had given up on. The
            // row only moves if `force` travels with the upload — `/api/jobs`
            // will not re-arm a non-retryable failure on its own.
            view = try await submit(
                jobId: request.jobId,
                imageData: imageData,
                mimeType: mimeType,
                hint: hint,
                maxCards: request.maxCards,
                multipleChoiceMode: request.multipleChoiceMode,
                subject: request.subject,
                force: true,
                token: token
            )
        case .useResult, .wait, .failPermanently:
            break
        }

        var waited: TimeInterval = 0
        while true {
            // Re-read on every turn of the loop: the ledger grows as the server
            // works, and every exit below owes the queue whatever has been
            // spent so far — a page that fails after two paid attempts must not
            // take that record down with it.
            let spent = Self.accounting(of: view)

            switch Self.action(for: view) {
            case .useResult:
                guard let result = view?.result else {
                    // `useResult` is only ever returned for a view that has one;
                    // this is unreachable and would be a bug in `action(for:)`.
                    throw CardGenerationFailure(
                        error: .schemaInvalid("Biten işte sonuç yok."),
                        accounting: spent
                    )
                }
                return try Self.map(
                    result,
                    elapsedMs: Int(Date().timeIntervalSince(started) * 1000),
                    accounting: spent
                )

            case .failPermanently(let message):
                throw CardGenerationFailure(error: .schemaInvalid(message), accounting: spent)

            case .failTransiently(let message):
                throw CardGenerationFailure(error: .providerUnavailable(message), accounting: spent)

            case .submit:
                // The job vanished between the submit and this poll — nothing
                // sensible left to wait for, and re-uploading from inside the
                // wait loop would risk looping forever. The queue's own retry
                // starts cleanly from the top.
                throw CardGenerationFailure(
                    error: .providerUnavailable("İş kaydı bulunamadı; tekrar denenecek."),
                    accounting: spent
                )

            case .wait:
                let interval = Self.pollInterval(afterWaiting: waited)
                guard waited + interval <= configuration.jobDeadline else {
                    // Not a lost page and, crucially, not a second charge: the
                    // job is still running on the server and its answer will be
                    // waiting for whoever asks next. Reported as transient so
                    // the queue retries rather than gives up — the retry
                    // collects, it does not regenerate.
                    throw CardGenerationFailure(
                        error: .providerUnavailable(
                            "Kart üretimi sunucuda sürüyor; sonuç bir sonraki denemede alınacak "
                                + "(yeniden ücretlendirilmez)."
                        ),
                        accounting: spent
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
        multipleChoiceMode: MultipleChoiceMode?,
        subject: String?,
        force: Bool,
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
                maxCards: maxCards,
                multipleChoiceMode: multipleChoiceMode?.rawValue,
                subject: subject,
                // Omitted rather than sent as `false`: an ordinary submission
                // should look exactly as it always did on the wire.
                force: force ? true : nil
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
    /// Turns a wire card's options into the model's own type, or `nil`.
    ///
    /// Re-validated on arrival even though the server's gate already checked
    /// them (§13.3 rule 4): the phone is not entitled to assume a well-formed
    /// response, and a card whose options do not hold up simply shows as a
    /// plain card rather than as a question that cannot be answered.
    static func options(of card: RemoteCard) -> [CardOption]? {
        guard card.type == .multipleChoice, let remote = card.options else { return nil }
        let options = remote.map {
            CardOption(text: $0.text, isCorrect: $0.correct, why: $0.why.isEmpty ? nil : $0.why)
        }
        guard case .valid = MultipleChoice.validate(options) else { return nil }
        // The server states the answer twice on purpose; if the two disagree,
        // neither can be trusted (backend `multipleChoice.ts`).
        guard let correctOption = card.correctOption,
              MultipleChoice.correctIndex(options) == correctOption
        else { return nil }
        return options
    }

    /// Turns the server's ledger into the phone's, verbatim.
    ///
    /// Nothing is recomputed here on purpose. The server knows the prices, saw
    /// the provider's own `usage` block and is the only party that observes
    /// every attempt; a phone that re-derived any of it would be inventing a
    /// second answer to a question that already has one.
    static func accounting(of view: RemoteJobView?) -> [ModelRunMetadata] {
        (view?.usage ?? []).map { entry in
            ModelRunMetadata(
                requestId: view?.jobId ?? "",
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

    static func map(
        _ decoded: RemoteCardsSuccess,
        elapsedMs: Int,
        accounting: [ModelRunMetadata]
    ) throws -> GeneratedKnowledge {
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
            // A type this build does not know about. Dropping the one card
            // keeps the rest of the page rather than failing all of it.
            guard let type = card.type else { return nil }
            return GeneratedCard(
                type: type,
                front: card.front,
                back: card.back,
                explanation: card.explanation.isEmpty ? nil : card.explanation,
                // v2 has no per-card source quote (source-fidelity accounting
                // was removed in Faz 6). Left empty rather than faking one.
                sourceQuote: "",
                riskFlags: [],
                requiresUserApproval: false,
                options: Self.options(of: card),
                lowConfidence: card.lowConfidence,
                topic: card.topic
            )
        }

        guard !survivingCards.isEmpty else {
            // A page that produced no card is the page whose coverage matters
            // most: every mark on it is uncovered by definition. Thrown as a
            // `CardGenerationFailure` rather than a bare error so the register
            // — and the ledger of what this attempt cost — survive the failure
            // instead of being dropped with it.
            throw CardGenerationFailure(
                error: .sourceInsufficient,
                accounting: accounting,
                coverage: Self.coverage(of: decoded.coverage)
            )
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

        // The server's ledger is authoritative when it sent one. The fallback
        // reconstructs a single line from the card payload's own `usage` block,
        // which is what a deployment predating the ledger still returns — one
        // call recorded is better than none, and it keeps this decoder working
        // against both.
        let runs = accounting.isEmpty
            ? [
                ModelRunMetadata(
                    requestId: decoded.output.requestId,
                    attempt: 1,
                    provider: decoded.output.usage.provider,
                    model: decoded.output.usage.model,
                    purpose: "card_generation",
                    promptVersion: decoded.cardPromptVersion,
                    latencyMs: elapsedMs,
                    inputTokens: decoded.output.usage.inputTokens,
                    outputTokens: decoded.output.usage.outputTokens,
                    estimatedCostUSD: decoded.output.usage.estimatedCostUSD,
                    success: true
                )
            ]
            : accounting

        return GeneratedKnowledge(
            canonicalClaim: canonicalClaim,
            tags: tags,
            sourceConcern: concern,
            cards: survivingCards,
            modelRuns: runs,
            coverage: Self.coverage(of: decoded.coverage)
        )
    }

    /// The server's coverage accounting, in the phone's own shape.
    ///
    /// Nothing is recomputed here, for the reason `accounting(of:)` gives: the
    /// server is the only party that sees the model's register and the gate's
    /// rejections together, and a second derivation would be a second answer to
    /// a settled question.
    ///
    /// `nil` for a backend that sends no block at all — which is a different
    /// state from a block saying `reported: false`, though both mean "no
    /// findings": one is an old server, the other a model that skipped the
    /// register. Only the second is worth re-auditing, and the audit button is
    /// offered either way.
    static func coverage(of remote: RemoteCoverage?) -> PageCoverage? {
        guard let remote else { return nil }
        return PageCoverage(
            reported: remote.reported,
            uncovered: remote.uncovered.compactMap { mark in
                // A tier this build has not heard of drops that one mark and
                // keeps the rest, exactly like an unknown card type does. The
                // alternative — failing the decode — would cost the page all
                // its cards over an audit extra.
                guard let kind = MarkKind(rawValue: mark.kind) else { return nil }
                return PageMark(kind: kind, quote: mark.quote, source: .generator)
            },
            unmarkedCardIds: remote.unmarkedCardIds
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
        /// Same rule as `maxCards`: the deployment's own mode is the ceiling
        /// (§21.3, §13.3). Omitted when the user has not chosen one.
        let multipleChoiceMode: String?
        /// Canonical subject name (schema v2.2) for per-card topics. Omitted
        /// when no subject is selected; the server stores unknown names as
        /// null rather than failing the capture.
        let subject: String?
        /// Present only on a user-initiated retry (§17): asks the server to
        /// re-arm even a failure it had marked permanent.
        let force: Bool?
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
    /// The server's per-call cost ledger for this job (§16.8).
    ///
    /// Sent on every view, not only the terminal one, and absent on jobs that
    /// have not called a provider yet — so `decodeIfPresent`, like every other
    /// field added after a build shipped.
    let usage: [RemoteCallAccounting]?
}

/// One provider call as `/api/jobs` reports it. Field names match the server's
/// `CallAccounting` exactly; the accompanying backend test is what keeps the
/// two from drifting.
struct RemoteCallAccounting: Decodable {
    let attempt: Int
    let provider: String
    let model: String
    let purpose: String
    let promptVersion: String
    /// `"success"` or `"failure"`. A plain string, not an enum, for the same
    /// reason `status` is: an unknown value must not fail the whole response.
    let outcome: String
    let failureReason: String?
    /// `measured` / `unmeasured` / `none` — see `ModelRunBilling`.
    let billing: String
    let usage: RemoteTokenUsage
    let estimatedCostUSD: Double
    let latencyMs: Int
}

struct RemoteTokenUsage: Decodable {
    let inputTokens: Int
    let cachedInputTokens: Int
    let outputTokens: Int
    let reasoningTokens: Int
}

struct RemoteJobsResponse: Decodable {
    let jobs: [RemoteJobView]
}

/// Field names match the server's JSON exactly (Faz 6 v2 contract — docs/FAZ6-PLAN.md §6).
struct RemoteCardsSuccess: Decodable {
    let output: RemoteCardsOutput
    let gate: RemoteCardGateReport
    /// Schema v2.3's coverage accounting. `decodeIfPresent`, like every field
    /// added after a build shipped: a job row written by an older deployment
    /// (and results live for 60 days) carries no such block.
    let coverage: RemoteCoverage?
    let cardPromptVersion: String
}

extension RemoteCardsSuccess {
    private enum CodingKeys: String, CodingKey {
        case output, gate, coverage, cardPromptVersion
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            output: try values.decode(RemoteCardsOutput.self, forKey: .output),
            gate: try values.decode(RemoteCardGateReport.self, forKey: .gate),
            coverage: try values.decodeIfPresent(RemoteCoverage.self, forKey: .coverage),
            cardPromptVersion: try values.decode(String.self, forKey: .cardPromptVersion)
        )
    }
}

/// `CardsSuccess.coverage` on the server (`providers/coverage.ts`).
///
/// The server's own `marks` array is deliberately not decoded: the phone shows
/// what is *missing*, and the full register is an audit artifact the page
/// screen has no use for. Extra keys are ignored by `Decodable`, so leaving it
/// out costs nothing and keeps the stored blob small.
struct RemoteCoverage: Decodable {
    let reported: Bool
    let uncovered: [RemoteMark]
    let unmarkedCardIds: [String]
}

/// In an extension so the memberwise initialiser survives — the tests build
/// these by hand, same reason as `RemoteCard`.
extension RemoteCoverage {
    private enum CodingKeys: String, CodingKey {
        case reported, uncovered, unmarkedCardIds
    }

    /// Every field defaulted rather than required. The block is an extra on a
    /// response whose real payload is the cards: a half-written coverage object
    /// must degrade to "no findings", never take a page's cards down with it.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            reported: (try? values.decode(Bool.self, forKey: .reported)) ?? false,
            uncovered: (try? values.decode([RemoteMark].self, forKey: .uncovered)) ?? [],
            unmarkedCardIds: (try? values.decode([String].self, forKey: .unmarkedCardIds)) ?? []
        )
    }
}

struct RemoteMark: Decodable {
    /// The model's own label ("m1"). Decoded but not used as identity — see
    /// `PageMark.id` for why a per-response label cannot survive a regeneration.
    let id: String
    /// Plain string, not `MarkKind`: an unknown tier must drop one mark, not
    /// fail the whole response (same rule as `RemoteCard.type`).
    let kind: String
    let quote: String
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
    /// `nil` for a card type this build has not heard of.
    ///
    /// Decoded leniently for the same reason `status` and `decision` are: a
    /// strict enum turned one unrecognized value into a decode failure for the
    /// *whole* response, so a server-side addition would cost an older client
    /// every card on the page — and, since a decode failure is reported as
    /// `schemaInvalid`, it would do so permanently. An unknown card is dropped
    /// and its siblings are kept (`map` filters them out).
    let type: CardType?
    let front: String
    let back: String
    let explanation: String
    let difficulty: Int
    let tags: [String]
    /// The model's own "I am unsure" signal (§6). Recorded but does not gate.
    let lowConfidence: Bool
    /// Schema v2.1 (§13.3). Absent on a v2.0 response and `null` on every card
    /// that is not five-option, so both decode to `nil` without a special case.
    let options: [RemoteCardOption]?
    let correctOption: Int?
    /// Schema v2.2: canonical topic from the subject's list. Absent on older
    /// responses and `null` when no subject was sent, both decoding to `nil`.
    let topic: String?
}

/// In an extension rather than the type body so the memberwise initialiser
/// survives — the tests build these by hand.
extension RemoteCard {
    private enum CodingKeys: String, CodingKey {
        case id, type, front, back, explanation, difficulty, tags, lowConfidence, options, correctOption, topic
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(String.self, forKey: .id),
            type: CardType(rawValue: try values.decode(String.self, forKey: .type)),
            front: try values.decode(String.self, forKey: .front),
            back: try values.decode(String.self, forKey: .back),
            explanation: try values.decode(String.self, forKey: .explanation),
            difficulty: try values.decode(Int.self, forKey: .difficulty),
            tags: try values.decode([String].self, forKey: .tags),
            lowConfidence: try values.decode(Bool.self, forKey: .lowConfidence),
            options: try values.decodeIfPresent([RemoteCardOption].self, forKey: .options),
            correctOption: try values.decodeIfPresent(Int.self, forKey: .correctOption),
            topic: try values.decodeIfPresent(String.self, forKey: .topic)
        )
    }
}

struct RemoteCardOption: Decodable {
    let text: String
    let correct: Bool
    /// Why this option is wrong; empty on the correct one.
    let why: String
}

struct RemoteUsage: Decodable {
    let provider: String
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let estimatedCostUSD: Double
    /// Optional because this one type decodes two different blocks: the card
    /// payload's §14 `usage` (which stays the shipped contract and carries only
    /// the totals) and `/api/second-opinion`'s, which reports the split. Absent
    /// means "this endpoint does not break the numbers down", not "zero".
    let cachedInputTokens: Int?
    let reasoningTokens: Int?
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
