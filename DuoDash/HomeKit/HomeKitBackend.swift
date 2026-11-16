import Foundation
import HomeKit

/// HomeKit on a real device. Turns `HMHome`s into `HomeSnapshot`s, keeps them
/// current through the home manager, home and accessory delegates, and writes
/// characteristics. Needs the `com.apple.developer.homekit` entitlement and
/// `NSHomeKitUsageDescription`.
///
/// HomeKit calls delegates on the main queue, but the callbacks are declared
/// nonisolated, so each one hops to the main actor and only passes identifiers.
@MainActor
final class HomeKitBackend: NSObject, HomeBackend {
    let isDemo = false
    var onEvent: (@MainActor (HomeBackendEvent) -> Void)?

    private var manager: HMHomeManager?
    /// Characteristics we've asked to be notified about (by characteristic id).
    private var subscribed = Set<UUID>()

    func start() {
        guard manager == nil else { return }
        // Creating the manager shows the permission prompt the first time.
        let manager = HMHomeManager()
        manager.delegate = self
        self.manager = manager
        onEvent?(.authorization(Self.authorization(from: manager.authorizationStatus)))
    }

    /// `HMHomeManagerAuthorizationStatus` → what the screen shows.
    nonisolated static func authorization(from status: HMHomeManagerAuthorizationStatus) -> HomeAuthorization {
        if status.contains(.authorized) { return .authorized }
        if status.contains(.restricted) { return .restricted }
        if status.contains(.determined) { return .denied }
        return .notDetermined
    }

    // MARK: Snapshots

    private func publishHomes() {
        guard let manager else { return }
        let status = Self.authorization(from: manager.authorizationStatus)
        guard status == .authorized else {
            onEvent?(.authorization(status))
            return
        }
        for home in manager.homes {
            home.delegate = self
            for accessory in home.accessories {
                accessory.delegate = self
                subscribe(accessory)
            }
        }
        onEvent?(.homes(manager.homes.map(snapshot(of:))))
    }

    private func snapshot(of home: HMHome) -> HomeSnapshot {
        let accessories = home.accessories.flatMap { accessory in
            accessory.services.compactMap { Self.accessory(from: $0, in: accessory) }
        }
        let scenes = home.actionSets
            .filter { $0.actionSetType != HMActionSetTypeTriggerOwned }
            .map { set in
                HomeScene(id: set.uniqueIdentifier.uuidString, name: set.name,
                          kind: HomeStateMapping.sceneKind(actionSetType: set.actionSetType),
                          touchesLocks: set.actions.contains { action in
                              (action as? HMCharacteristicWriteAction<NSCopying>)?.characteristic.service?.serviceType
                                  == HMServiceTypeLockMechanism
                          })
            }
        return HomeSnapshot(id: home.uniqueIdentifier.uuidString, name: home.name,
                            isPrimary: home.isPrimary, accessories: accessories, scenes: scenes)
    }

    private static func kind(of service: HMService, in accessory: HMAccessory) -> HomeAccessoryKind? {
        switch service.serviceType {
        case HMServiceTypeGarageDoorOpener:
            // HomeKit has no gate service; gates are garage door openers named as such.
            let name = "\(service.name) \(accessory.name)".lowercased()
            return name.contains("gate") ? .gate : .garageDoor
        case HMServiceTypeLockMechanism: return .lock
        case HMServiceTypeLightbulb: return .light
        case HMServiceTypeSwitch: return .switchPower
        case HMServiceTypeOutlet: return .outlet
        default: return nil
        }
    }

