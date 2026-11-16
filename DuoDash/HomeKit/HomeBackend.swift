import Foundation

/// What a backend tells the model. Always delivered on the main actor.
enum HomeBackendEvent {
    case authorization(HomeAuthorization)
    /// The full list of homes (on first load and whenever homes, rooms,
    /// accessories or scenes are added, removed or renamed).
    case homes([HomeSnapshot])
    /// One accessory's state or reachability changed.
    case accessory(homeID: String, HomeAccessory)
}

/// Where Home data comes from: HomeKit on a device, or the demo home in the
/// Simulator and tests.
@MainActor
protocol HomeBackend: AnyObject {
    var isDemo: Bool { get }
    var onEvent: (@MainActor (HomeBackendEvent) -> Void)? { get set }

    /// Start loading (on a device this may show the HomeKit permission prompt).
    func start()

    /// Write to one accessory. Returns when the accessory has accepted the
    /// write; state changes follow as `.accessory` events. The model applies its
    /// own timeout, so this may take as long as HomeKit takes.
    func send(_ command: HomeCommand, to accessoryID: String, in homeID: String) async throws

    func runScene(_ sceneID: String, in homeID: String) async throws
}

enum HomeBackendFactory {
    private static var arguments: [String] { ProcessInfo.processInfo.arguments }

    /// The Simulator has no HomeKit accessories; `-DemoHome` asks for the demo on a device.
    static var usesDemo: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return arguments.contains("-DemoHome")
        #endif
    }

    /// HomeKit needs an entitlement that a wildcard (free or default) provisioning profile can't
    /// carry, so it's switched on per build: DUODASH_HOMEKIT = YES (scripts/setup.sh --homekit).
    static var isEnabled: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "DuoDashHomeKit") as? String)?.uppercased() == "YES"
    }

    /// The backend for this run. Demo variants for UI tests:
    /// `-DemoHomeDenied`, `-DemoHomeRestricted`, `-DemoHomeNoHomes`.
    @MainActor
    static func make() -> HomeBackend {
        guard usesDemo else { return isEnabled ? HomeKitBackend() : DisabledHomeBackend() }
        let scenario: DemoHomeBackend.Scenario
        if arguments.contains("-DemoHomeDenied") {
            scenario = .denied
        } else if arguments.contains("-DemoHomeRestricted") {
            scenario = .restricted
        } else if arguments.contains("-DemoHomeNoHomes") {
            scenario = .noHomes
        } else {
            scenario = .standard
        }
        return DemoHomeBackend(scenario: scenario)
    }
}

/// Races `operation` against a timeout. On timeout the operation is cancelled
/// and `HomeError.timedOut` is thrown straight away, even if the operation
/// ignores cancellation (a HomeKit completion that never comes).
@MainActor
func withHomeTimeout(_ timeout: Duration, _ operation: @escaping @MainActor () async throws -> Void) async throws {
    final class Gate {
        var isDone = false
        var timer: Task<Void, Never>?
    }
    let gate = Gate()
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        let work = Task { @MainActor in
            do {
                try await operation()
                guard !gate.isDone else { return }
                gate.isDone = true
                gate.timer?.cancel()
                continuation.resume()
            } catch {
                guard !gate.isDone else { return }
                gate.isDone = true
                gate.timer?.cancel()
                continuation.resume(throwing: error)
            }
        }
        gate.timer = Task { @MainActor in
            try? await Task.sleep(for: timeout)
            guard !gate.isDone, !Task.isCancelled else { return }
            gate.isDone = true
            work.cancel()
            continuation.resume(throwing: HomeError.timedOut)
        }
    }
}

/// Used when the build has no HomeKit entitlement: never touches HomeKit (which would fail
/// without it), and the Home screen explains how to switch it on.
@MainActor
final class DisabledHomeBackend: HomeBackend {
    let isDemo = false
    var onEvent: (@MainActor (HomeBackendEvent) -> Void)?
    func start() {}
    func send(_ command: HomeCommand, to accessoryID: String, in homeID: String) async throws {
        throw HomeError.notResponding
    }
    func runScene(_ sceneID: String, in homeID: String) async throws {
        throw HomeError.notResponding
    }
}
