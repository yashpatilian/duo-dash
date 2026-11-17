import UIKit
import CryptoKit
import Security
import AuthenticationServices

/// The Spotify settings baked into this build.
enum SpotifyConfig {
    static let redirectURI = "duodash://spotify-callback"
    /// App Remote is the only Spotify API Duo Dash uses (playback, the home feed and
    /// artwork all go through the Spotify app), so this is the only scope it asks for.
    static let scopes = ["app-remote-control"]
    static let authorizeURL = URL(string: "https://accounts.spotify.com/authorize")!
    static let tokenURL = URL(string: "https://accounts.spotify.com/api/token")!

    /// The client ID from the Info.plist key `SpotifyClientID` (build setting `SPOTIFY_CLIENT_ID`,
    /// set in the git-ignored Config/Secrets.xcconfig). nil when the build has none.
    static func clientID(info: [String: Any]? = Bundle.main.infoDictionary) -> String? {
        let value = (info?["SpotifyClientID"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // An unset build setting comes through empty (or as the literal "$(…)").
        return value.isEmpty || value.hasPrefix("$(") ? nil : value
    }

    /// The build ships a client ID, so connecting is one tap and the welcome tour skips the
    /// developer-dashboard walkthrough. UI tests can force either with
    /// `-SpotifyBundledClientID YES|NO`.
    static func hasBundledClientID(info: [String: Any]? = Bundle.main.infoDictionary,
                                   arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        if let index = arguments.firstIndex(of: "-SpotifyBundledClientID"), index + 1 < arguments.count {
            return ["yes", "1", "true"].contains(arguments[index + 1].lowercased())
        }
        return clientID(info: info) != nil
    }
}

// MARK: - PKCE

/// One Authorization Code with PKCE attempt (RFC 7636): the secret verifier, its S256
/// challenge, and the `state` that Spotify's redirect must echo back.
struct SpotifyPKCE: Equatable, Sendable {
    let verifier: String
    let challenge: String
    let state: String

    init(verifier: String, state: String) {
        self.verifier = verifier
        self.challenge = Self.challenge(for: verifier)
        self.state = state
    }

    /// A fresh attempt: a 64-byte verifier (86 characters, within RFC 7636's 43 to 128) and
    /// a 16-byte state, both from the system's secure random generator.
    static func random() -> SpotifyPKCE {
        SpotifyPKCE(verifier: base64URL(randomBytes(64)), state: base64URL(randomBytes(16)))
    }

    /// BASE64URL(SHA256(ASCII(verifier))), without padding.
    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) != errSecSuccess {
            // Never happens in practice; fall back to the system RNG rather than a fixed value.
            var generator = SystemRandomNumberGenerator()
            bytes = bytes.map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        }
        return Data(bytes)
    }
}

// MARK: - Errors

enum SpotifyAuthError: LocalizedError, Equatable {
    /// The user closed the sign-in sheet.
    case cancelled
    /// The user said no on Spotify's page (or Spotify refused the app).
    case denied(String)
    /// A redirect arrived that this app didn't ask for, or whose `state` doesn't match.
    case unexpectedRedirect
    /// The refresh token is no longer accepted: sign in again.
    case invalidGrant
    /// Spotify won't let this account use this developer app (not on the development-mode
    /// allow-list, HTTP 403, `invalid_client`). Signing in again won't help.
    case notAllowed(String)
    case server(String)
    case network(String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .cancelled: "Spotify sign-in was cancelled."
        case .denied(let reason): reason
        case .unexpectedRedirect: "Spotify's reply didn't match this sign-in. Try again."
        case .invalidGrant: "Your Spotify sign-in has ended. Sign in again."
        case .notAllowed: "Spotify doesn't let this account sign in to Duo Dash."
        case .server(let reason): "Spotify couldn't sign you in. \(reason)"
        case .network: "Couldn't reach Spotify. Check the connection, then try again."
        case .badResponse: "Spotify sent an unexpected reply. Try again."
        }
    }
}

// MARK: - Requests and responses

