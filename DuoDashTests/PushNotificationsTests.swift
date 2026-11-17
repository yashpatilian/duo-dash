import XCTest
@testable import DuoDash

/// Records requests to the announcements server and answers with a set status code.
final class NotifyStubProtocol: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var bodies: [[String: Any]] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        // URLSession moves the body into a stream before a URLProtocol sees it.
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            stream.close()
        }
        Self.bodies.append((try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:])
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func reset() { status = 200; requests = []; bodies = [] }

    static var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NotifyStubProtocol.self]
        return URLSession(configuration: config)
    }
}

@MainActor
final class PushNotificationsTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "PushNotificationsTests"
    private let base = URL(string: "https://notify.example.com")!
    private let tokenBytes = Data([0x00, 0x01, 0x0a, 0xff, 0xab, 0xcd] + Array(repeating: UInt8(0x5c), count: 26))
    private var registerCalls = 0
    private var authorizationAnswer = true

    override func setUp() {
        super.setUp()
        NotifyStubProtocol.reset()
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
        registerCalls = 0
        authorizationAnswer = true
    }

    override func tearDown() {
        NotifyStubProtocol.reset()
        UserDefaults().removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func makeModel(baseURL: URL?, pushEntitled: Bool = true) -> PushNotifications {
        PushNotifications(
            baseURL: baseURL, bundleId: "com.duodash.beta", appVersion: "1.4", environment: .production,
            pushEntitled: pushEntitled, defaults: defaults, session: NotifyStubProtocol.session,
            system: .init(requestAuthorization: { [unowned self] in authorizationAnswer },
                          isAuthorized: { [unowned self] in authorizationAnswer },
                          registerForRemoteNotifications: { [unowned self] in registerCalls += 1 })
        )
    }

    // MARK: Token formatting

    func testTokenHexIsLowercaseTwoDigitsPerByte() {
        let hex = PushRegistration.hex(tokenBytes)
        XCTAssertEqual(hex.count, 64)
        XCTAssertTrue(hex.hasPrefix("00010affabcd5c"))
        XCTAssertEqual(hex, hex.lowercased())
        XCTAssertEqual(PushRegistration.hex(Data()), "")
    }

    // MARK: Request building

    func testRegisterRequest() throws {
        let registration = PushRegistration(token: "abcd", bundleId: "com.duodash.app", environment: .production, appVersion: "2.0")
        let request = registration.registerRequest(base: URL(string: "https://notify.example.com/api")!)
        XCTAssertEqual(request.url?.absoluteString, "https://notify.example.com/api/register")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
        XCTAssertEqual(body, ["token": "abcd", "bundleId": "com.duodash.app", "environment": "production", "appVersion": "2.0"])
    }

    func testUnregisterRequest() throws {
        let request = PushRegistration.unregisterRequest(base: base, token: "beef")
        XCTAssertEqual(request.url?.absoluteString, "https://notify.example.com/unregister")
        XCTAssertEqual(request.httpMethod, "POST")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
        XCTAssertEqual(body, ["token": "beef"])
    }

    func testBaseURLFromInfoPlistValue() {
        XCTAssertNil(PushRegistration.baseURL(from: nil))
        XCTAssertNil(PushRegistration.baseURL(from: ""))
        XCTAssertNil(PushRegistration.baseURL(from: "   "))
        XCTAssertNil(PushRegistration.baseURL(from: "$(DUODASH_NOTIFY_URL)"), "unexpanded build variable")
        XCTAssertNil(PushRegistration.baseURL(from: "https:"), "a full URL cut off by the xcconfig // comment")
        XCTAssertNil(PushRegistration.baseURL(from: "http://notify.example.com"), "https only")
        XCTAssertEqual(PushRegistration.baseURL(from: "notify.example.com")?.absoluteString, "https://notify.example.com")
        XCTAssertEqual(PushRegistration.baseURL(from: "https://notify.example.com/")?.absoluteString, "https://notify.example.com")
    }

    func testEnvironmentChoice() {
        // App Store and TestFlight builds have no embedded profile: production APNs.
        XCTAssertEqual(PushRegistration.environment(provisioningProfile: nil, isSimulator: false), .production)
        XCTAssertEqual(PushRegistration.environment(provisioningProfile: nil, isSimulator: true), .sandbox)
        XCTAssertEqual(PushRegistration.environment(provisioningProfile: profile(aps: "development"), isSimulator: false), .sandbox)
        XCTAssertEqual(PushRegistration.environment(provisioningProfile: profile(aps: "production"), isSimulator: false), .production)
        XCTAssertEqual(PushRegistration.environment(provisioningProfile: profile(aps: nil), isSimulator: false), .sandbox)
        XCTAssertEqual(PushRegistration.environment(provisioningProfile: Data("garbage".utf8), isSimulator: false), .sandbox)
    }

    /// A stand-in .mobileprovision: binary signature bytes around an XML plist.
    private func profile(aps: String?) -> Data {
        let entitlement = aps.map { "<key>aps-environment</key><string>\($0)</string>" } ?? ""
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>Name</key><string>Test</string>
        <key>Entitlements</key><dict>\(entitlement)<key>get-task-allow</key><true/></dict></dict></plist>
        """
        return Data([0x30, 0x82, 0x01, 0x00]) + Data(xml.utf8) + Data([0xa0, 0x00, 0x31])
    }

    // MARK: Inert when not configured

    func testNoOpWhenURLEmpty() async {
        let push = makeModel(baseURL: PushRegistration.baseURL(from: ""))
        XCTAssertFalse(push.isAvailable)
        await push.setEnabled(true)
        XCTAssertFalse(push.isEnabled)
        XCTAssertEqual(push.status, .off)
        await push.resumeOnLaunch()
        await push.didRegister(deviceToken: tokenBytes)
        XCTAssertEqual(registerCalls, 0, "never asks iOS for a token")
        XCTAssertTrue(NotifyStubProtocol.requests.isEmpty, "never contacts a server")
        XCTAssertNil(defaults.object(forKey: "notify.enabled"))
    }

    func testNoOpWithoutPushEntitlement() async {
        let push = makeModel(baseURL: base, pushEntitled: false)
        XCTAssertFalse(push.isAvailable)
        await push.setEnabled(true)
        XCTAssertEqual(registerCalls, 0)
        XCTAssertTrue(NotifyStubProtocol.requests.isEmpty)
    }

    func testDefaultBuildHidesTheSettingsPage() {
        // The repo's default config leaves DUODASH_NOTIFY_URL empty and DUODASH_PUSH = NO.
        XCTAssertFalse(PushNotifications.isConfiguredInThisBuild)
        XCTAssertFalse(SettingsView.SettingsSection.notifications.isListed)
        XCTAssertFalse(SettingsView.SettingsSection.groups.joined().contains(.notifications))
        XCTAssertTrue(SettingsView.SettingsSection.assistant.isListed)
    }

    // MARK: Flow

    func testOffByDefault() {
        let push = makeModel(baseURL: base)
        XCTAssertTrue(push.isAvailable)
        XCTAssertFalse(push.isEnabled)
        XCTAssertEqual(push.status, .off)
    }

    func testTurningOnRegistersAndUploads() async throws {
        let push = makeModel(baseURL: base)
        await push.setEnabled(true)
        XCTAssertEqual(registerCalls, 1)
        XCTAssertEqual(push.status, .registering)
        await push.didRegister(deviceToken: tokenBytes)
        XCTAssertEqual(push.status, .registered)
        let request = try XCTUnwrap(NotifyStubProtocol.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://notify.example.com/register")
        XCTAssertEqual(NotifyStubProtocol.bodies.first as? [String: String], [
            "token": PushRegistration.hex(tokenBytes), "bundleId": "com.duodash.beta",
            "environment": "production", "appVersion": "1.4",
        ])
        // The same token again (every launch) doesn't re-upload.
        await push.didRegister(deviceToken: tokenBytes)
        XCTAssertEqual(NotifyStubProtocol.requests.count, 1)
    }

    func testPermissionDeniedStaysOff() async {
        authorizationAnswer = false
        let push = makeModel(baseURL: base)
        await push.setEnabled(true)
        XCTAssertFalse(push.isEnabled)
        XCTAssertEqual(push.status, .denied)
        XCTAssertEqual(registerCalls, 0)
        XCTAssertTrue(NotifyStubProtocol.requests.isEmpty)
    }

    func testFailedUploadIsRetriedOnNextLaunch() async {
        NotifyStubProtocol.status = 503
        let push = makeModel(baseURL: base)
        await push.setEnabled(true)
        await push.didRegister(deviceToken: tokenBytes)
        XCTAssertEqual(push.status, .failed)

        // Next launch: a new model with the same saved state.
        NotifyStubProtocol.status = 200
        let relaunched = makeModel(baseURL: base)
        XCTAssertTrue(relaunched.isEnabled, "the choice persists")
        await relaunched.resumeOnLaunch()
        XCTAssertEqual(registerCalls, 2, "asks iOS for the token again")
        await relaunched.didRegister(deviceToken: tokenBytes)
        XCTAssertEqual(relaunched.status, .registered)
        XCTAssertEqual(NotifyStubProtocol.requests.count, 2)
    }

    func testTurningOffUnregisters() async {
        let push = makeModel(baseURL: base)
        await push.setEnabled(true)
        await push.didRegister(deviceToken: tokenBytes)
        await push.setEnabled(false)
        XCTAssertEqual(push.status, .off)
        XCTAssertFalse(defaults.bool(forKey: "notify.enabled"))
        XCTAssertEqual(NotifyStubProtocol.requests.last?.url?.path, "/unregister")
        XCTAssertEqual(NotifyStubProtocol.bodies.last as? [String: String], ["token": PushRegistration.hex(tokenBytes)])
    }

    func testFailedUnregisterIsRetriedOnNextLaunch() async {
        let push = makeModel(baseURL: base)
        await push.setEnabled(true)
        await push.didRegister(deviceToken: tokenBytes)
        NotifyStubProtocol.status = 500
        await push.setEnabled(false)
        NotifyStubProtocol.status = 200
        let relaunched = makeModel(baseURL: base)
        await relaunched.resumeOnLaunch()
        XCTAssertEqual(NotifyStubProtocol.requests.map(\.url?.path), ["/register", "/unregister", "/unregister"])
        XCTAssertEqual(registerCalls, 1, "off: no new token requested")
        await relaunched.resumeOnLaunch()
        XCTAssertEqual(NotifyStubProtocol.requests.count, 3, "done once it succeeded")
    }
}
