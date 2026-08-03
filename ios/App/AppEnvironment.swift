import Foundation
import SwiftData
import SwiftUI
import CizgiCore

/// Shared services for the app.
///
/// Vision OCR and the offline mock generator are always available; cloud OCR
/// and real card generation (§25 Faz 2/3) switch on together, behind the same
/// protocols, the moment Settings has a backend URL and device token.
@MainActor
final class AppEnvironment: ObservableObject {
    let imageStore: ImageStore
    let scheduler: any ReviewScheduling
    let queue: ProcessingQueue
    let tokenStore: any DeviceTokenStoring

    @Published var settings: AppSettings
    /// Published rather than recomputed: SwiftUI re-runs `body` often, and
    /// deriving this on demand meant a Keychain query and a client
    /// construction on every render of the settings screen.
    @Published private(set) var isBackendConfigured = false
    @Published private(set) var hasDeviceToken = false

    init(container: ModelContainer) throws {
        let store = try ImageStore(root: try ImageStore.defaultRoot())
        self.imageStore = store
        self.scheduler = Self.makeScheduler()
        let settings = AppSettings.load()
        self.settings = settings

        #if canImport(Security)
        let tokens: any DeviceTokenStoring = KeychainDeviceTokenStore()
        #else
        let tokens: any DeviceTokenStoring = InMemoryDeviceTokenStore()
        #endif
        self.tokenStore = tokens

        #if canImport(Vision)
        let recognizer: any TextRecognizing = VisionTextRecognizer()
        #else
        let recognizer: any TextRecognizing = UnavailableRecognizer()
        #endif

        // `settings`/`tokens` are local copies, not `self.settings`/`self.tokenStore`:
        // reading a property through `self` here would trip Swift's "used before all
        // stored properties are initialized" check, since `queue` itself is still
        // mid-assignment.
        self.queue = ProcessingQueue(
            container: container,
            imageStore: store,
            pipeline: CapturePipeline(
                recognizer: recognizer,
                selector: Self.makeSelector(),
                generator: Self.makeCardGenerator(settings: settings, tokens: tokens),
                backend: Self.makeBackend(settings: settings, tokens: tokens)
            )
        )
        refreshBackendState()
    }

    /// On-device marker detection, falling back to manual selection if the
    /// bundled thresholds cannot be read.
    ///
    /// The fallback asks the user for every page rather than guessing, which
    /// is the behaviour §19.3 requires when no marker was detected. A detector
    /// that silently selected everything would be the dangerous failure.
    static func makeSelector() -> any MarkerSelecting {
        (try? DetectedMarkerSelector()) ?? ManualSelectionOnly()
    }

    /// FSRS-6 (§18.1), falling back to the non-FSRS placeholder if the
    /// bundled weights cannot be read.
    ///
    /// Same reasoning as `makeSelector()`: a config-loading component throws
    /// rather than substituting built-in numbers (§0.6), so the safe
    /// fallback lives here, at the one call site, not inside the scheduler.
    static func makeScheduler() -> any ReviewScheduling {
        (try? FSRSScheduler()) ?? PlaceholderScheduler()
    }

    /// Resolves Settings into a `BackendConfiguration`, or nil when the user
    /// has not set up a backend. The one place the URL/token validity check
    /// lives, so `makeBackend` and `makeCardGenerator` cannot drift into
    /// deciding "configured" differently from each other.
    static func resolvedBackendConfiguration(
        settings: AppSettings,
        tokens: any DeviceTokenStoring
    ) -> BackendConfiguration? {
        let trimmed = settings.backendURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmed.isEmpty,
            let url = URL(string: trimmed),
            url.scheme != nil,
            tokens.read()?.isEmpty == false
        else { return nil }
        return BackendConfiguration(baseURL: url)
    }

    /// Builds the cloud OCR client, or nil when the user has not set it up.
    ///
    /// Nil is a normal state, not an error: capture, local OCR and review all
    /// work without it (§24.1, §24.5). What does not work is Turkish text,
    /// which is why Settings says so out loud rather than letting the app look
    /// broken.
    static func makeBackend(
        settings: AppSettings,
        tokens: any DeviceTokenStoring
    ) -> (any BackendCalling)? {
        guard let configuration = resolvedBackendConfiguration(settings: settings, tokens: tokens) else {
            return nil
        }
        return BackendClient(
            configuration: configuration,
            // Read per call rather than captured, so changing the token in
            // Settings takes effect on the next page instead of next launch.
            tokenProvider: { tokens.read() }
        )
    }