/// Builds the Authorization Code with PKCE requests and reads Spotify's replies. No client
/// secret is involved anywhere: PKCE replaces it for public clients like this app.
enum SpotifyOAuth {
    static func authorizeURL(clientID: String, pkce: SpotifyPKCE,
                             scopes: [String] = SpotifyConfig.scopes,
                             redirectURI: String = SpotifyConfig.redirectURI) -> URL {
        var components = URLComponents(url: SpotifyConfig.authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "state", value: pkce.state),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
        ]
        return components.url!
    }

    /// The authorization code from Spotify's redirect, once its `state` has been checked.
    static func code(from url: URL, expectedState: String,
                     redirectURI: String = SpotifyConfig.redirectURI) throws -> String {
        guard let redirect = URL(string: redirectURI), url.scheme == redirect.scheme, url.host == redirect.host,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            throw SpotifyAuthError.unexpectedRedirect
        }
        let values = Dictionary(items.map { ($0.name, $0.value ?? "") }) { first, _ in first }
        // Check the state before anything else, errors included: a reply to someone
        // else's request must not change what the app does.
        guard let state = values["state"], !expectedState.isEmpty, state == expectedState else {
            throw SpotifyAuthError.unexpectedRedirect
        }
        if let error = values["error"] {
            let detail = [error, values["error_description"]].compactMap { $0 }.joined(separator: ": ")
            if error != "access_denied", SpotifyRefusal.isNotAllowed(detail) {
                throw SpotifyAuthError.notAllowed(detail)
            }
            throw SpotifyAuthError.denied(error == "access_denied" ? "Spotify access wasn't allowed." : "Spotify didn't allow the connection (\(error)).")
        }
        guard let code = values["code"], !code.isEmpty else { throw SpotifyAuthError.badResponse }
        return code
    }

    static func codeExchangeRequest(code: String, verifier: String, clientID: String,
                                    redirectURI: String = SpotifyConfig.redirectURI) -> URLRequest {
        formRequest(["grant_type": "authorization_code", "code": code, "redirect_uri": redirectURI,
                     "client_id": clientID, "code_verifier": verifier])
    }

    static func refreshRequest(refreshToken: String, clientID: String) -> URLRequest {
        formRequest(["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": clientID])
    }

    private static func formRequest(_ fields: [String: String]) -> URLRequest {
        var request = URLRequest(url: SpotifyConfig.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        request.httpBody = Data(fields.sorted { $0.key < $1.key }
            .map { "\(formEncode($0.key))=\(formEncode($0.value))" }
            .joined(separator: "&").utf8)
        return request
    }

    /// application/x-www-form-urlencoded: everything but unreserved characters escaped.
    static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private struct TokenBody: Decodable {
        let access_token: String
        let expires_in: TimeInterval?
        let refresh_token: String?
    }

    private struct ErrorBody: Decodable {
        let error: String?
        let error_description: String?
    }

    /// Reads a token endpoint reply. Spotify may rotate the refresh token; when the reply has
    /// none, the one used for the request carries on.
    static func token(from data: Data, status: Int, previousRefreshToken: String? = nil,
                      now: Date = .now) throws -> SpotifyToken {
        guard (200..<300).contains(status) else {
            let body = try? JSONDecoder().decode(ErrorBody.self, from: data)
            if body?.error == "invalid_grant" { throw SpotifyAuthError.invalidGrant }
            if body?.error == "access_denied" { throw SpotifyAuthError.denied("Spotify access wasn't allowed.") }
            let reason = body?.error_description ?? body?.error ?? "HTTP \(status)."
            // 403, invalid_client / unauthorized_client, "User not registered in the Developer
            // Dashboard": the allow-list, not something another sign-in fixes.
            if status == 403 || SpotifyRefusal.isNotAllowed([body?.error, body?.error_description].compactMap { $0 }.joined(separator: " ")) {
                throw SpotifyAuthError.notAllowed(reason)
            }
            throw SpotifyAuthError.server(reason)
        }
        guard let body = try? JSONDecoder().decode(TokenBody.self, from: data), !body.access_token.isEmpty else {
            throw SpotifyAuthError.badResponse
        }
        let refresh = body.refresh_token.flatMap { $0.isEmpty ? nil : $0 } ?? previousRefreshToken
        return SpotifyToken(accessToken: body.access_token,
                            expiresAt: now.addingTimeInterval(body.expires_in ?? 3600),
                            refreshToken: refresh)
    }
}

// MARK: - Authorizer

/// Signs in to Spotify (interactive, once) and renews the access token (silent).
@MainActor
protocol SpotifyAuthorizing: AnyObject {
    /// Asks the user to sign in and approve Duo Dash. Returns tokens including a refresh token.
    func signIn() async throws -> SpotifyToken
    /// Swaps a refresh token for a new access token, without the user.
    func refresh(_ refreshToken: String) async throws -> SpotifyToken
    /// Switches to another developer app's Client ID (Settings → Spotify); nil: none.
    func setClientID(_ clientID: String?)
}

