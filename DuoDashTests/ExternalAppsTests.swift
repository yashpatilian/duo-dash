import XCTest
import MapKit
import UIKit
@testable import DuoDash

/// Google Maps / Waze hand-off links, the hand-off itself, and the "Navigate with" setting.
@MainActor
final class NavigationHandoffTests: XCTestCase {
    private let sydney = NavigationTarget(name: "Opera House", latitude: -33.856784, longitude: 151.215297)
    private let stopA = NavigationTarget(name: "Stop A", latitude: -33.8, longitude: 151.1)
    private let stopB = NavigationTarget(name: "Stop B", latitude: -33.9, longitude: 151.2)

    private func freshDefaults() -> UserDefaults {
        let name = "handoff.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testGoogleMapsAppLinkWithoutStops() {
        XCTAssertEqual(NavigationLinks.googleMapsApp(to: sydney)?.absoluteString,
                       "comgooglemaps://?daddr=-33.856784,151.215297&directionsmode=driving")
    }

    func testGoogleMapsAppLinkWithWaypoints() {
        XCTAssertEqual(NavigationLinks.googleMapsApp(to: sydney, via: [stopA, stopB])?.absoluteString,
                       "comgooglemaps://?saddr=&daddr=-33.800000,151.100000+to:-33.900000,151.200000+to:-33.856784,151.215297&directionsmode=driving")
    }

    func testGoogleMapsWebFallback() {
        XCTAssertEqual(NavigationLinks.googleMapsWeb(to: sydney)?.absoluteString,
                       "https://www.google.com/maps/dir/?api=1&destination=-33.856784,151.215297&travelmode=driving")
        XCTAssertEqual(NavigationLinks.googleMapsWeb(to: sydney, via: [stopA, stopB])?.absoluteString,
                       "https://www.google.com/maps/dir/?api=1&destination=-33.856784,151.215297&travelmode=driving&waypoints=-33.800000,151.100000%7C-33.900000,151.200000")
    }

    func testWazeAppAndWebLinks() {
        XCTAssertEqual(NavigationLinks.wazeApp(to: sydney)?.absoluteString, "waze://?ll=-33.856784,151.215297&navigate=yes")
        XCTAssertEqual(NavigationLinks.wazeWeb(to: sydney)?.absoluteString, "https://waze.com/ul?ll=-33.856784,151.215297&navigate=yes")
    }

    func testNamesAreEncodedWhenThereIsNoCoordinate() {
        let place = NavigationTarget(name: "Café & Bar #1, 10 King St + Co", latitude: nil, longitude: nil)
        let encoded = "Caf%C3%A9%20%26%20Bar%20%231,%2010%20King%20St%20%2B%20Co"
        XCTAssertEqual(NavigationLinks.googleMapsApp(to: place)?.absoluteString,
                       "comgooglemaps://?daddr=\(encoded)&directionsmode=driving")
        XCTAssertEqual(NavigationLinks.wazeApp(to: place)?.absoluteString, "waze://?q=\(encoded)&navigate=yes")
        XCTAssertEqual(NavigationLinks.wazeWeb(to: place)?.absoluteString, "https://waze.com/ul?q=\(encoded)&navigate=yes")
        XCTAssertEqual(NavigationLinks.googleMapsWeb(to: place)?.absoluteString,
                       "https://www.google.com/maps/dir/?api=1&destination=\(encoded)&travelmode=driving")
        // A name with "+to:" in it can't split the waypoint list.
        let tricky = NavigationTarget(name: "A+to:B", latitude: nil, longitude: nil)
        XCTAssertEqual(NavigationLinks.googleMapsApp(to: tricky)?.absoluteString,
                       "comgooglemaps://?daddr=A%2Bto%3AB&directionsmode=driving")
    }

    func testCoordinatesUseADotWhateverTheLocale() {
        XCTAssertEqual(NavigationLinks.coordinate(48.5, 2.25), "48.500000,2.250000")
        let target = NavigationTarget(name: nil, latitude: 52.52, longitude: 13.405)
        XCTAssertEqual(target.query, "52.520000,13.405000")
    }