    private static func accessory(from service: HMService, in accessory: HMAccessory) -> HomeAccessory? {
        guard let kind = kind(of: service, in: accessory) else { return nil }
        func value(_ type: String) -> Any? {
            service.characteristics.first { $0.characteristicType == type }?.value
        }
        let state: HomeAccessoryState
        switch kind {
        case .garageDoor, .gate:
            state = HomeStateMapping.door(
                current: HomeStateMapping.int(value(HMCharacteristicTypeCurrentDoorState)),
                target: HomeStateMapping.int(value(HMCharacteristicTypeTargetDoorState)),
                obstructed: HomeStateMapping.bool(value(HMCharacteristicTypeObstructionDetected)))
        case .lock:
            state = HomeStateMapping.lock(
                current: HomeStateMapping.int(value(HMCharacteristicTypeCurrentLockMechanismState)),
                target: HomeStateMapping.int(value(HMCharacteristicTypeTargetLockMechanismState)))
        case .light, .switchPower, .outlet:
            state = HomeStateMapping.power(value(HMCharacteristicTypePowerState))
        }
        // A one-service accessory is named by the accessory; a multi-service one by each service.
        let name = accessory.services.count(where: { Self.kind(of: $0, in: accessory) != nil }) > 1
            ? service.name : accessory.name
        return HomeAccessory(id: service.uniqueIdentifier.uuidString, name: name, room: accessory.room?.name,
                             kind: kind, state: state, isReachable: accessory.isReachable)
    }

    private static let watchedTypes: Set<String> = [
        HMCharacteristicTypeCurrentDoorState, HMCharacteristicTypeTargetDoorState,
        HMCharacteristicTypeObstructionDetected, HMCharacteristicTypeCurrentLockMechanismState,
        HMCharacteristicTypeTargetLockMechanismState, HMCharacteristicTypePowerState,
    ]

    /// Read the current values once and ask for change notifications.
    private func subscribe(_ accessory: HMAccessory) {
        let accessoryID = accessory.uniqueIdentifier
        for service in accessory.services where Self.kind(of: service, in: accessory) != nil {
            for characteristic in service.characteristics where Self.watchedTypes.contains(characteristic.characteristicType) {
                guard !subscribed.contains(characteristic.uniqueIdentifier) else { continue }
                subscribed.insert(characteristic.uniqueIdentifier)
                characteristic.readValue { [weak self] _ in
                    Task { @MainActor in self?.accessoryChanged(accessoryID) }
                }
                if characteristic.properties.contains(HMCharacteristicPropertySupportsEventNotification) {
                    characteristic.enableNotification(true) { _ in }
                }
            }
        }
    }

    /// Re-publish one accessory's services from HomeKit's cached values.
    private func accessoryChanged(_ accessoryID: UUID) {
        guard let manager else { return }
        for home in manager.homes {
            guard let accessory = home.accessories.first(where: { $0.uniqueIdentifier == accessoryID }) else { continue }
            let homeID = home.uniqueIdentifier.uuidString
            for service in accessory.services {
                if let item = Self.accessory(from: service, in: accessory) {
                    onEvent?(.accessory(homeID: homeID, item))
                }
            }
        }
    }

    // MARK: Writes

    private func find(service id: String, in homeID: String) -> (HMService, HMAccessory)? {
        guard let home = manager?.homes.first(where: { $0.uniqueIdentifier.uuidString == homeID }) else { return nil }
        for accessory in home.accessories {
            if let service = accessory.services.first(where: { $0.uniqueIdentifier.uuidString == id }) {
                return (service, accessory)
            }
        }
        return nil
    }

    func send(_ command: HomeCommand, to accessoryID: String, in homeID: String) async throws {
        guard let (service, accessory) = find(service: accessoryID, in: homeID) else { throw HomeError.notFound }
        guard accessory.isReachable else { throw HomeError.notResponding }
        let type: String
        switch command {
        case .setDoor: type = HMCharacteristicTypeTargetDoorState
        case .setLock: type = HMCharacteristicTypeTargetLockMechanismState
        case .setPower: type = HMCharacteristicTypePowerState
        }
        guard let characteristic = service.characteristics.first(where: { $0.characteristicType == type }) else {
            throw HomeError.notFound
        }
        let value = NSNumber(value: HomeStateMapping.value(for: command))
        let error: Error? = await withCheckedContinuation { continuation in
            characteristic.writeValue(value) { continuation.resume(returning: $0) }
        }
        if let error { throw Self.map(error) }
    }

