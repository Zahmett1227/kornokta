import Foundation

/// One card as the auditor needs to see it: the question and the answer, and
/// nothing else. The audit is asked what is *missing*, not whether a card is
/// right, so it has no use for the rest.
public struct CoverageAuditCard: Sendable, Equatable, Encodable {
    public let front: String
    public let back: String

    public init(front: String, back: String) {
        self.front = front
        self.back = back
    }
}

/// The independent reader's answer for one page (`/api/coverage`,
/// docs/PLAN-kapsama-sozlesmesi.md Katman B).
public struct CoverageAudit: Sendable, Equatable {
    /// Every mark the auditor reported, whether carded or not — the
    /// denominator behind "it saw N marks and k of them have no card".
    public let markCount: Int
    /// The marks it found no card for, most valuable tier first (the server
    /// sorts; the phone does not re-derive that order).
    public let uncovered: [PageMark]
    /// Rows the server dropped as unusable. Surfaced rather than hidden: a
    /// number that climbs says the auditor is confused about the card list,
    /// which is worth knowing before trusting the rest of its answer.
    public let discarded: Int
    /// What the call cost (§16.8). Optional so an older server without the
    /// block cannot fail the whole response; the same wire type the second
    /// opinion decodes, because it is the same block.
    public let usage: SecondOpinion.Usage?
    /// For the `ModelRun` record, same role as `cardPromptVersion` on cards.
    public let promptVersion: String?

    public init(
        markCount: Int,
        uncovered: [PageMark],
        discarded: Int,
        usage: SecondOpinion.Usage?,
        promptVersion: String?
    ) {
        self.markCount = markCount
        self.uncovered = uncovered
        self.discarded = discarded
        self.usage = usage
        self.promptVersion = promptVersion
    }
}

/// Why an audit failed, and — when the server said — how it should be counted.
///
/// This started as a type alias for `SecondOpinionError`, on the grounds that
/// both are one user-initiated call to the same backend against the same
/// provider. The review found the seam that argument missed (Codex, PR #47):
/// the ledger needs to know whether a failed call was *billed*, and that verdict
/// cannot be derived from anything the alias carries. A 429 is retryable and
/// free; a safety stop is permanent and billed — inferring billing from
/// `retryable` gets both backwards. So the server states it and this type
/// carries it, which the shared alias had nowhere to put.
public enum CoverageAuditError: Error, LocalizedError, Equatable {
    /// No backend URL or device token — the button should not even have fired.
    case notConfigured
    /// Network-level failure; worth another tap (§17).
    case transport(String)
    /// The server answered with an error. The message travels verbatim: the
    /// backend already names the real suspect ("Gemini kotası/kredisi
    /// tükenmiş…"), and rewording it here would undo exactly that.
    ///
    /// `billing` is the server's own classification (`ModelRunBilling`), or
    /// `nil` for a refusal that never involved a provider — a malformed body, a
    /// missing key — where there is nothing to account for.
    case server(String, retryable: Bool, billing: String?)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Backend ayarlı değil (Ayarlar → Backend)."
        case .transport(let message):
            return "Bağlantı kurulamadı: \(message)"
        case .server(let message, _, _):
            return message
        case .invalidResponse(let message):
            return "Sunucu yanıtı çözümlenemedi: \(message)"
        }
    }

    /// Whether "Tekrar dene" is worth offering.
    public var retryable: Bool {
        switch self {
        case .notConfigured: return false
        case .transport: return true
        case .server(_, let retryable, _): return retryable
        case .invalidResponse: return false
        }
    }

    /// How the phone's ledger should record this failed call.
    ///
    /// Only the server can answer it, so anything it did not classify is
    /// `unmeasured`: a call that got far enough to fail on our side of the
    /// wire may well have been generated and billed, and overstating a failure
    /// is the safe direction — the same choice the cached-token price makes in
    /// `config.ts`.
    public var billing: String {
        switch self {
        case .notConfigured: return ModelRunBilling.none
        case .server(_, _, let billing): return billing ?? ModelRunBilling.unmeasured
        case .transport, .invalidResponse: return ModelRunBilling.unmeasured
        }
    }
}

