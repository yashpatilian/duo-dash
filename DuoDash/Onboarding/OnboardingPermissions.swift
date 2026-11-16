import SwiftUI
import AVFoundation
import Contacts
import CoreLocation
import Speech

/// The permissions the welcome tour asks for, through the same calls the app already uses.
enum OnboardingPermission: String, CaseIterable, Identifiable {
    case location, contacts, microphone

    var id: String { rawValue }

    enum State { case notDetermined, allowed, denied }

    var title: String {
        switch self {
        case .location: "Location"
        case .contacts: "Contacts"
        case .microphone: "Microphone & Speech"
        }
    }

    var detail: String {
        switch self {
        case .location: "Your place on the map and turn-by-turn directions."
        case .contacts: "Call and text your favourites with one tap."
        case .microphone: "Talk to the assistant and dictate searches and texts."
        }
    }

    var symbol: String {
        switch self {
        case .location: "location.fill"
        case .contacts: "person.crop.circle.fill"
        case .microphone: "mic.fill"
        }
    }

    var tint: Color {
        switch self {
        case .location: Theme.accent
        case .contacts: Color(white: 0.5)
        case .microphone: Color(red: 0.98, green: 0.30, blue: 0.45)
        }
    }

    @MainActor
    func state(location: LocationManager, contacts: ContactsStore) -> State {
        switch self {
        case .location:
            switch location.authorization {
            case .notDetermined: return .notDetermined
            case .authorizedAlways, .authorizedWhenInUse: return .allowed
            default: return .denied
            }
        case .contacts:
            if contacts.isSeeded { return .allowed }
            switch CNContactStore.authorizationStatus(for: .contacts) {
            case .notDetermined: return .notDetermined
            case .authorized, .limited: return .allowed
            default: return .denied
            }
        case .microphone:
            let mic = AVAudioApplication.shared.recordPermission
            let speech = SFSpeechRecognizer.authorizationStatus()
            if mic == .undetermined || speech == .notDetermined { return .notDetermined }
            return mic == .granted && speech == .authorized ? .allowed : .denied
        }
    }

    /// Asks, using the app's existing request paths.
    @MainActor
    func request(location: LocationManager, contacts: ContactsStore) async {
        switch self {
        case .location: location.start()
        case .contacts: await contacts.prepareDirectory()
        case .microphone: _ = await AppleRecognizerEngine.authorize()
        }
    }
}