    func runScene(_ sceneID: String, in homeID: String) async throws {
        guard let home = manager?.homes.first(where: { $0.uniqueIdentifier.uuidString == homeID }),
              let set = home.actionSets.first(where: { $0.uniqueIdentifier.uuidString == sceneID }) else {
            throw HomeError.notFound
        }
        let error: Error? = await withCheckedContinuation { continuation in
            home.executeActionSet(set) { continuation.resume(returning: $0) }
        }
        if let error { throw Self.map(error) }
    }

    static func map(_ error: Error) -> HomeError {
        let nsError = error as NSError
        guard nsError.domain == HMErrorDomain else { return .failed(nsError.localizedDescription) }
        switch HMError.Code(rawValue: nsError.code) {
        case .accessoryNotReachable, .bridgedAccessoryNotReachable, .communicationFailure,
             .accessoryCommunicationFailure, .partialCommunicationFailure:
            return .notResponding
        case .operationTimedOut, .timedOutWaitingForAccessory:
            return .timedOut
        default:
            return .failed(nsError.localizedDescription)
        }
    }
}

// MARK: Delegates

extension HomeKitBackend: HMHomeManagerDelegate {
    nonisolated func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        Task { @MainActor in self.publishHomes() }
    }

    nonisolated func homeManagerDidUpdatePrimaryHome(_ manager: HMHomeManager) {
        Task { @MainActor in self.publishHomes() }
    }

    nonisolated func homeManager(_ manager: HMHomeManager, didAdd home: HMHome) {
        Task { @MainActor in self.publishHomes() }
    }

    nonisolated func homeManager(_ manager: HMHomeManager, didRemove home: HMHome) {
        Task { @MainActor in self.publishHomes() }
    }

    nonisolated func homeManager(_ manager: HMHomeManager, didUpdate status: HMHomeManagerAuthorizationStatus) {
        let authorization = Self.authorization(from: status)
        Task { @MainActor in
            self.onEvent?(.authorization(authorization))
            if authorization == .authorized { self.publishHomes() }
        }
    }
}

extension HomeKitBackend: HMHomeDelegate {
    nonisolated func homeDidUpdateName(_ home: HMHome) { Task { @MainActor in self.publishHomes() } }
    nonisolated func home(_ home: HMHome, didAdd accessory: HMAccessory) { Task { @MainActor in self.publishHomes() } }
    nonisolated func home(_ home: HMHome, didRemove accessory: HMAccessory) { Task { @MainActor in self.publishHomes() } }
    nonisolated func home(_ home: HMHome, didAdd actionSet: HMActionSet) { Task { @MainActor in self.publishHomes() } }
    nonisolated func home(_ home: HMHome, didRemove actionSet: HMActionSet) { Task { @MainActor in self.publishHomes() } }
    nonisolated func home(_ home: HMHome, didUpdateNameFor actionSet: HMActionSet) { Task { @MainActor in self.publishHomes() } }
    nonisolated func home(_ home: HMHome, didUpdate room: HMRoom, for accessory: HMAccessory) {
        Task { @MainActor in self.publishHomes() }
    }
}

extension HomeKitBackend: HMAccessoryDelegate {
    nonisolated func accessory(_ accessory: HMAccessory, service: HMService, didUpdateValueFor characteristic: HMCharacteristic) {
        let id = accessory.uniqueIdentifier
        Task { @MainActor in self.accessoryChanged(id) }
    }

    nonisolated func accessoryDidUpdateReachability(_ accessory: HMAccessory) {
        let id = accessory.uniqueIdentifier
        Task { @MainActor in self.accessoryChanged(id) }
    }

    nonisolated func accessoryDidUpdateName(_ accessory: HMAccessory) {
        Task { @MainActor in self.publishHomes() }
    }

    nonisolated func accessory(_ accessory: HMAccessory, didUpdateNameFor service: HMService) {
        Task { @MainActor in self.publishHomes() }
    }

    nonisolated func accessoryDidUpdateServices(_ accessory: HMAccessory) {
        Task { @MainActor in self.publishHomes() }
    }
}