    /// Real card generation once a backend is configured, `MockCardProvider`
    /// otherwise — the same on/off condition as `makeBackend`, so cards never
    /// go real while OCR is still local (§25 Faz 3).
    static func makeCardGenerator(
        settings: AppSettings,
        tokens: any DeviceTokenStoring
    ) -> any CardGenerating {
        guard let configuration = resolvedBackendConfiguration(settings: settings, tokens: tokens) else {
            return MockCardProvider()
        }
        return BackendCardProvider(
            configuration: configuration,
            tokenProvider: { tokens.read() }
        )
    }

    /// Re-reads the settings and rebuilds the cloud client. Called when the
    /// user edits the backend URL or the token.
    func backendChanged() {
        queue.setBackend(Self.makeBackend(settings: settings, tokens: tokenStore))
        queue.setCardGenerator(Self.makeCardGenerator(settings: settings, tokens: tokenStore))
        refreshBackendState()
    }

    private func refreshBackendState() {
        hasDeviceToken = tokenStore.read()?.isEmpty == false
        isBackendConfigured = Self.makeBackend(settings: settings, tokens: tokenStore) != nil
    }
}

/// User-facing preferences (§6.7). Stored in UserDefaults; nothing here is
/// sensitive.
struct AppSettings: Codable, Equatable {
    /// Base URL of the backend proxy, e.g. `https://cizgi.example.com`.
    /// Not a secret — the device token is what authorizes, and that lives in
    /// the Keychain (§7.3).
    var backendURL: String = ""
    var defaultSubject: String = ""
    var maxCardsPerPassage: Int = 2
    var sourceFaithfulOnly: Bool = true
    var notificationHour: Int = 20
    var notificationsEnabled: Bool = false
    var dailyNewCardLimit: Int = 20
    var quickSessionMinutes: Int = 5
    var keepOriginalPage: Bool = true

    static let storageKey = "cizgi.settings.v1"

    private enum CodingKeys: String, CodingKey {
        case backendURL, defaultSubject, maxCardsPerPassage, sourceFaithfulOnly
        case notificationHour, notificationsEnabled, dailyNewCardLimit
        case quickSessionMinutes, keepOriginalPage
    }

    init() {}

    /// Decode each preference independently so adding a Faz 5 setting does
    /// not reset existing backend or capture preferences after an upgrade.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        backendURL = try values.decodeIfPresent(String.self, forKey: .backendURL) ?? ""
        defaultSubject = try values.decodeIfPresent(String.self, forKey: .defaultSubject) ?? ""
        maxCardsPerPassage = try values.decodeIfPresent(Int.self, forKey: .maxCardsPerPassage) ?? 2
        sourceFaithfulOnly = try values.decodeIfPresent(Bool.self, forKey: .sourceFaithfulOnly) ?? true
        notificationHour = try values.decodeIfPresent(Int.self, forKey: .notificationHour) ?? 20
        notificationsEnabled = try values.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? false
        dailyNewCardLimit = try values.decodeIfPresent(Int.self, forKey: .dailyNewCardLimit) ?? 20
        quickSessionMinutes = try values.decodeIfPresent(Int.self, forKey: .quickSessionMinutes) ?? 5
        keepOriginalPage = try values.decodeIfPresent(Bool.self, forKey: .keepOriginalPage) ?? true
    }

    static func load() -> AppSettings {
        guard
            let data = UserDefaults.standard.data(forKey: storageKey),
            let decoded = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return AppSettings() }
        return decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}

/// Used on platforms without Vision so the app still builds and the failure is
/// explicit rather than a silent empty result.
struct UnavailableRecognizer: TextRecognizing {
    func recognize(imageAt url: URL) async throws -> RecognizedPage {
        throw TextRecognitionError.recognitionFailed("Bu platformda Vision yok")
    }
}
