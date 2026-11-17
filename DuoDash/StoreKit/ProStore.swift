import Foundation
import Observation

/// Duo Dash Pro: themes, home layout, app icons, dashcam impact detection and longer loops,
/// and trip history. Everything else in Duo Dash stays free.
///
/// Pro is any active subscription in the "Duo Dash Pro" group (monthly or yearly) or the
/// lifetime purchase. StoreKit sits behind `ProStoreBackend` so tests can drive it.
@MainActor
@Observable
final class ProStore {
    static let monthlyID = "com.duodash.pro.monthly"
    static let yearlyID = "com.duodash.pro.yearly"
    static let lifetimeID = "com.duodash.pro.lifetime"
    static let productIDs = [yearlyID, monthlyID, lifetimeID]
    static let subscriptionGroupName = "Duo Dash Pro"

    /// Apple's standard licence agreement and the app's privacy policy (App Review 3.1.2).
    static let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    static let privacyURL = URL(string: "https://github.com/yashpatilian/duo-dash/blob/main/PRIVACY.md")!

    /// The products as the App Store describes them (localised name and price), yearly first.
    private(set) var products: [ProProduct] = []
    /// Product IDs the user owns right now (verified, not revoked, not expired).
    private(set) var entitledIDs: Set<String>
    private(set) var isLoadingProducts = false
    /// Set when prices can't be loaded (offline, App Store unavailable).
    private(set) var productsError: String?
    /// The product being bought, while the App Store sheet is up.
    private(set) var purchasingID: String?
    private(set) var isRestoring = false
    /// A one-off line for the paywall: "Purchase pending approval", errors, "Nothing to restore".
    var message: String?

    /// The paywall is drawn by RootView over everything, so any locked control can open it.
    var isPaywallPresented = false
    /// Apple's manage-subscriptions sheet.
    var isManagingSubscriptions = false

    /// `-ProUnlocked` (UI tests, screenshots): Pro without the App Store.
    let isForcedUnlocked: Bool

    var isPro: Bool { isForcedUnlocked || !entitledIDs.isDisjoint(with: Self.productIDs) }

    /// Which purchase unlocks Pro, for the status row (lifetime wins over a subscription).
    var activeKind: ProProductKind? {
        if isForcedUnlocked { return .lifetime }
        if entitledIDs.contains(Self.lifetimeID) { return .lifetime }
        if entitledIDs.contains(Self.yearlyID) { return .yearly }
        if entitledIDs.contains(Self.monthlyID) { return .monthly }
        return nil
    }

    var hasSubscription: Bool { entitledIDs.contains(Self.yearlyID) || entitledIDs.contains(Self.monthlyID) }

    @ObservationIgnored private let backend: ProStoreBackend
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let cachesEntitlements: Bool
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var started = false

    static let cacheKey = "pro.entitledIDs"

    /// - Parameters:
    ///   - cachesEntitlements: remember the last answer so Pro features don't flash locked at launch
    ///     before StoreKit replies (StoreKit stays the source of truth: the next check overwrites it).
    init(backend: ProStoreBackend, defaults: UserDefaults = .standard, forcedUnlocked: Bool = false,
         cachesEntitlements: Bool = true) {
        self.backend = backend
        self.defaults = defaults
        self.isForcedUnlocked = forcedUnlocked
        self.cachesEntitlements = cachesEntitlements
        let cached = cachesEntitlements ? (defaults.stringArray(forKey: Self.cacheKey) ?? []) : []
        entitledIDs = Set(cached).intersection(Self.productIDs)
    }

    /// The app's store: StoreKit on devices; with `-UITest` a demo store (fixed A$ prices, no
    /// App Store), not Pro unless `-ProUnlocked` is also passed.
    static func live() -> ProStore {
        let args = ProcessInfo.processInfo.arguments
        let forced = args.contains("-ProUnlocked")
        if forced || LaunchOptions.isUITesting || args.contains("-DemoStore") {
            return ProStore(backend: DemoProBackend(), forcedUnlocked: forced, cachesEntitlements: false)
        }
        return ProStore(backend: StoreKitProBackend())
    }

    /// At launch: what the user owns, then prices, then listen for changes (renewals, refunds,
    /// Ask to Buy approvals, purchases on other devices). Safe to call more than once.
    func start() async {
        guard !started else { return }
        started = true
        updatesTask = backend.observeTransactions { [weak self] in
            Task { await self?.refreshEntitlements() }
        }
        await refreshEntitlements()
        await loadProducts()
    }

    func refreshEntitlements() async {
        let ids = await backend.entitledProductIDs()
        setEntitled(ids)
    }

    private func setEntitled(_ ids: Set<String>) {
        let known = ids.intersection(Self.productIDs)
        if known != entitledIDs { entitledIDs = known }
        if cachesEntitlements { defaults.set(Array(known).sorted(), forKey: Self.cacheKey) }
    }