    func testNoTargetMeansNoLink() {
        let nothing = NavigationTarget(name: "  ", latitude: nil, longitude: nil)
        XCTAssertNil(NavigationLinks.googleMapsApp(to: nothing))
        XCTAssertNil(NavigationLinks.wazeApp(to: nothing))
        XCTAssertNil(NavigationLinks.links(for: .appleMaps, to: sydney), "Apple Maps is guided in Duo Dash")
    }

    func testTargetFromMapItemPrefersTheCoordinate() {
        let item = MKMapItem(location: CLLocation(latitude: -33.85, longitude: 151.2), address: nil)
        item.name = "Somewhere"
        let target = NavigationTarget(item: item)
        XCTAssertEqual(target.query, "-33.850000,151.200000")
        XCTAssertEqual(target.name, "Somewhere")
    }

    func testWazeDropsStopsAndSaysSo() {
        XCTAssertNil(NavigationLinks.stopsNotice(for: .googleMaps, stopCount: 2))
        XCTAssertNil(NavigationLinks.stopsNotice(for: .waze, stopCount: 0))
        XCTAssertEqual(NavigationLinks.stopsNotice(for: .waze, stopCount: 1),
                       "Waze takes only the destination, so your stop isn't passed on. Add it in Waze.")
        XCTAssertEqual(NavigationLinks.stopsNotice(for: .waze, stopCount: 2),
                       "Waze takes only the destination, so your 2 stops aren't passed on. Add them in Waze.")
    }

    func testPreferenceDefaultsToAppleMapsAndPersists() {
        let defaults = freshDefaults()
        let handoff = NavigationHandoff(defaults: defaults, canOpen: { _ in true }, opener: { _, done in done(true) })
        XCTAssertEqual(handoff.preferred, .appleMaps)
        XCTAssertFalse(handoff.usesExternalApp)
        handoff.preferred = .waze
        XCTAssertEqual(NavigationHandoff(defaults: defaults, canOpen: { _ in true }, opener: { _, _ in }).preferred, .waze)
    }

    func testInstalledDetection() {
        let handoff = NavigationHandoff(defaults: freshDefaults(), canOpen: { $0.scheme == "waze" }, opener: { _, _ in })
        XCTAssertTrue(handoff.isInstalled(.appleMaps))
        XCTAssertTrue(handoff.isInstalled(.waze))
        XCTAssertFalse(handoff.isInstalled(.googleMaps))
    }

    func testHandOffOpensTheAppWhenInstalled() {
        var opened: [URL] = []
        let handoff = NavigationHandoff(defaults: freshDefaults(), canOpen: { _ in true },
                                        opener: { url, done in opened.append(url); done(true) })
        handoff.preferred = .googleMaps
        handoff.handOff(to: sydney, via: [stopA])
        XCTAssertEqual(opened.map(\.scheme), ["comgooglemaps"])
        XCTAssertNil(handoff.notice)
    }

    func testHandOffFallsBackToTheWebWhenNotInstalled() {
        var opened: [URL] = []
        let handoff = NavigationHandoff(defaults: freshDefaults(), canOpen: { _ in false },
                                        opener: { url, done in opened.append(url); done(true) })
        handoff.preferred = .waze
        handoff.handOff(to: sydney, via: [stopA, stopB])
        XCTAssertEqual(opened.map(\.absoluteString), ["https://waze.com/ul?ll=-33.856784,151.215297&navigate=yes"])
        XCTAssertNotNil(handoff.notice, "Waze can't take the stops")
    }

    func testHandOffFallsBackToTheWebWhenTheAppRefuses() {
        var opened: [URL] = []
        let handoff = NavigationHandoff(defaults: freshDefaults(), canOpen: { _ in true },
                                        opener: { url, done in opened.append(url); done(url.scheme == "https") })
        handoff.preferred = .waze
        handoff.handOff(to: sydney)
        XCTAssertEqual(opened.map(\.scheme), ["waze", "https"])
        XCTAssertEqual(handoff.lastOpened?.scheme, "https")
    }

