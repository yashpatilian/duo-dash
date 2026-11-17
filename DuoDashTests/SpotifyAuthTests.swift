import XCTest
@testable import DuoDash

/// Answers requests to Spotify's token endpoint in tests, so nothing reaches Spotify.
final class SpotifyTokenStubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLSession moves the body into a stream; keep it readable for the assertions.
        var request = request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                body.append(buffer, count: read)
            }
            stream.close()
            request.httpBody = body
        }
        Self.requests.append(request)
        let (status, data) = Self.handler?(request) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SpotifyTokenStubProtocol.self]
        return URLSession(configuration: config)
    }
}

/// Sign in once, stay signed in: PKCE, the token requests and replies, the renew-or-sign-in
/// decision, and the model's behaviour around them.
@MainActor
final class SpotifyAuthTests: XCTestCase {
    private let clientID = "test-client-id"

    override func tearDown() {
        SpotifyTokenStubProtocol.handler = nil
        SpotifyTokenStubProtocol.requests = []
    }

    private func form(_ request: URLRequest) -> [String: String] {
        let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        var values: [String: String] = [:]
        for pair in body.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            values[parts[0]] = parts[1].removingPercentEncoding
        }
        return values
    }

    private func query(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }) { a, _ in a }
    }

    // MARK: PKCE

    /// RFC 7636, Appendix B.
    func testPKCEChallengeMatchesRFC7636Vector() {
        let pkce = SpotifyPKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", state: "s")
        XCTAssertEqual(pkce.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(SpotifyPKCE.base64URL(Data([0xfb, 0xff, 0xfe])), "-__-", "base64url, no padding")
    }

    func testRandomPKCEIsWellFormedAndUnique() {
        let a = SpotifyPKCE.random(), b = SpotifyPKCE.random()
        XCTAssertNotEqual(a.verifier, b.verifier)
        XCTAssertNotEqual(a.state, b.state)
        XCTAssertTrue((43...128).contains(a.verifier.count), "RFC 7636 verifier length")
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        XCTAssertTrue(a.verifier.unicodeScalars.allSatisfy(unreserved.contains))
        XCTAssertGreaterThanOrEqual(a.state.count, 16)
        XCTAssertEqual(a.challenge, SpotifyPKCE.challenge(for: a.verifier))
    }

    func testAuthorizeURL() {
        let pkce = SpotifyPKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", state: "xyz")
        let url = SpotifyOAuth.authorizeURL(clientID: clientID, pkce: pkce)
        XCTAssertEqual(url.host, "accounts.spotify.com")
        XCTAssertEqual(url.path, "/authorize")
        let values = query(url)
        XCTAssertEqual(values["client_id"], clientID)
        XCTAssertEqual(values["response_type"], "code")
        XCTAssertEqual(values["redirect_uri"], "duodash://spotify-callback")
        XCTAssertEqual(values["code_challenge_method"], "S256")
        XCTAssertEqual(values["code_challenge"], "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(values["state"], "xyz")
        XCTAssertEqual(values["scope"], "app-remote-control")
        XCTAssertNil(values["code_verifier"], "the verifier never leaves the phone before the exchange")
    }

    // MARK: Redirect and state

    func testRedirectStateIsChecked() throws {
        let auth = SpotifyPKCEAuthorizer(clientID: clientID, session: SpotifyTokenStubProtocol.session())
        let good = URL(string: "duodash://spotify-callback?code=abc&state=expected")!

        // Nothing asked for yet: rejected.
        XCTAssertThrowsError(try auth.accept(good)) { XCTAssertEqual($0 as? SpotifyAuthError, .unexpectedRedirect) }

        let pkce = SpotifyPKCE(verifier: "v".padding(toLength: 43, withPad: "v", startingAt: 0), state: "expected")
        _ = auth.begin(pkce)
        for bad in ["duodash://spotify-callback?code=abc&state=other",
                    "duodash://spotify-callback?code=abc",
                    "duodash://spotify-callback?error=access_denied&state=other",
                    "duodash://elsewhere?code=abc&state=expected"] {
            XCTAssertThrowsError(try auth.accept(URL(string: bad)!), bad) {
                XCTAssertEqual($0 as? SpotifyAuthError, .unexpectedRedirect, bad)
            }
        }
        XCTAssertNotNil(auth.pending, "a forged redirect doesn't cancel the real sign-in")

        let accepted = try auth.accept(good)
        XCTAssertEqual(accepted.code, "abc")
        XCTAssertEqual(accepted.verifier, pkce.verifier)
        XCTAssertNil(auth.pending)
        XCTAssertThrowsError(try auth.accept(good), "a redirect is only accepted once")
    }

    func testRedirectDeniedAndStale() {
        let auth = SpotifyPKCEAuthorizer(clientID: clientID, session: SpotifyTokenStubProtocol.session())
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        auth.now = { clock }
        _ = auth.begin(SpotifyPKCE(verifier: String(repeating: "a", count: 43), state: "st"))
        XCTAssertThrowsError(try auth.accept(URL(string: "duodash://spotify-callback?error=access_denied&state=st")!)) {
            XCTAssertEqual($0 as? SpotifyAuthError, .denied("Spotify access wasn't allowed."))
        }

        _ = auth.begin(SpotifyPKCE(verifier: String(repeating: "a", count: 43), state: "st"))
        clock += 601
        XCTAssertThrowsError(try auth.accept(URL(string: "duodash://spotify-callback?code=abc&state=st")!)) {
            XCTAssertEqual($0 as? SpotifyAuthError, .unexpectedRedirect, "older than ten minutes")
        }
    }

    // MARK: Requests

    func testRefreshRequest() {
        let request = SpotifyOAuth.refreshRequest(refreshToken: "r/1+2=", clientID: clientID)
        XCTAssertEqual(request.url, URL(string: "https://accounts.spotify.com/api/token"))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "PKCE: no client secret, no Basic auth")
        XCTAssertEqual(form(request), ["grant_type": "refresh_token", "refresh_token": "r/1+2=", "client_id": clientID])
        let body = String(data: request.httpBody!, encoding: .utf8)!
        XCTAssertTrue(body.contains("refresh_token=r%2F1%2B2%3D"), body)
        XCTAssertFalse(body.contains("client_secret"))
    }

    func testCodeExchangeRequest() {
        let request = SpotifyOAuth.codeExchangeRequest(code: "the-code", verifier: "the-verifier", clientID: clientID)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(form(request), ["grant_type": "authorization_code", "code": "the-code",
                                       "redirect_uri": "duodash://spotify-callback", "client_id": clientID,
                                       "code_verifier": "the-verifier"])
    }

    // MARK: Replies

    func testTokenReplyParsing() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let rotated = try SpotifyOAuth.token(from: Data(#"{"access_token":"A1","token_type":"Bearer","expires_in":3600,"refresh_token":"R2","scope":"app-remote-control"}"#.utf8),
                                             status: 200, previousRefreshToken: "R1", now: now)
        XCTAssertEqual(rotated, SpotifyToken(accessToken: "A1", expiresAt: now.addingTimeInterval(3600), refreshToken: "R2"))

        let kept = try SpotifyOAuth.token(from: Data(#"{"access_token":"A2","expires_in":1800}"#.utf8),
                                          status: 200, previousRefreshToken: "R1", now: now)
        XCTAssertEqual(kept.refreshToken, "R1", "no new refresh token: the old one carries on")
        XCTAssertEqual(kept.expiresAt, now.addingTimeInterval(1800))

        XCTAssertThrowsError(try SpotifyOAuth.token(from: Data(#"{"error":"invalid_grant","error_description":"Refresh token revoked"}"#.utf8),
                                                    status: 400)) {
            XCTAssertEqual($0 as? SpotifyAuthError, .invalidGrant)
        }
        // The development-mode allow-list and unknown clients: "not allowed", not "try again".
        XCTAssertThrowsError(try SpotifyOAuth.token(from: Data(#"{"error":"invalid_client","error_description":"Invalid client"}"#.utf8),
                                                    status: 400)) {
            XCTAssertEqual($0 as? SpotifyAuthError, .notAllowed("Invalid client"))
        }
        XCTAssertThrowsError(try SpotifyOAuth.token(from: Data(#"{"error":"access_denied","error_description":"User not registered in the Developer Dashboard"}"#.utf8),
                                                    status: 403)) {
            XCTAssertEqual($0 as? SpotifyAuthError, .denied("Spotify access wasn't allowed."), "access_denied is the user saying no")
        }
        XCTAssertThrowsError(try SpotifyOAuth.token(from: Data(#"{"error":"server_error","error_description":"User not registered in the Developer Dashboard"}"#.utf8),
                                                    status: 403)) {
            XCTAssertEqual($0 as? SpotifyAuthError, .notAllowed("User not registered in the Developer Dashboard"))
        }
        XCTAssertThrowsError(try SpotifyOAuth.token(from: Data(), status: 403)) {
            XCTAssertEqual($0 as? SpotifyAuthError, .notAllowed("HTTP 403."))
        }
        XCTAssertThrowsError(try SpotifyOAuth.token(from: Data(#"{"error":"server_error"}"#.utf8), status: 500)) {
            XCTAssertEqual($0 as? SpotifyAuthError, .server("server_error"))
        }
        XCTAssertThrowsError(try SpotifyOAuth.token(from: Data("<html>".utf8), status: 503)) {
            XCTAssertEqual($0 as? SpotifyAuthError, .server("HTTP 503."))
        }
        XCTAssertThrowsError(try SpotifyOAuth.token(from: Data("{}".utf8), status: 200)) {
            XCTAssertEqual($0 as? SpotifyAuthError, .badResponse)
        }
    }

    func testAuthorizerRefreshOverStubbedNetwork() async throws {
        let auth = SpotifyPKCEAuthorizer(clientID: clientID, session: SpotifyTokenStubProtocol.session())
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        auth.now = { now }
        SpotifyTokenStubProtocol.handler = { _ in (200, Data(#"{"access_token":"fresh","expires_in":3600}"#.utf8)) }
        let token = try await auth.refresh("saved-refresh")
        XCTAssertEqual(token, SpotifyToken(accessToken: "fresh", expiresAt: now.addingTimeInterval(3600), refreshToken: "saved-refresh"))
        XCTAssertEqual(SpotifyTokenStubProtocol.requests.count, 1)
        let sent = try XCTUnwrap(SpotifyTokenStubProtocol.requests.first)
        XCTAssertEqual(sent.url?.host, "accounts.spotify.com")
        XCTAssertEqual(form(sent)["refresh_token"], "saved-refresh")
        XCTAssertEqual(form(sent)["grant_type"], "refresh_token")

        SpotifyTokenStubProtocol.handler = { _ in (400, Data(#"{"error":"invalid_grant"}"#.utf8)) }
        do {
            _ = try await auth.refresh("revoked")
            XCTFail("a revoked refresh token must fail")
        } catch {
            XCTAssertEqual(error as? SpotifyAuthError, .invalidGrant)
        }
    }

    // MARK: Renew or sign in

    func testTokenPlan() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func token(_ seconds: TimeInterval, refresh: String? = "R") -> SpotifyToken {
            SpotifyToken(accessToken: "A", expiresAt: now.addingTimeInterval(seconds), refreshToken: refresh)
        }
        XCTAssertEqual(SpotifyTokenPlan.plan(for: nil, at: now), .signIn)
        XCTAssertEqual(SpotifyTokenPlan.plan(for: token(3600), at: now), .use("A"), "fresh")
        XCTAssertEqual(SpotifyTokenPlan.plan(for: token(301), at: now), .use("A"), "just over 5 minutes left")
        XCTAssertEqual(SpotifyTokenPlan.plan(for: token(240), at: now), .refresh("R"), "within 5 minutes of expiry")
        XCTAssertEqual(SpotifyTokenPlan.plan(for: token(-60), at: now), .refresh("R"), "expired")
        // Tokens saved by older builds (App Remote only, no refresh token).
        XCTAssertEqual(SpotifyTokenPlan.plan(for: token(240, refresh: nil), at: now), .use("A"))
        XCTAssertEqual(SpotifyTokenPlan.plan(for: token(30, refresh: nil), at: now), .signIn)
        XCTAssertEqual(SpotifyTokenPlan.plan(for: token(30, refresh: ""), at: now), .signIn)
    }

    func testKeychainKeepsRefreshTokenAndReadsOldTokens() throws {
        let store = KeychainSpotifyTokenStore(service: "duodash.spotify.tests", account: "token-\(UUID().uuidString)")
        let token = SpotifyToken(accessToken: "a", expiresAt: Date(timeIntervalSince1970: 2_000_000_000), refreshToken: "r")
        store.save(token)
        XCTAssertEqual(store.load(), token)
        store.clear()
        XCTAssertNil(store.load())

        // What builds before sign-in-once saved.
        let old = Data(#"{"accessToken":"old","expiresAt":800000000}"#.utf8)
        let decoded = try JSONDecoder().decode(SpotifyToken.self, from: old)
        XCTAssertEqual(decoded.accessToken, "old")
        XCTAssertNil(decoded.refreshToken)
    }

    // MARK: Model

    private func waitUntil(_ timeout: TimeInterval = 3, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
    }

    private func make(_ backend: DemoSpotifyBackend, token: SpotifyToken?, mode: SpotifySignInMode = .signInOnce,
                      access: SpotifyAccessSettings? = nil,
                      store: MemorySpotifyTokenStore? = nil) -> (SpotifyModel, MemorySpotifyTokenStore) {
        let store = store ?? MemorySpotifyTokenStore(token: token)
        let model = SpotifyModel(nowPlaying: NowPlayingModel(), backend: backend, tokens: store,
                                 access: access ?? SpotifyAccessSettings(defaults: nil), buildMode: mode,
                                 observesLifecycle: false)
        return (model, store)
    }

    // MARK: Modes and fallbacks (development-mode allow-list)

    func testModeSelection() {
        XCTAssertEqual(SpotifySignInMode(infoValue: "app-remote"), .appRemoteOnly)
        XCTAssertEqual(SpotifySignInMode(infoValue: " App-Remote "), .appRemoteOnly)
        XCTAssertEqual(SpotifySignInMode(infoValue: "sign-in"), .signInOnce)
        XCTAssertEqual(SpotifySignInMode(infoValue: "$(DUODASH_SPOTIFY_MODE)"), .signInOnce)
        XCTAssertEqual(SpotifySignInMode(infoValue: nil), .signInOnce)

        typealias M = SpotifySignInMode
        // Store builds: App Remote only, unless the user brings their own developer app.
        XCTAssertEqual(M.choose(build: .appRemoteOnly, hasOwnClientID: false, fellBackToAppRemote: false), .appRemoteOnly)
        XCTAssertEqual(M.choose(build: .appRemoteOnly, hasOwnClientID: true, fellBackToAppRemote: false), .signInOnce)
        XCTAssertEqual(M.choose(build: .appRemoteOnly, hasOwnClientID: true, fellBackToAppRemote: true), .signInOnce)
        // Source builds: sign in once, until Spotify refuses the account's sign-in.
        XCTAssertEqual(M.choose(build: .signInOnce, hasOwnClientID: false, fellBackToAppRemote: false), .signInOnce)
        XCTAssertEqual(M.choose(build: .signInOnce, hasOwnClientID: false, fellBackToAppRemote: true), .appRemoteOnly)
    }

    func testRefusalClassification() {
        for text in ["User not registered in the Developer Dashboard", "INVALID_CLIENT: Invalid client", "unauthorized_client",
                     "HTTP 403.", "Forbidden"] {
            XCTAssertTrue(SpotifyRefusal.isNotAllowed(text), text)
        }
        for text in ["Spotify isn't running.", "access_denied", "The access token expired", "", "HTTP 500."] {
            XCTAssertFalse(SpotifyRefusal.isNotAllowed(text), text)
        }
        XCTAssertFalse(SpotifyRefusal.isNotAllowed(nil))

        let auth = SpotifyPKCEAuthorizer(clientID: clientID, session: SpotifyTokenStubProtocol.session())
        _ = auth.begin(SpotifyPKCE(verifier: String(repeating: "a", count: 43), state: "st"))
        XCTAssertThrowsError(try auth.accept(URL(string: "duodash://spotify-callback?error=unauthorized_client&error_description=User%20not%20registered&state=st")!)) {
            XCTAssertEqual($0 as? SpotifyAuthError, .notAllowed("unauthorized_client: User not registered"))
        }
    }

    func testClientIDValidation() {
        XCTAssertEqual(SpotifyAccessSettings.normalisedClientID(" 0123456789ABCDEF0123456789abcdef\n"), "0123456789abcdef0123456789abcdef")
        XCTAssertNil(SpotifyAccessSettings.normalisedClientID("0123456789abcdef"))
        XCTAssertNil(SpotifyAccessSettings.normalisedClientID("0123456789abcdef0123456789abcdeg"))
    }

    /// TestFlight / App Store: no accounts.spotify.com sign-in at all, only the Spotify app.
    func testStoreBuildUsesAppRemoteOnly() async {
        let backend = DemoSpotifyBackend()
        let (model, store) = make(backend, token: nil, mode: .appRemoteOnly)
        XCTAssertEqual(model.mode, .appRemoteOnly)
        model.connect()
        await waitUntil { model.status == .connected }
        XCTAssertEqual(model.status, .connected)
        XCTAssertEqual(backend.signInCount, 0, "no Web API sign-in")
        XCTAssertEqual(backend.authorizeCount, 1)
        XCTAssertNil(store.token?.refreshToken)
        await waitUntil { model.hasLoadedLibrary }
        XCTAssertFalse(model.shelves.isEmpty, "browsing comes from App Remote's content API")

        // The token ran out and Spotify was closed: Connect opens Spotify again, no sign-in.
        backend.simulateSpotifyQuit()
        await waitUntil { model.status != .connected }
        store.token?.expiresAt = .now.addingTimeInterval(-60)
        model.connect()
        await waitUntil { model.status == .connected }
        XCTAssertEqual(backend.authorizeCount, 2)
        XCTAssertEqual(backend.signInCount, 0)
        XCTAssertEqual(backend.refreshCount, 0)
    }

    func testAppRemoteOnlyNeverOpensSpotifyByItself() async {
        let backend = DemoSpotifyBackend(spotifyRunning: true)
        let (model, _) = make(backend, token: SpotifyToken(accessToken: "old", expiresAt: .now.addingTimeInterval(-60)),
                              mode: .appRemoteOnly)
        model.appDidBecomeActive()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.status, .notConnected)
        XCTAssertEqual(backend.authorizeCount, 0)
        XCTAssertEqual(backend.connectCount, 0)
    }

    /// Not on the allow-list: the PKCE sign-in is refused, so it carries on through the Spotify
    /// app, and remembers that (no sign-in attempt next time).
    func testSignInNotAllowedFallsBackToAppRemote() async {
        let access = SpotifyAccessSettings(defaults: nil)
        let backend = DemoSpotifyBackend()
        backend.signInNotAllowed = true
        let (model, store) = make(backend, token: nil, access: access)
        XCTAssertEqual(model.mode, .signInOnce)
        model.connect()
        await waitUntil { model.status == .connected }
        XCTAssertEqual(model.status, .connected)
        XCTAssertEqual(backend.signInCount, 1)
        XCTAssertEqual(backend.authorizeCount, 1)
        XCTAssertEqual(model.mode, .appRemoteOnly)
        XCTAssertTrue(access.fellBackToAppRemote)
        XCTAssertFalse(model.isSignedIn)
        XCTAssertNil(store.token?.refreshToken)

        let relaunched = DemoSpotifyBackend()
        relaunched.signInNotAllowed = true
        let (again, _) = make(relaunched, token: nil, access: access)
        XCTAssertEqual(again.mode, .appRemoteOnly)
        again.connect()
        await waitUntil { again.status == .connected }
        XCTAssertEqual(relaunched.signInCount, 0, "doesn't try the refused sign-in again")
    }

    func testRefreshNotAllowedOnLaunchFallsBackQuietly() async {
        let access = SpotifyAccessSettings(defaults: nil)
        let backend = DemoSpotifyBackend(spotifyRunning: true)
        backend.refreshFailure = .notAllowed("User not registered")
        let (model, store) = make(backend, token: SpotifyToken(accessToken: "a", expiresAt: .now.addingTimeInterval(-60),
                                                               refreshToken: "r"), access: access)
        await waitUntil { model.status != .connecting }
        XCTAssertEqual(model.status, .notConnected)
        XCTAssertEqual(model.mode, .appRemoteOnly)
        XCTAssertNil(store.token)
        XCTAssertEqual(backend.signInCount, 0)
        XCTAssertEqual(backend.authorizeCount, 0, "nothing opens without a tap")
    }

    /// The Spotify app refuses the account too: a friendly "Open Spotify" state that stays put,
    /// never a loop of failed logins.
    func testAppRemoteRefusedShowsLimitedWithoutLooping() async {
        let access = SpotifyAccessSettings(defaults: nil)
        let backend = DemoSpotifyBackend()
        backend.signInNotAllowed = true
        backend.appRemoteRefused = true
        let (model, store) = make(backend, token: nil, access: access)
        model.connect()
        await waitUntil { model.status == .limited }
        XCTAssertEqual(model.status, .limited)
        XCTAssertTrue(access.isLimited)
        XCTAssertNil(store.token)
        XCTAssertEqual(backend.signInCount, 1)
        XCTAssertEqual(backend.authorizeCount, 1)

        model.connect()
        model.appDidBecomeActive()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.status, .limited)
        XCTAssertEqual(backend.authorizeCount, 1, "no retries on its own")
        XCTAssertEqual(backend.signInCount, 1)

        let relaunched = DemoSpotifyBackend()
        let (again, _) = make(relaunched, token: nil, access: access)
        XCTAssertEqual(again.status, .limited, "remembered across launches")
        XCTAssertEqual(relaunched.connectCount + relaunched.authorizeCount + relaunched.signInCount, 0)

        // Added to the allow-list later: Try Again works.
        again.retryAfterLimited()
        await waitUntil { again.status == .connected }
        XCTAssertEqual(again.status, .connected)
        XCTAssertFalse(access.isLimited)
    }

    func testOwnClientIDGetsFullSignInAndClearsFallbacks() async {
        let access = SpotifyAccessSettings(defaults: nil)
        access.fellBackToAppRemote = true
        access.isLimited = true
        let backend = DemoSpotifyBackend()
        let (model, store) = make(backend, token: SpotifyToken(accessToken: "a", expiresAt: .now.addingTimeInterval(3600)),
                                  mode: .appRemoteOnly, access: access)
        XCTAssertEqual(model.status, .limited)

        let own = "0123456789abcdef0123456789abcdef"
        model.useOwnClientID(own)
        XCTAssertEqual(model.ownClientID, own)
        XCTAssertEqual(access.ownClientID, own)
        XCTAssertEqual(model.mode, .signInOnce)
        XCTAssertFalse(access.isLimited)
        XCTAssertFalse(access.fellBackToAppRemote)
        XCTAssertNil(store.token, "tokens belong to the old Client ID")
        XCTAssertEqual(backend.clientIDs.last, own)
        XCTAssertEqual(model.status, .notConnected)

        model.connect()
        await waitUntil { model.status == .connected }
        XCTAssertEqual(backend.signInCount, 1)
        XCTAssertTrue(model.isSignedIn)

        model.useOwnClientID(nil)
        XCTAssertNil(access.ownClientID)
        XCTAssertEqual(model.mode, .appRemoteOnly)
        XCTAssertFalse(model.isSignedIn)
    }

    func testAccessSettingsPersist() {
        let suite = "SpotifyAccessTests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = SpotifyAccessSettings(defaults: defaults)
        a.ownClientID = "0123456789abcdef0123456789abcdef"
        a.fellBackToAppRemote = true
        a.isLimited = true
        let b = SpotifyAccessSettings(defaults: defaults)
        XCTAssertEqual(b.ownClientID, "0123456789abcdef0123456789abcdef")
        XCTAssertTrue(b.fellBackToAppRemote)
        XCTAssertTrue(b.isLimited)
    }

    /// The point of it all: an hour later, Duo Dash reconnects on launch without the user.
    func testExpiredAccessTokenRenewsSilentlyOnLaunch() async {
        let backend = DemoSpotifyBackend(spotifyRunning: true)
        let (model, store) = make(backend, token: SpotifyToken(accessToken: "old", expiresAt: .now.addingTimeInterval(-600),
                                                               refreshToken: "demo-refresh"))
        XCTAssertTrue(model.isSignedIn)
        XCTAssertEqual(model.status, .connecting)
        await waitUntil { model.status == .connected }
        XCTAssertEqual(model.status, .connected)
        XCTAssertEqual(backend.refreshCount, 1)
        XCTAssertEqual(backend.signInCount, 0, "no sign-in")
        XCTAssertEqual(backend.authorizeCount, 0, "Spotify didn't have to open")
        XCTAssertEqual(store.token?.accessToken, "demo-refreshed-1")
        XCTAssertEqual(store.token?.refreshToken, "demo-refresh")
    }

    func testNearExpiryRenewsBeforeConnecting() async {
        let backend = DemoSpotifyBackend(spotifyRunning: true)
        let (model, _) = make(backend, token: SpotifyToken(accessToken: "soon", expiresAt: .now.addingTimeInterval(120),
                                                           refreshToken: "demo-refresh"))
        await waitUntil { model.status == .connected }
        XCTAssertEqual(backend.refreshCount, 1)
        XCTAssertEqual(backend.connectCount, 1, "connected once, with the renewed token")
    }

    func testSignInOnceThenReconnectsWithoutSigningIn() async {
        let backend = DemoSpotifyBackend()
        let (model, store) = make(backend, token: nil)
        XCTAssertFalse(model.isSignedIn)
        model.connect()
        await waitUntil { model.status == .connected }
        XCTAssertEqual(backend.signInCount, 1)
        XCTAssertEqual(backend.authorizeCount, 1, "Spotify opened once to start playing")
        XCTAssertTrue(model.isSignedIn)
        XCTAssertEqual(store.token?.refreshToken, "demo-refresh", "the wake-up token keeps the refresh token")

        // Hours later: Spotify was closed and the access token has run out.
        backend.simulateSpotifyQuit()
        await waitUntil { model.status != .connected }
        store.token?.expiresAt = .now.addingTimeInterval(-3600)
        model.connect()
        await waitUntil { model.status == .connected }
        XCTAssertEqual(model.status, .connected)
        XCTAssertEqual(backend.signInCount, 1, "never asked to sign in again")
        XCTAssertEqual(backend.refreshCount, 1)
        XCTAssertEqual(backend.authorizeCount, 2, "Spotify wasn't running, so it opened for a moment")
    }

    /// A revoked refresh token after a tap: the user signs in again (interactive).
    func testInvalidGrantAfterTapSignsInAgain() async {
        let backend = DemoSpotifyBackend(spotifyRunning: true)
        backend.refreshFailure = .invalidGrant
        let (model, store) = make(backend, token: nil)
        store.token = SpotifyToken(accessToken: "old", expiresAt: .now.addingTimeInterval(-60), refreshToken: "revoked")
        model.connect()
        await waitUntil { model.status == .connected }
        XCTAssertEqual(model.status, .connected)
        XCTAssertEqual(backend.refreshCount, 1)
        XCTAssertEqual(backend.signInCount, 1)
        XCTAssertEqual(store.token?.refreshToken, "demo-refresh")
    }

    /// Without a tap (launch, foreground) a revoked sign-in never pops up a login: it's
    /// forgotten and the screen asks to sign in again.
    func testInvalidGrantOnLaunchDoesNotPopUpSignIn() async {
        let backend = DemoSpotifyBackend(spotifyRunning: true)
        backend.refreshFailure = .invalidGrant
        let (model, store) = make(backend, token: SpotifyToken(accessToken: "old", expiresAt: .now.addingTimeInterval(-60),
                                                               refreshToken: "revoked"))
        await waitUntil { model.status != .connecting }
        XCTAssertEqual(model.status, .disconnected("Your Spotify sign-in has ended. Sign in again."))
        XCTAssertEqual(backend.signInCount, 0)
        XCTAssertNil(store.token)
        XCTAssertFalse(model.isSignedIn)
    }

    /// Offline at launch: no sign-in either; a token with a few minutes left is still used.
    func testNetworkFailureKeepsSignInAndUsesValidToken() async {
        let backend = DemoSpotifyBackend(spotifyRunning: true)
        backend.refreshFailure = .network("offline")
        let (model, store) = make(backend, token: SpotifyToken(accessToken: "still-good", expiresAt: .now.addingTimeInterval(180),
                                                               refreshToken: "demo-refresh"))
        await waitUntil { model.status == .connected }
        XCTAssertEqual(model.status, .connected)
        XCTAssertEqual(store.token?.refreshToken, "demo-refresh", "a network error doesn't sign out")
        XCTAssertEqual(backend.signInCount, 0)

        let offline = DemoSpotifyBackend(spotifyRunning: true)
        offline.refreshFailure = .network("offline")
        let (expired, expiredStore) = make(offline, token: SpotifyToken(accessToken: "x", expiresAt: .now.addingTimeInterval(-60),
                                                                        refreshToken: "demo-refresh"))
        await waitUntil { expired.status != .connecting }
        XCTAssertEqual(expired.status, .disconnected("Couldn't reach Spotify. Check the connection, then try again."))
        XCTAssertNotNil(expiredStore.token)
        XCTAssertEqual(offline.signInCount, 0)
    }

    func testSignOutClearsTokens() async {
        let backend = DemoSpotifyBackend(spotifyRunning: true)
        let (model, store) = make(backend, token: SpotifyToken(accessToken: "a", expiresAt: .now.addingTimeInterval(3600),
                                                               refreshToken: "demo-refresh"))
        await waitUntil { model.hasLoadedLibrary }
        XCTAssertEqual(model.status, .connected)
        model.signOut()
        XCTAssertNil(store.token)
        XCTAssertFalse(model.isSignedIn)
        XCTAssertEqual(model.status, .notConnected)
        XCTAssertTrue(model.recents.isEmpty)
        XCTAssertFalse(backend.isConnected)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.status, .notConnected, "the disconnect event doesn't turn into Reconnect")

        // Coming back to the app doesn't reconnect: there's nothing to connect with.
        model.appDidBecomeActive()
        XCTAssertEqual(model.status, .notConnected)
        XCTAssertEqual(backend.signInCount, 0)
    }

    func testSignOutWhileRenewingWins() async {
        let backend = DemoSpotifyBackend(spotifyRunning: true)
        let (model, store) = make(backend, token: SpotifyToken(accessToken: "a", expiresAt: .now.addingTimeInterval(-60),
                                                               refreshToken: "demo-refresh"))
        XCTAssertEqual(model.status, .connecting)
        model.signOut()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(store.token, "a renewal finishing after sign-out must not save tokens")
        XCTAssertEqual(model.status, .notConnected)
        XCTAssertEqual(backend.connectCount, 0)
    }

    /// A redirect nobody asked for is swallowed and changes nothing.
    func testUnaskedRedirectIgnored() {
        let (model, store) = make(DemoSpotifyBackend(spotifyRunning: true), token: nil)
        XCTAssertTrue(model.handleOpenURL(URL(string: "duodash://spotify-callback#access_token=planted&expires_in=3600")!))
        XCTAssertNil(store.token)
        XCTAssertEqual(model.status, .notConnected)
    }
}