    func loadProducts() async {
        guard !isLoadingProducts else { return }
        isLoadingProducts = true
        defer { isLoadingProducts = false }
        do {
            let loaded = try await backend.loadProducts(ids: Self.productIDs)
            products = loaded.sorted { $0.kind.sortOrder < $1.kind.sortOrder }
            productsError = loaded.isEmpty ? "Prices aren't available right now." : nil
        } catch {
            productsError = "Couldn't reach the App Store. Check the connection and try again."
        }
    }

    func product(_ kind: ProProductKind) -> ProProduct? { products.first { $0.kind == kind } }

    /// Buys a product. On success the paywall closes; pending (Ask to Buy) and errors leave a message.
    func purchase(_ product: ProProduct) async {
        guard purchasingID == nil else { return }
        purchasingID = product.id
        message = nil
        defer { purchasingID = nil }
        do {
            switch try await backend.purchase(productID: product.id) {
            case .purchased:
                await refreshEntitlements()
                if isPro { isPaywallPresented = false }
            case .pending:
                message = "Waiting for approval. Pro unlocks as soon as it's approved."
            case .cancelled:
                break
            }
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? "The purchase didn't go through. Please try again."
        }
    }

    /// Restore Purchases: syncs with the App Store (may ask the user to sign in).
    func restore() async {
        guard !isRestoring else { return }
        isRestoring = true
        message = nil
        defer { isRestoring = false }
        do {
            try await backend.sync()
        } catch {
            message = "Couldn't restore: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            return
        }
        await refreshEntitlements()
        if isPro {
            isPaywallPresented = false
        } else {
            message = "No Duo Dash Pro purchase was found for this Apple Account."
        }
    }

    func showPaywall() {
        message = nil
        isPaywallPresented = true
        if products.isEmpty { Task { await loadProducts() } }
    }
}

enum ProProductKind: String, CaseIterable, Sendable {
    case yearly, monthly, lifetime

    init?(productID: String) {
        switch productID {
        case ProStore.monthlyID: self = .monthly
        case ProStore.yearlyID: self = .yearly
        case ProStore.lifetimeID: self = .lifetime
        default: return nil
        }
    }

    var sortOrder: Int {
        switch self {
        case .yearly: 0
        case .monthly: 1
        case .lifetime: 2
        }
    }

    var title: String {
        switch self {
        case .yearly: "Yearly"
        case .monthly: "Monthly"
        case .lifetime: "Lifetime"
        }
    }

    /// Under the price on the paywall.
    var priceSuffix: String {
        switch self {
        case .yearly: "per year"
        case .monthly: "per month"
        case .lifetime: "One-time purchase"
        }
    }
}

/// A product as the paywall shows it. Prices are the App Store's own `displayPrice`.
struct ProProduct: Identifiable, Equatable, Sendable {
    let id: String
    let kind: ProProductKind
    var displayName: String
    var description: String
    var displayPrice: String
    /// "1 week free" when the user can still get the subscription's free trial; nil otherwise.
    var trialText: String?
}

enum ProPurchaseResult: Equatable, Sendable {
    case purchased, pending, cancelled
}

enum ProStoreError: LocalizedError, Equatable {
    case productUnavailable
    case unverified

    var errorDescription: String? {
        switch self {
        case .productUnavailable: "This option isn't available right now."
        case .unverified: "The App Store couldn't verify the purchase."
        }
    }
}

/// What ProStore needs from the App Store. `StoreKitProBackend` is the real one.
@MainActor
protocol ProStoreBackend: AnyObject {
    func loadProducts(ids: [String]) async throws -> [ProProduct]
    /// Products owned now: verified, not revoked, subscriptions not expired.
    func entitledProductIDs() async -> Set<String>
    func purchase(productID: String) async throws -> ProPurchaseResult
    /// Restore Purchases (`AppStore.sync()`).
    func sync() async throws
    /// Calls `onChange` for every transaction update until the task is cancelled.
    func observeTransactions(_ onChange: @escaping @MainActor () -> Void) -> Task<Void, Never>
}

/// The Simulator/UI-test store: fixed Australian prices, purchases unlock in memory.
@MainActor
final class DemoProBackend: ProStoreBackend {
    private var owned: Set<String> = []

    func loadProducts(ids: [String]) async throws -> [ProProduct] {
        [
            ProProduct(id: ProStore.yearlyID, kind: .yearly, displayName: "Duo Dash Pro Yearly",
                       description: "All Pro features, billed yearly.", displayPrice: "A$19.99", trialText: "1 week free"),
            ProProduct(id: ProStore.monthlyID, kind: .monthly, displayName: "Duo Dash Pro Monthly",
                       description: "All Pro features, billed monthly.", displayPrice: "A$2.99", trialText: nil),
            ProProduct(id: ProStore.lifetimeID, kind: .lifetime, displayName: "Duo Dash Pro Lifetime",
                       description: "All Pro features, forever.", displayPrice: "A$39.99", trialText: nil),
        ].filter { ids.contains($0.id) }
    }

    func entitledProductIDs() async -> Set<String> { owned }

    func purchase(productID: String) async throws -> ProPurchaseResult {
        owned.insert(productID)
        return .purchased
    }

    func sync() async throws {}

    func observeTransactions(_ onChange: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        Task {}
    }
}