    func testGoHandsOffAndKeepsThePreview() async {
        let defaults = freshDefaults()
        var opened: [URL] = []
        let handoff = NavigationHandoff(defaults: defaults, canOpen: { _ in true },
                                        opener: { url, done in opened.append(url); done(true) })
        handoff.preferred = .googleMaps
        let location = LocationManager(live: false)
        // A route that takes its time: the preview is still calculating while the hand-off happens.
        let model = NavigationModel(location: location, defaults: defaults, routeProvider: { _, _ in
            try await Task.sleep(for: .seconds(30))
            throw CancellationError()
        }, handoff: handoff)
        let item = MKMapItem(location: CLLocation(latitude: -33.856784, longitude: 151.215297), address: nil)
        item.name = "Opera House"
        model.go(to: item)
        XCTAssertEqual(opened.map(\.absoluteString), ["comgooglemaps://?daddr=-33.856784,151.215297&directionsmode=driving"])
        XCTAssertNotEqual(model.state, .navigating, "Duo Dash doesn't guide when another app does")
        // The preview's button hands off again; "Guide in Duo Dash instead" stays in Duo Dash.
        model.start()
        XCTAssertEqual(opened.count, 2)
        model.end()
    }
}

/// The catalogue of other apps, and dock persistence with them in it.
@MainActor
final class ExternalAppsTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let name = "external.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testCatalogIDsAndSchemesAreUnique() {
        let all = ExternalAppCatalog.all
        XCTAssertEqual(Set(all.map(\.id)).count, all.count)
        XCTAssertEqual(Set(all.map(\.scheme)).count, all.count)
        for app in all {
            XCTAssertNotNil(UIImage(systemName: app.symbol), "SF Symbol \(app.symbol) for \(app.name)")
            XCTAssertNotNil(DockEntry(storageID: "ext.\(app.id)"))
        }
    }

    func testEverySchemeIsDeclaredForCanOpenURL() throws {
        let declared = Bundle.main.object(forInfoDictionaryKey: "LSApplicationQueriesSchemes") as? [String] ?? []
        XCTAssertLessThanOrEqual(declared.count, 50, "iOS answers canOpenURL for at most 50 schemes")
        for app in ExternalAppCatalog.all {
            XCTAssertTrue(declared.contains(app.scheme), "\(app.scheme) missing from LSApplicationQueriesSchemes")
        }
        XCTAssertTrue(declared.contains("comgooglemaps"))
        XCTAssertTrue(declared.contains("waze"))
    }

    func testInstalledFiltersWithCanOpen() {
        let installed = ExternalAppCatalog.installed { ["waze", "tg", "audible"].contains($0.scheme ?? "") }
        XCTAssertEqual(installed.map(\.id), ["waze", "audible", "telegram"], "catalogue order")
        XCTAssertTrue(ExternalAppCatalog.installed { _ in false }.isEmpty)
    }

    func testOldSavedOrdersStillLoad() {
        let saved = ["messages", "maps", "phone", "music", "spotify", "calendar", "weather", "car", "homekit", "dashcam", "settings"]
        let entries = AppModel.resolvedEntries(saved: saved)
        XCTAssertEqual(Array(entries.prefix(saved.count)).map(\.id), saved)
        XCTAssertEqual(entries.last, .app(.youtube), "new screens are appended")
        XCTAssertEqual(entries.compactMap(\.dockItem).count, DockItem.apps.count)
    }

    func testUnknownAndRemovedAppsAreDropped() {
        let saved = ["ext.waze", "maps", "ext.notAnApp", "ext.", "bogus", "home", "ext.waze", "maps"]
        let entries = AppModel.resolvedEntries(saved: saved)
        XCTAssertEqual(Array(entries.prefix(2)).map(\.id), ["ext.waze", "maps"])
        XCTAssertEqual(entries.filter { $0.externalApp != nil }.count, 1)
        XCTAssertEqual(Set(entries.compactMap(\.dockItem)), Set(DockItem.apps))
        XCTAssertFalse(entries.contains(.app(.home)))
        // The old reader ignores app entries, so an older build reading this order still works.
        XCTAssertEqual(Set(AppModel.resolvedOrder(saved: entries.map(\.id))), Set(DockItem.apps))
    }

    func testAddingReorderingAndRemovingAnAppPersists() {
        let defaults = freshDefaults()
        var opened: [URL] = []
        let canOpen: (URL) -> Bool = { ["waze", "whatsapp"].contains($0.scheme ?? "") }
        let model = AppModel(defaults: defaults, canOpenURL: canOpen, openURL: { opened.append($0) })
        XCTAssertEqual(model.installedApps.map(\.id), ["waze", "whatsapp"])
        let waze = ExternalAppCatalog.app(id: "waze")!
        XCTAssertFalse(model.visibleDockEntries.contains(.external(waze)), "not in the dock until added")

        model.setInDock(waze, true)
        model.moveDockEntry(.external(waze), to: .app(.maps))
        XCTAssertEqual(model.visibleDockEntries.first, .external(waze))
        XCTAssertEqual(model.dockOrder.first, .maps, "built-in order is unaffected")

        let relaunched = AppModel(defaults: defaults, canOpenURL: canOpen, openURL: { _ in })
        XCTAssertEqual(relaunched.visibleDockEntries.first, .external(waze), "survives relaunch")

        model.open(.external(waze))
        XCTAssertEqual(opened, [URL(string: "waze://")!])

        model.resetDockOrder()
        XCTAssertEqual(model.dockEntries.last, .external(waze), "reset keeps added apps, after the screens")
        model.setInDock(waze, false)
        XCTAssertFalse(AppModel(defaults: defaults, canOpenURL: canOpen, openURL: { _ in }).isInDock(waze))
    }

    func testUninstalledAppsHideButKeepTheirPlace() {
        let defaults = freshDefaults()
        var installed: Set<String> = ["waze"]
        let model = AppModel(defaults: defaults, canOpenURL: { installed.contains($0.scheme ?? "") }, openURL: { _ in })
        let waze = ExternalAppCatalog.app(id: "waze")!
        model.setInDock(waze, true)
        XCTAssertTrue(model.visibleDockEntries.contains(.external(waze)))
        installed = []
        model.refreshInstalledApps()
        XCTAssertFalse(model.visibleDockEntries.contains(.external(waze)), "deleted apps leave the dock")
        XCTAssertTrue(model.isInDock(waze), "and come back if reinstalled")
    }

    func testYouTubeIsABuiltInScreen() {
        XCTAssertTrue(DockItem.apps.contains(.youtube))
        XCTAssertEqual(DockItem.youtube.title, "YouTube")
        XCTAssertEqual(DockItem.youtube.symbol, "play.rectangle.fill")
        XCTAssertNil(DockItem.youtube.officialIconAsset, "no YouTube logo is bundled")
        XCTAssertEqual(DockItem(rawValue: "youtube"), .youtube, "duodash://open/youtube")
    }
}

