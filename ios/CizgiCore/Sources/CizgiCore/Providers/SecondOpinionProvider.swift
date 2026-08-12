import Foundation

/// One second opinion, as the phone understands it.
///
/// `verdict` is `nil` for a value this build has not heard of — decoded
/// leniently for the same reason `RemoteJobView.status` is a plain string: a
/// server-side addition must not fail the whole response on an older client.
/// The raw string is kept so the UI can still show *something* honest.
public struct SecondOpinion: Sendable, Equatable {
    public enum Verdict: String, Sendable {
        /// The page supports what the card says.
        case supports
        /// The page contradicts the card (misread prefix, wrong number/unit…).
        case contradicts
        /// The second reader could not read the region confidently either.
        case unclear
    }

    /// What the call cost, as the server reported it (§16.8). Optional so an
    /// older server without the block cannot fail the whole response; without
    /// it the caller simply has nothing to account.
    public struct Usage: Sendable, Equatable {
        public let provider: String
        public let model: String
        public let inputTokens: Int
        /// Subset of `inputTokens` served from the provider's cache, billed cheaper.
        public let cachedInputTokens: Int
        public let outputTokens: Int
        /// Subset of `outputTokens` spent on hidden reasoning, billed at the output rate.
        public let reasoningTokens: Int
        public let estimatedCostUSD: Double

        public init(
            provider: String,
            model: String,
            inputTokens: Int,
            cachedInputTokens: Int = 0,
            outputTokens: Int,
            reasoningTokens: Int = 0,
            estimatedCostUSD: Double
        ) {
            self.provider = provider
            self.model = model
            self.inputTokens = inputTokens
            self.cachedInputTokens = cachedInputTokens
            self.outputTokens = outputTokens
            self.reasoningTokens = reasoningTokens
            self.estimatedCostUSD = estimatedCostUSD
        }
    }

    public let verdict: Verdict?
    public let verdictRaw: String
    /// The independent transcription (≤3 candidates per unclear spot).
    public let reading: String
    /// One-sentence explanation, mainly on `contradicts`.
    public let note: String?
    public let usage: Usage?
    /// For the `ModelRun` record, same role as `cardPromptVersion` on cards.
    public let promptVersion: String?

    public init(verdictRaw: String, reading: String, note: String?, usage: Usage?, promptVersion: String?) {
        self.verdict = Verdict(rawValue: verdictRaw)
        self.verdictRaw = verdictRaw
        self.reading = reading
        self.note = note
        self.usage = usage
        self.promptVersion = promptVersion
    }
}

public enum SecondOpinionError: Error, LocalizedError, Equatable {
    /// No backend URL or device token — the button should not even have fired.
    case notConfigured
    /// Network-level failure; worth another tap (§17).
    case transport(String)
    /// The server answered with an error. The message travels verbatim: the
    /// backend already names the real suspect ("Gemini kotası/kredisi
    /// tükenmiş…"), and rewording it here would undo exactly that.
    case server(String, retryable: Bool)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Backend ayarlı değil (Ayarlar → Backend)."
        case .transport(let message):
            return "Bağlantı kurulamadı: \(message)"
        case .server(let message, _):
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
        case .server(_, let retryable): return retryable
        case .invalidResponse: return false
        }
    }
}

/// `POST /api/second-opinion` — the on-demand independent re-read of a
/// `lowConfidence` card's source page (backend `_secondOpinion.ts`).
///
/// Deliberately not part of `CardGenerating` or the processing queue: this is
/// a button the user presses while already looking at a doubtful card, one
/// short synchronous call, no retry machinery, no job row. The server's copy
/// of the page is long deleted by the time anyone reviews a card, so the
/// phone re-uploads its own stored original (downscaled by
/// `UploadImageEncoder`, same budget as a capture upload).
public struct SecondOpinionProvider: Sendable {
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
        front: String,
        back: String,
        explanation: String?
    ) async throws -> SecondOpinion {
        guard let token = tokenProvider(), !token.isEmpty else {
            throw SecondOpinionError.notConfigured
        }

        var urlRequest = URLRequest(url: configuration.baseURL.appendingPathComponent("api/second-opinion"))
        urlRequest.httpMethod = "POST"
        // The server aborts its own provider call at GEMINI_TIMEOUT_MS (60 s);
        // this only needs to outlive that plus the upload.
        urlRequest.timeoutInterval = configuration.timeout
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(
            RequestBody(
                requestId: requestId,
                mimeType: mimeType,
                imageBase64: imageData.base64EncodedString(),
                card: RequestBody.CardBody(
                    front: front,
                    back: back,
                    // Omitted rather than sent empty, matching the server's
                    // "explanation isteğe bağlı" contract.
                    explanation: Self.normalized(explanation)
                )
            )
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw SecondOpinionError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw SecondOpinionError.transport("Beklenmeyen yanıt türü.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let failure = try? JSONDecoder().decode(FailureBody.self, from: data)
            throw SecondOpinionError.server(
                failure?.error ?? "Sunucu hatası (\(http.statusCode)).",
                retryable: failure?.retryable ?? (http.statusCode >= 500)
            )
        }
        return try Self.parse(data)
    }

    /// `nil` for a blank or absent text, the trimmed text otherwise.
    static func normalized(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    /// Split out of `request` because it is the one decision worth testing and
    /// this package has no HTTP stub — same constraint that keeps
    /// `BackendCardProvider.map` internal rather than private.
    static func parse(_ data: Data) throws -> SecondOpinion {
        let decoded: RemoteSecondOpinion
        do {
            decoded = try JSONDecoder().decode(RemoteSecondOpinion.self, from: data)
        } catch {
            throw SecondOpinionError.invalidResponse("\(error)")
        }
        let note = decoded.note?.trimmingCharacters(in: .whitespacesAndNewlines)
        return SecondOpinion(
            verdictRaw: decoded.verdict,
            reading: decoded.reading,
            note: (note?.isEmpty ?? true) ? nil : note,
            // Kept even though the opinion text itself is ephemeral: Ayarlar →
            // Kullanım totals `ModelRun`, and a paid call that never lands
            // there permanently underreports cost (Codex, PR #39).
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
        struct CardBody: Encodable {
            let front: String
            let back: String
            let explanation: String?
        }

        let requestId: String
        let mimeType: String
        let imageBase64: String
        let card: CardBody
    }

    private struct FailureBody: Decodable {
        let error: String
        let retryable: Bool
    }
}

/// Field names match the server's JSON exactly (`_secondOpinion.ts`).
/// `verdict` stays a plain string on the wire — see `SecondOpinion.verdict`.
/// `usage` reuses card generation's own wire type: the server sends the same
/// shape on both endpoints on purpose.
struct RemoteSecondOpinion: Decodable {
    let requestId: String
    let verdict: String
    let reading: String
    let note: String?
    let usage: RemoteUsage?
    let promptVersion: String?
}
