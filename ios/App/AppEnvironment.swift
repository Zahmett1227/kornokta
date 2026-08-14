import Foundation
import SwiftData
import SwiftUI
import CizgiCore

/// Shared services for the app.
///
/// The offline mock generator is always available; real card generation
/// (Faz 6 vision flow) switches on the moment Settings has a backend URL and
/// device token.
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

        // `settings`/`tokens` are local copies, not `self.settings`/`self.tokenStore`:
        // reading a property through `self` here would trip Swift's "used before all
        // stored properties are initialized" check, since `queue` itself is still
        // mid-assignment.
        self.queue = ProcessingQueue(
            container: container,
            imageStore: store,
            pipeline: CapturePipeline(
                generator: Self.makeCardGenerator(settings: settings, tokens: tokens)
            )
        )
        refreshBackendState()
    }

    /// FSRS-6 (§18.1), falling back to the non-FSRS placeholder if the
    /// bundled weights cannot be read: a config-loading component throws
    /// rather than substituting built-in numbers (§0.6), so the safe
    /// fallback lives here, at the one call site, not inside the scheduler.
    static func makeScheduler() -> any ReviewScheduling {
        (try? FSRSScheduler()) ?? PlaceholderScheduler()
    }

    /// Resolves Settings into a `BackendConfiguration`, or nil when the user
    /// has not set up a backend. The one place the URL/token validity check
    /// lives, so "configured" cannot be decided differently in two places.
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

    /// Real card generation once a backend is configured, `MockCardProvider`
    /// otherwise. Nil configuration is a normal state, not an error: capture
    /// and review both work without it (§24.1, §24.5); Settings says out loud
    /// that generation is offline rather than letting the app look broken.
    static func makeCardGenerator(
        settings: AppSettings,
        tokens: any DeviceTokenStoring
    ) -> any CardGenerating {
        guard let configuration = resolvedBackendConfiguration(settings: settings, tokens: tokens) else {
            return MockCardProvider()
        }
        // Under ADR-006 every card call is short — a page upload or a small
        // poll — so these are upper bounds rather than the norm they were when
        // the phone had to hold one connection open for the whole generation.
        // Kept generous anyway: `URLSession.shared` would cap a request at its
        // config's 60 s, which the retained synchronous `/api/cards-vision`
        // path still needs to exceed.
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = configuration.timeout
        sessionConfig.timeoutIntervalForResource = configuration.timeout
        // A page batch runs for minutes, and a phone moving between Wi-Fi and
        // cellular in that window would otherwise fail the request instantly
        // and burn one of its five retry attempts on a blip that resolved
        // itself a second later. Waiting is bounded by the resource timeout
        // above, so this cannot hang past the ceiling the backend already has.
        sessionConfig.waitsForConnectivity = true
        return BackendCardProvider(
            configuration: configuration,
            tokenProvider: { tokens.read() },
            session: URLSession(configuration: sessionConfig)
        )
    }

    /// Client for the "İkinci görüş iste" button (Gemini re-read of a
    /// `lowConfidence` card, backend `/api/second-opinion`).
    ///
    /// Built per use rather than held: the button lives on a detail screen the
    /// user reaches rarely, and resolving here means an edited URL or token is
    /// always current without this type joining `backendChanged()`'s rebuild
    /// list. Nil while the backend is unconfigured — the caller explains
    /// instead of failing.
    func makeSecondOpinionProvider() -> SecondOpinionProvider? {
        guard let configuration = Self.resolvedBackendConfiguration(settings: settings, tokens: tokenStore)
        else { return nil }
        let tokens = tokenStore
        return SecondOpinionProvider(
            configuration: configuration,
            tokenProvider: { tokens.read() }
        )
    }

    /// Re-reads the settings and rebuilds the cloud client. Called when the
    /// user edits the backend URL or the token.
    func backendChanged() {
        queue.setCardGenerator(Self.makeCardGenerator(settings: settings, tokens: tokenStore))
        refreshBackendState()
    }

    private func refreshBackendState() {
        hasDeviceToken = tokenStore.read()?.isEmpty == false
        isBackendConfigured = Self.resolvedBackendConfiguration(settings: settings, tokens: tokenStore) != nil
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
    /// Legacy. Kept so an existing install still decodes, but no longer read:
    /// see `maxCardsPerPage`.
    var maxCardsPerPassage: Int = 2
    /// Cards the model may produce from one marked page (§6.7).
    ///
    /// A new key rather than a new meaning for `maxCardsPerPassage`. That one
    /// was written for the pre-Faz-6 "one passage → ≤4 cards" flow and was never
    /// actually sent to the server, so every install has a stored 2 in it —
    /// wiring it up would have silently capped every page at two cards and
    /// undone B3's deliberate raise to 12 (since raised to 18, 2026-08-14).
    var maxCardsPerPage: Int = 18
    /// Five-option cards (§13.3). Stored as the wire value so the setting and
    /// the request body cannot drift apart.
    var multipleChoiceModeRaw: String = MultipleChoiceMode.mixed.rawValue

    /// An unknown stored value reads as the default rather than crashing: the
    /// string comes from this device's own defaults, but a downgrade or a
    /// hand-edited plist should not take the app with it.
    var multipleChoiceMode: MultipleChoiceMode {
        get { MultipleChoiceMode(rawValue: multipleChoiceModeRaw) ?? .mixed }
        set { multipleChoiceModeRaw = newValue.rawValue }
    }
    var sourceFaithfulOnly: Bool = true
    var notificationHour: Int = 20
    var notificationsEnabled: Bool = false
    var dailyNewCardLimit: Int = 20
    var quickSessionMinutes: Int = 5
    var keepOriginalPage: Bool = true

    static let storageKey = "cizgi.settings.v1"

    private enum CodingKeys: String, CodingKey {
        case backendURL, defaultSubject, maxCardsPerPassage, maxCardsPerPage, sourceFaithfulOnly
        case multipleChoiceModeRaw
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
        maxCardsPerPage = try values.decodeIfPresent(Int.self, forKey: .maxCardsPerPage) ?? 18
        multipleChoiceModeRaw = try values.decodeIfPresent(String.self, forKey: .multipleChoiceModeRaw)
            ?? MultipleChoiceMode.mixed.rawValue
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

/// Persistence for the daily new-card tally (§6.7's "günlük yeni kart").
///
/// Separate from `AppSettings` on purpose: that is what the user chose, this is
/// what has happened. Mixing them would put a counter that changes several times
/// a minute into the same blob as preferences, and make "reset my settings" also
/// reset today's allowance.
///
/// Kept in `UserDefaults` rather than SwiftData because it is a single small
/// value read on every review screen appearance, and because the review screen
/// must keep working offline and without a store fetch (§24.5). The type itself
/// lives in CizgiCore, where its day-boundary logic is unit-tested.
extension DailyNewCardLedger {
    static let storageKey = "cizgi.newCardLedger.v1"

    static func load() -> DailyNewCardLedger {
        guard
            let data = UserDefaults.standard.data(forKey: storageKey),
            let decoded = try? JSONDecoder().decode(DailyNewCardLedger.self, from: data)
        else { return DailyNewCardLedger() }
        return decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