/// The YouTube screen's URLs and what its web views may load.
final class YouTubeLinksTests: XCTestCase {
    func testSearchURL() {
        XCTAssertEqual(YouTubeLinks.search("  lo-fi beats & chill + rain ")?.absoluteString,
                       "https://m.youtube.com/results?search_query=lo-fi%20beats%20%26%20chill%20%2B%20rain")
        XCTAssertNil(YouTubeLinks.search("   "))
    }

    func testVideoIDs() {
        let id = "dQw4w9WgXcQ"
        for link in ["https://www.youtube.com/watch?v=\(id)", "https://m.youtube.com/watch?v=\(id)&t=42",
                     "https://youtu.be/\(id)", "https://www.youtube.com/shorts/\(id)",
                     "https://www.youtube-nocookie.com/embed/\(id)", "https://m.youtube.com/live/\(id)"] {
            XCTAssertEqual(YouTubeLinks.videoID(from: URL(string: link)!), id, link)
        }
        for link in ["https://m.youtube.com/", "https://m.youtube.com/results?search_query=x",
                     "https://evil.example/watch?v=\(id)", "https://m.youtube.com/watch?v=short",
                     "https://m.youtube.com/watch?v=abc'%3Bdef12"] {
            XCTAssertNil(YouTubeLinks.videoID(from: URL(string: link)!), link)
        }
    }

