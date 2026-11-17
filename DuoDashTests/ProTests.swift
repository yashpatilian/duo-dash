import XCTest
import CoreLocation
@testable import DuoDash

/// Duo Dash Pro: store gating (through the backend protocol), themes, Home layout, the
/// dashcam's Pro options and edition gate, impact detection and trip recording.
@MainActor
final class ProTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var folder: URL!

    override func setUp() async throws {
        suiteName = "ProTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        folder = FileManager.default.temporaryDirectory.appending(path: "ProTests-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: ProStore

    /// A scripted App Store.
    private final class FakeBackend: ProStoreBackend {
        var products: [ProProduct] = [
            ProProduct(id: ProStore.monthlyID, kind: .monthly, displayName: "Monthly", description: "", displayPrice: "A$2.99"),
            ProProduct(id: ProStore.lifetimeID, kind: .lifetime, displayName: "Lifetime", description: "", displayPrice: "A$39.99"),
            ProProduct(id: ProStore.yearlyID, kind: .yearly, displayName: "Yearly", description: "", displayPrice: "A$19.99", trialText: "1 week free"),
        ]
        var owned: Set<String> = []
        var restoredOnSync: Set<String> = []
        var purchaseResult: ProPurchaseResult = .purchased
        var failLoading = false
        var onChange: (@MainActor () -> Void)?

        func loadProducts(ids: [String]) async throws -> [ProProduct] {
            if failLoading { throw URLError(.notConnectedToInternet) }
            return products.filter { ids.contains($0.id) }
        }
        func entitledProductIDs() async -> Set<String> { owned }
        func purchase(productID: String) async throws -> ProPurchaseResult {
            if purchaseResult == .purchased { owned.insert(productID) }
            return purchaseResult
        }
        func sync() async throws { owned.formUnion(restoredOnSync) }
        func observeTransactions(_ onChange: @escaping @MainActor () -> Void) -> Task<Void, Never> {
            self.onChange = onChange
            return Task {}
        }
    }

    func testNotProWithoutEntitlementsAndProductsSortedYearlyFirst() async {
        let backend = FakeBackend()
        let store = ProStore(backend: backend, defaults: defaults)
        await store.start()
        XCTAssertFalse(store.isPro)
        XCTAssertNil(store.activeKind)
        XCTAssertEqual(store.products.map(\.kind), [.yearly, .monthly, .lifetime])
        XCTAssertEqual(store.product(.yearly)?.trialText, "1 week free")
        XCTAssertNil(store.productsError)
    }

    func testAnySubscriptionOrLifetimeIsPro() async {
        for id in ProStore.productIDs {
            let backend = FakeBackend()
            backend.owned = [id]
            let store = ProStore(backend: backend, defaults: defaults, cachesEntitlements: false)
            await store.refreshEntitlements()
            XCTAssertTrue(store.isPro, id)
        }
        // Something unrelated isn't.
        let backend = FakeBackend()
        backend.owned = ["com.duodash.tip"]
        let store = ProStore(backend: backend, defaults: defaults, cachesEntitlements: false)
        await store.refreshEntitlements()
        XCTAssertFalse(store.isPro)
    }

    func testLifetimeWinsForTheStatusRow() async {
        let backend = FakeBackend()
        backend.owned = [ProStore.monthlyID, ProStore.lifetimeID]
        let store = ProStore(backend: backend, defaults: defaults)
        await store.refreshEntitlements()
        XCTAssertEqual(store.activeKind, .lifetime)
        XCTAssertTrue(store.hasSubscription)
    }

    func testPurchaseUnlocksAndClosesThePaywall() async {
        let backend = FakeBackend()
        let store = ProStore(backend: backend, defaults: defaults)
        await store.start()
        store.showPaywall()
        XCTAssertTrue(store.isPaywallPresented)
        await store.purchase(store.product(.lifetime)!)
        XCTAssertTrue(store.isPro)
        XCTAssertFalse(store.isPaywallPresented)
        XCTAssertNil(store.purchasingID)
    }

    func testPendingAndCancelledPurchasesDontUnlock() async {
        let backend = FakeBackend()
        let store = ProStore(backend: backend, defaults: defaults)
        await store.start()
        store.showPaywall()
        backend.purchaseResult = .pending
        await store.purchase(store.product(.monthly)!)
        XCTAssertFalse(store.isPro)
        XCTAssertNotNil(store.message, "Ask to Buy says it's waiting")
        XCTAssertTrue(store.isPaywallPresented)
        backend.purchaseResult = .cancelled
        await store.purchase(store.product(.monthly)!)
        XCTAssertFalse(store.isPro)
    }

    func testRestore() async {
        let backend = FakeBackend()
        let store = ProStore(backend: backend, defaults: defaults)
        await store.restore()
        XCTAssertFalse(store.isPro)
        XCTAssertNotNil(store.message, "nothing to restore is said")
        backend.restoredOnSync = [ProStore.yearlyID]
        store.showPaywall()
        await store.restore()
        XCTAssertTrue(store.isPro)
        XCTAssertFalse(store.isPaywallPresented)
    }

    func testTransactionUpdatesRefreshEntitlements() async {
        let backend = FakeBackend()
        let store = ProStore(backend: backend, defaults: defaults)
        await store.start()
        XCTAssertFalse(store.isPro)
        backend.owned = [ProStore.yearlyID]          // e.g. Ask to Buy approved
        backend.onChange?()
        for _ in 0..<100 where !store.isPro { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(store.isPro)
        backend.owned = []                           // refunded / expired
        backend.onChange?()
        for _ in 0..<100 where store.isPro { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(store.isPro)
    }

    func testCachedEntitlementUntilStoreKitAnswers() async {
        let backend = FakeBackend()
        backend.owned = [ProStore.lifetimeID]
        let first = ProStore(backend: backend, defaults: defaults)
        await first.refreshEntitlements()
        // Next launch: Pro straight away from the cache, then StoreKit's answer wins.
        let next = ProStore(backend: FakeBackend(), defaults: defaults)
        XCTAssertTrue(next.isPro)
        await next.refreshEntitlements()
        XCTAssertFalse(next.isPro)
    }

    func testForcedUnlockAndLoadFailure() async {
        let backend = FakeBackend()
        backend.failLoading = true
        let store = ProStore(backend: backend, defaults: defaults, forcedUnlocked: true)
        await store.start()
        XCTAssertTrue(store.isPro)
        XCTAssertTrue(store.products.isEmpty)
        XCTAssertNotNil(store.productsError)
    }

    func testDemoBackendPrices() async throws {
        let products = try await DemoProBackend().loadProducts(ids: ProStore.productIDs)
        XCTAssertEqual(Set(products.map(\.displayPrice)), ["A$2.99", "A$19.99", "A$39.99"])
        XCTAssertEqual(products.first { $0.kind == .lifetime }?.kind.priceSuffix, "One-time purchase")
    }

    // MARK: Gates

    func testDashcamGate() {
        XCTAssertTrue(ProGate.dashcamAvailable(edition: .personal, isPro: false), "free in personal builds")
        XCTAssertTrue(ProGate.dashcamAvailable(edition: .personal, isPro: true))
        XCTAssertFalse(ProGate.dashcamAvailable(edition: .commercial, isPro: false), "Pro in the App Store edition")
        XCTAssertTrue(ProGate.dashcamAvailable(edition: .commercial, isPro: true))
        XCTAssertFalse(ProGate.proFeatureAvailable(isPro: false))
        XCTAssertTrue(ProGate.proFeatureAvailable(isPro: true))
    }

    func testLockedDashcamNeverRecords() async {
        let settings = DashcamSettings(defaults: defaults)
        settings.autoStart = true
        let base = folder.appending(path: "Dashcam")
        let model = DashcamModel(settings: settings, recorder: DemoDashcamRecorder(), storage: DashcamStorage(base: base),
                                 freeSpace: { 50_000_000_000 }, thermalState: { .nominal }, observesLifecycle: false)
        model.accessAllowed = false
        await model.startIfAutoStart()
        XCTAssertEqual(model.state, .idle)
        await model.start()
        XCTAssertEqual(model.state, .idle)
        model.toggle()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.state, .idle)
        // Unlocked: records; locking again stops it.
        model.accessAllowed = true
        await model.startIfAutoStart()
        XCTAssertEqual(model.state, .recording)
        model.accessAllowed = false
        XCTAssertEqual(model.state, .idle)
    }

    // MARK: Themes

    func testThemeDefaultsPersistAndNeedPro() {
        let theme = ThemeSettings(defaults: defaults)
        XCTAssertEqual(theme.accent, .blue)
        XCTAssertEqual(theme.wallpaper, .aurora)
        theme.accent = .purple
        theme.wallpaper = .forest
        XCTAssertEqual(theme.effectiveAccent, .blue, "without Pro the default shows")
        XCTAssertEqual(theme.effectiveWallpaper, .aurora)
        theme.isProActive = true
        XCTAssertEqual(theme.effectiveAccent, .purple)
        XCTAssertEqual(theme.effectiveWallpaper, .forest)

        let reloaded = ThemeSettings(defaults: defaults)
        XCTAssertEqual(reloaded.accent, .purple)
        XCTAssertEqual(reloaded.wallpaper, .forest)
        reloaded.reset()
        XCTAssertEqual(ThemeSettings(defaults: defaults).accent, .blue)
    }

    func testThemeIgnoresUnknownSavedValues() {
        defaults.set("plaid", forKey: ThemeSettings.Keys.accent)
        defaults.set("lava", forKey: ThemeSettings.Keys.wallpaper)
        let theme = ThemeSettings(defaults: defaults)
        XCTAssertEqual(theme.accent, .blue)
        XCTAssertEqual(theme.wallpaper, .aurora)
        XCTAssertGreaterThanOrEqual(AccentChoice.allCases.count, 6)
        XCTAssertNil(WallpaperChoice.black.meshColors)
        XCTAssertEqual(WallpaperChoice.allCases.filter { $0.meshColors != nil }.count, 6, "original + 5 variants")
    }

    // MARK: Home layout

    func testHomeOrderPersists() {
        let layout = HomeLayoutSettings(defaults: defaults)
        XCTAssertEqual(layout.order, HomeLayoutSettings.defaultOrder)
        XCTAssertFalse(layout.isCustomised)
        layout.move(fromOffsets: IndexSet(integer: 0), toOffset: 4)   // map to the end
        layout.extra = .weather
        XCTAssertEqual(layout.order, [.nowPlaying, .nextTurn, .extra, .map])
        let reloaded = HomeLayoutSettings(defaults: defaults)
        XCTAssertEqual(reloaded.order, [.nowPlaying, .nextTurn, .extra, .map])
        XCTAssertEqual(reloaded.extra, .weather)
        XCTAssertTrue(reloaded.isCustomised)
    }

    func testHomeOrderRepair() {
        XCTAssertEqual(HomeLayoutSettings.repair([]), HomeLayoutSettings.defaultOrder)
        XCTAssertEqual(HomeLayoutSettings.repair(["extra", "bogus", "map", "extra"]), [.extra, .map, .nowPlaying, .nextTurn],
                       "unknown and repeated cards dropped, missing ones appended")
        defaults.set(["radio", "nowPlaying"], forKey: HomeLayoutSettings.Keys.order)
        defaults.set("tarot", forKey: HomeLayoutSettings.Keys.extra)
        let layout = HomeLayoutSettings(defaults: defaults)
        XCTAssertEqual(layout.order, [.nowPlaying, .map, .nextTurn, .extra])
        XCTAssertEqual(layout.extra, .automatic)
        // Assigning a broken order repairs it too.
        layout.order = [.map, .map]
        XCTAssertEqual(layout.order, HomeLayoutSettings.defaultOrder)
    }

    func testHomeLayoutNeedsProAndKeepsTheMapFirstWhenNarrow() {
        let layout = HomeLayoutSettings(defaults: defaults)
        layout.order = [.nextTurn, .extra, .nowPlaying, .map]
        layout.extra = .contacts
        // Without Pro: the original dashboard.
        XCTAssertTrue(layout.mapOnLeft)
        XCTAssertEqual(layout.wideColumn, [.nowPlaying, .nextTurn, .extra])
        XCTAssertEqual(layout.narrowCards, [.nextTurn, .nowPlaying])
        XCTAssertEqual(layout.effectiveExtra, .automatic)
        layout.isProActive = true
        XCTAssertFalse(layout.mapOnLeft, "map in the second half → right column")
        XCTAssertEqual(layout.wideColumn, [.nextTurn, .extra, .nowPlaying])
        XCTAssertEqual(layout.narrowCards, [.nextTurn, .nowPlaying])
        XCTAssertEqual(layout.effectiveExtra, .contacts)
        layout.order = [.nowPlaying, .map, .nextTurn, .extra]
        XCTAssertTrue(layout.mapOnLeft)
        XCTAssertEqual(layout.narrowCards, [.nowPlaying, .nextTurn])
    }

    func testColumnWidthsSwapOnTheFold() {
        let fold = CGRect(x: 470, y: 0, width: 12, height: 600)
        let left = HomeView.columnWidths(width: 950, fold: fold, mapOnLeft: true)
        XCTAssertEqual(left.map, 470)
        XCTAssertEqual(left.cards, 468)
        let right = HomeView.columnWidths(width: 950, fold: fold, mapOnLeft: false)
        XCTAssertEqual(right.map, 468)
        XCTAssertEqual(right.cards, 470)
        // No fold: the map keeps the big share either way.
        let plain = HomeView.columnWidths(width: 900, fold: nil, mapOnLeft: false)
        XCTAssertGreaterThan(plain.map, plain.cards)
    }

    func testAppIconChoices() {
        XCTAssertNil(AppIconChoice.standard.iconName)
        XCTAssertEqual(AppIconChoice(iconName: "AppIconOcean"), .ocean)
        XCTAssertEqual(AppIconChoice(iconName: "Nope"), .standard)
        for choice in AppIconChoice.allCases {
            XCTAssertNotNil(UIImage(named: choice.previewAsset, in: Bundle(for: DashcamModel.self), with: nil), choice.previewAsset)
        }
    }

    // MARK: Dashcam Pro

    func testLongLoopsNeedPro() {
        let settings = DashcamSettings(defaults: defaults)
        settings.loopMinutes = 60
        XCTAssertEqual(settings.loopMinutes, 60, "saved as chosen")
        XCTAssertEqual(settings.effectiveLoopMinutes, 30, "longest free loop without Pro")
        settings.isProActive = true
        XCTAssertEqual(settings.effectiveLoopMinutes, 60)
        XCTAssertEqual(DashcamSettings(defaults: defaults).loopMinutes, 60)
        settings.loopMinutes = 50
        XCTAssertEqual(settings.loopMinutes, DashcamSettings.defaultLoopMinutes)
    }

    func testImpactSettingsPersist() {
        let settings = DashcamSettings(defaults: defaults)
        XCTAssertTrue(settings.impactDetection)
        XCTAssertEqual(settings.impactSensitivity, .medium)
        XCTAssertFalse(settings.impactDetectionActive, "needs Pro")
        settings.impactSensitivity = .high
        settings.impactDetection = false
        let reloaded = DashcamSettings(defaults: defaults)
        XCTAssertEqual(reloaded.impactSensitivity, .high)
        XCTAssertFalse(reloaded.impactDetection)
    }

    func testImpactDetectorThresholdAndDebounce() {
        var detector = ImpactDetector(sensitivity: .medium, debounce: 30)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        // Road noise and a pothole: no.
        XCTAssertFalse(detector.ingest(x: 0.3, y: 0.2, z: 0.4, at: t0))
        XCTAssertFalse(detector.ingest(x: 1.2, y: 1.0, z: 1.5, at: t0.addingTimeInterval(1)))   // ≈2.2 g
        // A crash: yes.
        XCTAssertTrue(detector.ingest(x: 2.0, y: 1.5, z: 0.5, at: t0.addingTimeInterval(2)))    // ≈2.55 g
        // The car rocking afterwards is the same event.
        XCTAssertFalse(detector.ingest(x: 3, y: 0, z: 0, at: t0.addingTimeInterval(10)))
        XCTAssertFalse(detector.ingest(x: 3, y: 0, z: 0, at: t0.addingTimeInterval(31.9)))
        // A second impact well after it counts again.
        XCTAssertTrue(detector.ingest(x: 3, y: 0, z: 0, at: t0.addingTimeInterval(33)))
        XCTAssertFalse(detector.ingest(x: .nan, y: 0, z: 0, at: t0.addingTimeInterval(100)))
    }

    func testImpactSensitivityLevels() {
        let jolt = (x: 2.0, y: 0.0, z: 0.0)   // 2 g
        var high = ImpactDetector(sensitivity: .high)
        var medium = ImpactDetector(sensitivity: .medium)
        var low = ImpactDetector(sensitivity: .low)
        XCTAssertTrue(high.ingest(x: jolt.x, y: jolt.y, z: jolt.z, at: .now))
        XCTAssertFalse(medium.ingest(x: jolt.x, y: jolt.y, z: jolt.z, at: .now))
        XCTAssertFalse(low.ingest(x: jolt.x, y: jolt.y, z: jolt.z, at: .now))
        XCTAssertTrue(low.ingest(x: 3.6, y: 0, z: 0, at: .now))
        XCTAssertLessThan(ImpactSensitivity.high.thresholdG, ImpactSensitivity.medium.thresholdG)
        XCTAssertEqual(ImpactSensitivity.medium.thresholdG, 2.5)
    }

    func testImpactSavesAClipThroughSaveClip() async {
        let settings = DashcamSettings(defaults: defaults)
        let base = folder.appending(path: "Dashcam")
        let model = DashcamModel(settings: settings, recorder: DemoDashcamRecorder(), storage: DashcamStorage(base: base),
                                 freeSpace: { 50_000_000_000 }, thermalState: { .nominal }, observesLifecycle: false)
        await model.start()
        model.rotateSegment()
        try? await Task.sleep(for: .milliseconds(50))
        // Without Pro nothing happens.
        let none = await model.handleImpact()
        XCTAssertNil(none)
        XCTAssertNil(model.impactBanner)
        settings.isProActive = true
        let clip = await model.handleImpact()
        XCTAssertNotNil(clip)
        XCTAssertEqual(model.impactBanner, DashcamModel.impactSavedText)
        XCTAssertEqual(model.savedClips.count, 1)
        model.stop()
    }

    // MARK: Trips

    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// A fix `seconds` after `start`, `metres` east of a fixed point, at `kmh`.
    private func fix(_ seconds: TimeInterval, metres: Double, kmh: Double?, accuracy: Double = 8) -> TripFix {
        TripFix(time: start.addingTimeInterval(seconds), latitude: -33.87,
                longitude: 151.0 + metres / (111_320 * cos(33.87 * .pi / 180)),
                speed: kmh.map { $0 / 3.6 }, accuracy: accuracy)
    }

    /// Drives east at `kmh` from `from` seconds for `duration`, one fix a second.
    private func drive(_ detector: inout TripDetector, from: TimeInterval, duration: TimeInterval,
                       kmh: Double, startMetres: Double) -> (trips: [Trip], metres: Double) {
        var trips: [Trip] = []
        var metres = startMetres
        for t in stride(from: from, to: from + duration, by: 1) {
            if let trip = detector.ingest(fix(t, metres: metres, kmh: kmh)) { trips.append(trip) }
            metres += kmh / 3.6
        }
        return (trips, metres)
    }

    func testTripStartsAfter30sAbove15kmh() {
        var detector = TripDetector()
        // Crawling at 10 km/h for a minute: no trip.
        var (trips, metres) = drive(&detector, from: 0, duration: 60, kmh: 10, startMetres: 0)
        XCTAssertTrue(trips.isEmpty)
        XCTAssertEqual(detector.phase, .idle)
        // 20 s at 40 km/h then slowing: still nothing.
        (trips, metres) = drive(&detector, from: 60, duration: 20, kmh: 40, startMetres: metres)
        XCTAssertFalse(detector.isDriving)
        (trips, metres) = drive(&detector, from: 80, duration: 5, kmh: 5, startMetres: metres)
        XCTAssertEqual(detector.phase, .idle)
        // 31 s at 40 km/h: driving.
        (trips, metres) = drive(&detector, from: 85, duration: 31, kmh: 40, startMetres: metres)
        XCTAssertTrue(detector.isDriving)
    }

    func testTripEndsAfterFiveMinutesStoppedWithStats() {
        var detector = TripDetector()
        var (_, metres) = drive(&detector, from: 0, duration: 300, kmh: 50, startMetres: 0)   // 5 min at 50
        (_, metres) = drive(&detector, from: 300, duration: 60, kmh: 80, startMetres: metres)  // 1 min at 80
        XCTAssertTrue(detector.isDriving)
        // Parked: fixes at 0 km/h for 4 min, no end yet.
        var ended: Trip?
        for t in stride(from: 360.0, to: 600, by: 10) {
            ended = detector.ingest(fix(t, metres: metres, kmh: 0)) ?? ended
        }
        XCTAssertNil(ended)
        // A parked phone goes quiet; the tick ends it 5 min after the car stopped.
        XCTAssertNil(detector.tick(now: start.addingTimeInterval(600)))
        let trip = detector.tick(now: start.addingTimeInterval(660))
        XCTAssertNotNil(trip)
        guard let trip else { return }
        XCTAssertEqual(trip.startedAt, start)
        XCTAssertEqual(trip.endedAt.timeIntervalSince(start), 359, accuracy: 1, "ends when the car stopped, not when it was noticed")
        let expected = 50 / 3.6 * 299 + 80 / 3.6 * 60
        XCTAssertEqual(trip.distanceMeters, expected, accuracy: expected * 0.02)
        XCTAssertEqual(trip.maxSpeed * 3.6, 80, accuracy: 0.5)
        XCTAssertEqual(trip.averageSpeed, trip.distanceMeters / trip.duration, accuracy: 0.01)
        XCTAssertLessThanOrEqual(trip.route.count, TripDetector.maxRoutePoints)
        XCTAssertEqual(trip.route.first?.longitude ?? 0, fix(0, metres: 0, kmh: nil).longitude, accuracy: 1e-9)
        XCTAssertEqual(detector.phase, .idle)
    }

    func testTripEndsAfterLongBackgroundOrGap() {
        var detector = TripDetector()
        var (_, metres) = drive(&detector, from: 0, duration: 120, kmh: 60, startMetres: 0)
        detector.enteredBackground(at: start.addingTimeInterval(120))
        XCTAssertNil(detector.becameActive(at: start.addingTimeInterval(300)), "5 min away: still the same drive")
        XCTAssertTrue(detector.isDriving)
        (_, metres) = drive(&detector, from: 300, duration: 60, kmh: 60, startMetres: metres)
        detector.enteredBackground(at: start.addingTimeInterval(360))
        let trip = detector.becameActive(at: start.addingTimeInterval(360 + 11 * 60))
        XCTAssertNotNil(trip, "more than 10 min in the background ends it")
        XCTAssertFalse(detector.isDriving)

        // Fixes that stop for over 10 minutes end it too, and the new fix starts afresh.
        var other = TripDetector()
        (_, metres) = drive(&other, from: 0, duration: 120, kmh: 60, startMetres: 0)
        let gapTrip = other.ingest(fix(120 + 15 * 60, metres: metres + 5000, kmh: 60))
        XCTAssertNotNil(gapTrip)
        XCTAssertEqual(gapTrip?.endedAt.timeIntervalSince(start) ?? 0, 119, accuracy: 1)
        XCTAssertEqual(other.phase, .starting(since: start.addingTimeInterval(120 + 15 * 60)))
    }

    func testTripIgnoresBadFixesAndTinyDrives() {
        var detector = TripDetector()
        // Inaccurate fixes are ignored.
        for t in stride(from: 0.0, to: 60, by: 1) {
            _ = detector.ingest(fix(t, metres: t * 20, kmh: 72, accuracy: 500))
        }
        XCTAssertEqual(detector.phase, .idle)
        // Speed worked out from positions when the GPS gives none.
        _ = drive(&detector, from: 100, duration: 1, kmh: 0, startMetres: 0)
        var metres = 0.0
        for t in stride(from: 101.0, to: 140, by: 1) {
            metres += 15
            _ = detector.ingest(fix(t, metres: metres, kmh: nil))   // 54 km/h
        }
        XCTAssertTrue(detector.isDriving)
        // Under 300 m in total is a car-park shuffle, not a trip... this one is 570 m, so it's kept.
        XCTAssertNotNil(detector.tick(now: start.addingTimeInterval(1000)))

        var short = TripDetector()
        for t in stride(from: 0.0, to: 32, by: 1) { _ = short.ingest(fix(t, metres: t * 4.5, kmh: 16.2)) }
        XCTAssertTrue(short.isDriving)
        XCTAssertNil(short.tick(now: start.addingTimeInterval(1000)), "144 m isn't a trip")
    }

    func testDownsampleKeepsEnds() {
        let points = Array(0..<1000)
        let sampled = TripDetector.downsample(points)
        XCTAssertEqual(sampled.count, 300)
        XCTAssertEqual(sampled.first, 0)
        XCTAssertEqual(sampled.last, 999)
        XCTAssertEqual(TripDetector.downsample(Array(0..<10)), Array(0..<10))
    }

    func testTripStorePersistsCapsAndNeedsPro() async {
        let store = TripStore(directory: folder, defaults: defaults)
        store.placeName = { _ in "Testville" }
        XCTAssertTrue(store.isRecordingEnabled)
        XCTAssertFalse(store.isRecordingActive, "needs Pro")
        // Without Pro, fixes are ignored.
        store.ingest(CLLocation(coordinate: CLLocationCoordinate2D(latitude: -33.87, longitude: 151), altitude: 0,
                                horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 20, timestamp: start))
        XCTAssertFalse(store.isDriving)

        func trip(_ i: Int) -> Trip {
            Trip(id: UUID(), startedAt: start.addingTimeInterval(Double(i) * 3600), endedAt: start.addingTimeInterval(Double(i) * 3600 + 600),
                 distanceMeters: 5000, maxSpeed: 20, averageSpeed: 8.3,
                 route: [TripPoint(latitude: -33.87, longitude: 151), TripPoint(latitude: -33.86, longitude: 151.01)])
        }
        for i in 0..<(TripStore.maxTrips + 5) { store.save(trip(i)) }
        XCTAssertEqual(store.trips.count, TripStore.maxTrips)
        XCTAssertEqual(store.trips.first?.startedAt, trip(TripStore.maxTrips + 4).startedAt, "newest first")
        XCTAssertEqual(store.trips.last?.startedAt, trip(5).startedAt, "oldest five removed")
        let files = try? FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(files?.count, TripStore.maxTrips)

        let reloaded = TripStore(directory: folder, defaults: defaults)
        XCTAssertEqual(reloaded.trips.count, TripStore.maxTrips)
        XCTAssertEqual(reloaded.trips.first?.distanceMeters, 5000)

        // Recording names the ends once the geocoder answers.
        store.record(trip(1000))
        for _ in 0..<100 where store.trips.first?.startName == nil { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.trips.first?.startName, "Testville")
        XCTAssertEqual(store.trips.first?.title, "Testville")

        store.delete(store.trips[0])
        XCTAssertEqual(store.trips.count, TripStore.maxTrips - 1)
        store.deleteAll()
        XCTAssertTrue(TripStore(directory: folder, defaults: defaults).trips.isEmpty)
    }

    func testTripStoreRecordsADriveWithPro() {
        let store = TripStore(directory: folder, defaults: defaults)
        store.placeName = { _ in nil }
        store.isProActive = true
        var metres = 0.0
        for t in stride(from: 0.0, to: 120, by: 1) {
            let f = fix(t, metres: metres, kmh: 60)
            store.ingest(CLLocation(coordinate: CLLocationCoordinate2D(latitude: f.latitude, longitude: f.longitude),
                                    altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90,
                                    speed: 60 / 3.6, timestamp: f.time))
            metres += 60 / 3.6
        }
        XCTAssertTrue(store.isDriving)
        store.now = { self.start.addingTimeInterval(120 + 301) }
        store.tick()
        XCTAssertFalse(store.isDriving)
        XCTAssertEqual(store.trips.count, 1)
        XCTAssertEqual(store.trips[0].distanceMeters, 60 / 3.6 * 119, accuracy: 30)
        // Turning recording off (or losing Pro) drops a drive in progress.
        store.isRecordingEnabled = false
        XCTAssertFalse(TripStore(directory: folder, defaults: defaults).isRecordingEnabled)
    }
}