/// Authorization Code with PKCE against accounts.spotify.com, signing in through an
/// `ASWebAuthenticationSession` sheet that shares Safari's cookies (so an existing Spotify
/// web login is reused). Tokens come from https://accounts.spotify.com/api/token.
@MainActor
final class SpotifyPKCEAuthorizer: NSObject, SpotifyAuthorizing {
    private(set) var clientID: String
    private let session: URLSession
    var now: () -> Date = { .now }
    /// The attempt in progress. A redirect is only accepted while this is set, within ten
    /// minutes, and with its `state`.
    private(set) var pending: (pkce: SpotifyPKCE, startedAt: Date)?
    private var webSession: ASWebAuthenticationSession?
    /// The window the sign-in sheet is shown over.
    private var anchor: UIWindow?

    init(clientID: String, session: URLSession = .shared) {
        self.clientID = clientID
        self.session = session
    }

    func signIn() async throws -> SpotifyToken {
        let pkce = SpotifyPKCE.random()
        let url = begin(pkce)
        let callback = try await openSheet(url)
        let (code, verifier) = try accept(callback)
        return try await send(SpotifyOAuth.codeExchangeRequest(code: code, verifier: verifier, clientID: clientID),
                              previousRefreshToken: nil)
    }

    func refresh(_ refreshToken: String) async throws -> SpotifyToken {
        try await send(SpotifyOAuth.refreshRequest(refreshToken: refreshToken, clientID: clientID),
                       previousRefreshToken: refreshToken)
    }

    func setClientID(_ clientID: String?) {
        self.clientID = clientID ?? ""
        pending = nil
    }

    /// Starts an attempt and returns the URL to show. Split out for tests.
    func begin(_ pkce: SpotifyPKCE) -> URL {
        pending = (pkce, now())
        return SpotifyOAuth.authorizeURL(clientID: clientID, pkce: pkce)
    }

    /// Checks a redirect against the attempt in progress and ends it. Throws
    /// `unexpectedRedirect` for a redirect nobody asked for, a stale one, or a wrong state.
    func accept(_ url: URL) throws -> (code: String, verifier: String) {
        guard let pending, now().timeIntervalSince(pending.startedAt) < 600 else {
            throw SpotifyAuthError.unexpectedRedirect
        }
        let code = try SpotifyOAuth.code(from: url, expectedState: pending.pkce.state)
        self.pending = nil
        return (code, pending.pkce.verifier)
    }

    private func send(_ request: URLRequest, previousRefreshToken: String?) async throws -> SpotifyToken {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SpotifyAuthError.network(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return try SpotifyOAuth.token(from: data, status: status, previousRefreshToken: previousRefreshToken, now: now())
    }

    private func openSheet(_ url: URL) async throws -> URL {
        let scheme = URL(string: SpotifyConfig.redirectURI)?.scheme ?? "duodash"
        guard let window = Self.visibleWindow() else {
            pending = nil
            throw SpotifyAuthError.network("Open Duo Dash, then try again.")
        }
        anchor = window
        return try await withCheckedThrowingContinuation { continuation in
            let sheet = ASWebAuthenticationSession(url: url, callback: .customScheme(scheme)) { [weak self] callback, error in
                let code = (error as? ASWebAuthenticationSessionError)?.code
                let reason = error?.localizedDescription
                Task { @MainActor in
                    self?.webSession = nil
                    self?.anchor = nil
                    if let callback {
                        continuation.resume(returning: callback)
                    } else {
                        self?.pending = nil
                        continuation.resume(throwing: code == .canceledLogin
                                            ? SpotifyAuthError.cancelled
                                            : SpotifyAuthError.network(reason ?? "Sign-in failed."))
                    }
                }
            }
            sheet.presentationContextProvider = self
            // Share Safari's cookies, so someone already signed in to Spotify on the web
            // only has to tap Agree.
            sheet.prefersEphemeralWebBrowserSession = false
            webSession = sheet
            if !sheet.start() {
                webSession = nil
                pending = nil
                continuation.resume(throwing: SpotifyAuthError.network("The sign-in sheet couldn't open."))
            }
        }
    }
}

extension SpotifyPKCEAuthorizer: ASWebAuthenticationPresentationContextProviding {
    static func visibleWindow() -> UIWindow? {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        return windows.first(where: \.isKeyWindow) ?? windows.first
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        guard let window = anchor ?? Self.visibleWindow() else {
            // Not reached: the sheet only starts once `openSheet` has found a window.
            preconditionFailure("Spotify sign-in started without a window")
        }
        return window
    }
}