    func testPlayerPageUsesTheOfficialNoCookiePlayerInline() throws {
        let page = try XCTUnwrap(YouTubeLinks.playerPage(videoID: "dQw4w9WgXcQ", origin: "https://com.example.duodash"))
        XCTAssertTrue(page.contains("https://www.youtube.com/iframe_api"))
        XCTAssertTrue(page.contains("host:'https://www.youtube-nocookie.com'"))
        XCTAssertTrue(page.contains("playsinline:1"))
        XCTAssertTrue(page.contains("origin:'https://com.example.duodash'"))
        XCTAssertNil(YouTubeLinks.playerPage(videoID: "x');alert(1)//", origin: "https://a"))
    }

    func testAppLinks() {
        XCTAssertEqual(YouTubeLinks.app(videoID: "dQw4w9WgXcQ").absoluteString, "youtube://www.youtube.com/watch?v=dQw4w9WgXcQ")
        XCTAssertEqual(YouTubeLinks.app(videoID: nil).absoluteString, "youtube://")
    }

    func testNavigationAllowList() {
        typealias P = YouTubeNavigationPolicy
        func main(_ s: String) -> P.Decision { P.decision(for: URL(string: s)!, isMainFrame: true, playerHost: "com.example.duodash") }
        XCTAssertEqual(main("https://m.youtube.com/results?search_query=x"), .allow)
        XCTAssertEqual(main("https://www.youtube.com/watch?v=dQw4w9WgXcQ"), .allow)
        XCTAssertEqual(main("https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ"), .allow)
        XCTAssertEqual(main("https://youtu.be/dQw4w9WgXcQ"), .allow)
        XCTAssertEqual(main("https://accounts.google.com/ServiceLogin?service=youtube"), .allow)
        XCTAssertEqual(main("https://consent.youtube.com/m?continue=x"), .allow)
        XCTAssertEqual(main("https://com.example.duodash/"), .allow, "the player page's own origin")
        XCTAssertEqual(main("about:blank"), .allow)

        XCTAssertEqual(main("https://example.com/"), .openExternally)
        XCTAssertEqual(main("https://notyoutube.com/"), .openExternally)
        XCTAssertEqual(main("https://youtube.com.evil.example/"), .openExternally)
        XCTAssertEqual(main("https://www.google.com/search?q=x"), .openExternally)
        XCTAssertEqual(main("https://mail.google.com/"), .openExternally)
        XCTAssertEqual(main("youtube://www.youtube.com/watch?v=dQw4w9WgXcQ"), .openExternally)
        XCTAssertEqual(main("mailto:someone@example.com"), .openExternally)
        XCTAssertEqual(main("javascript:alert(1)"), .cancel)

        // Frames inside a YouTube page (the player, YouTube's ads) load untouched.
        XCTAssertEqual(P.decision(for: URL(string: "https://googleads.g.doubleclick.net/x")!, isMainFrame: false), .allow)
        XCTAssertEqual(P.decision(for: URL(string: "javascript:alert(1)")!, isMainFrame: false), .cancel)
    }

    @MainActor
    func testWideLayoutSplitsOnTheFold() {
        XCTAssertTrue(YouTubeScreen.isWide(CGSize(width: 839, height: 653)), "inner landscape")
        XCTAssertTrue(YouTubeScreen.isWide(CGSize(width: 580, height: 450)), "cover landscape")
        XCTAssertFalse(YouTubeScreen.isWide(CGSize(width: 653, height: 800)), "inner portrait")
        XCTAssertFalse(YouTubeScreen.isWide(CGSize(width: 450, height: 530)), "cover portrait")
        XCTAssertFalse(YouTubeScreen.isWide(CGSize(width: 459, height: 560)), "Split View half")
        let even = YouTubeScreen.halves(width: 808, fold: nil)
        XCTAssertEqual(even.video, even.browser)
        let fold = YouTubeScreen.halves(width: 808, fold: CGRect(x: 420, y: 0, width: 20, height: 600))
        XCTAssertEqual(fold.video, 420)
        XCTAssertEqual(fold.browser, 368)
        XCTAssertEqual(fold.gap, 20)
    }
}