/// `POST /api/coverage` — the on-demand independent re-read of a page,
/// answering "which marks did the generator leave uncarded?".
///
/// Modelled on `SecondOpinionProvider` on purpose, including what it is *not*:
/// not part of `CardGenerating`, not in the processing queue, no job row, no
/// retry machinery. It is a button the owner presses while looking at a
/// finished page. The server's copy of the photo is long deleted by then, so
/// the phone re-uploads its own stored original (downscaled by
/// `UploadImageEncoder`, the same budget a capture upload gets).
///
/// The manual trigger is a decision, not a limitation: an automatic audit on
/// every page would spend on pages nobody will look at, and a manual one is the
/// cheapest way to learn how often it is right before making it automatic —
/// the same reasoning `docs/PLAN-model-karsilastirma.md` gives for the manual
/// "Sol'la yeniden üret" button.
public struct CoverageAuditProvider: Sendable {
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
        imageData: Data,
        mimeType: String,
        cards: [CoverageAuditCard]
    ) async throws -> CoverageAudit {
        guard let token = tokenProvider(), !token.isEmpty else {
            throw CoverageAuditError.notConfigured
        }

        var urlRequest = URLRequest(url: configuration.baseURL.appendingPathComponent("api/coverage"))
        urlRequest.httpMethod = "POST"
        // The server aborts its own provider call at GEMINI_TIMEOUT_MS; this
        // only needs to outlive that plus the upload.
        urlRequest.timeoutInterval = configuration.timeout
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(
            RequestBody(
                requestId: requestId,
                mimeType: mimeType,
                imageBase64: imageData.base64EncodedString(),
                cards: cards
            )
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw CoverageAuditError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw CoverageAuditError.transport("Beklenmeyen yanıt türü.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let failure = try? JSONDecoder().decode(FailureBody.self, from: data)
            throw CoverageAuditError.server(
                failure?.error ?? "Sunucu hatası (\(http.statusCode)).",
                retryable: failure?.retryable ?? (http.statusCode >= 500),
                billing: failure?.billing
            )
        }
        return try Self.parse(data)
    }

    /// Split out for the same reason `SecondOpinionProvider.parse` is: it is
    /// the one decision worth testing and this package has no HTTP stub.
    static func parse(_ data: Data) throws -> CoverageAudit {
        let decoded: RemoteCoverageAudit
        do {
            decoded = try JSONDecoder().decode(RemoteCoverageAudit.self, from: data)
        } catch {
            throw CoverageAuditError.invalidResponse("\(error)")
        }

        return CoverageAudit(
            markCount: decoded.marks.count,
            uncovered: decoded.uncovered.compactMap { mark in
                // An unknown tier drops one row and keeps the rest — the same
                // leniency an unknown card type gets, for the same reason.
                guard let kind = MarkKind(rawValue: mark.kind) else { return nil }
                return PageMark(kind: kind, quote: mark.quote, source: .auditor)
            },
            discarded: decoded.discarded ?? 0,
            usage: decoded.usage.map {
                SecondOpinion.Usage(
                    provider: $0.provider,
                    model: $0.model,
                    inputTokens: $0.inputTokens,
                    cachedInputTokens: $0.cachedInputTokens ?? 0,
                    outputTokens: $0.outputTokens,
                    reasoningTokens: $0.reasoningTokens ?? 0,
                    estimatedCostUSD: $0.estimatedCostUSD
                )
            },
            promptVersion: decoded.promptVersion
        )
    }

    private struct RequestBody: Encodable {
        let requestId: String
        let mimeType: String
        let imageBase64: String
        let cards: [CoverageAuditCard]
    }

    private struct FailureBody: Decodable {
        let error: String
        let retryable: Bool
        /// `measured` / `unmeasured` / `none`. Absent from a refusal that never
        /// reached a provider, and from any server older than this contract.
        let billing: String?
    }
}

/// Field names match the server's JSON exactly (`_coverage.ts`). `usage` reuses
/// card generation's own wire type: the server sends the same shape on every
/// endpoint that costs money, on purpose.
struct RemoteCoverageAudit: Decodable {
    let requestId: String
    /// Every mark the auditor reported. Only its count is used today; the list
    /// is decoded because "it looked at 14 marks" is what makes "2 uncovered"
    /// mean something.
    let marks: [RemoteAuditedMark]
    let uncovered: [RemoteAuditedMark]
    let discarded: Int?
    let usage: RemoteUsage?
    let promptVersion: String?
}

struct RemoteAuditedMark: Decodable {
    /// Plain string, not `MarkKind` — an unknown tier must drop one mark, not
    /// fail the whole response.
    let kind: String
    let quote: String
    /// Index into the cards the phone sent, or `nil` for "no card covers this".
    /// Decoded for completeness; the server has already split the list.
    let coveredByCardIndex: Int?
}
