import SwiftUI
import UIKit
import Contacts
import ContactsUI
import MessageUI

/// The topmost view controller, for presenting Apple's own sheets from SwiftUI.
@MainActor
enum Presenter {
    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.first?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

/// A contact (and one of its numbers) chosen in Apple's contact picker.
struct PickedContact {
    var contactID: String
    var name: String
    var number: LabeledNumber
    var thumbnail: Data?
}

/// Shows `CNContactPickerViewController`, which needs no Contacts permission:
/// iOS only hands back the person the user taps. Contacts with one number are
/// picked straight away; with several, the card opens so the user picks one.
@MainActor
final class ContactPicker: NSObject, CNContactPickerDelegate {
    private static var current: ContactPicker?
    private let onPick: (PickedContact) -> Void

    private init(onPick: @escaping (PickedContact) -> Void) {
        self.onPick = onPick
    }

    static func present(onPick: @escaping (PickedContact) -> Void) {
        guard let top = Presenter.topViewController() else { return }
        let picker = CNContactPickerViewController()
        picker.displayedPropertyKeys = [CNContactPhoneNumbersKey]
        picker.predicateForEnablingContact = NSPredicate(format: "phoneNumbers.@count > 0")
        picker.predicateForSelectionOfContact = NSPredicate(format: "phoneNumbers.@count == 1")
        picker.predicateForSelectionOfProperty = NSPredicate(format: "key == 'phoneNumbers'")
        let delegate = ContactPicker(onPick: onPick)
        current = delegate
        picker.delegate = delegate
        top.present(picker, animated: true)
    }

    nonisolated func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
        let numbers = ContactsStore.numbers(of: contact)
        guard let first = numbers.first else { return }
        let picked = PickedContact(contactID: contact.identifier, name: ContactsStore.displayName(of: contact),
                                   number: first, thumbnail: ContactsStore.thumbnail(of: contact))
        MainActor.assumeIsolated { finish(with: picked) }
    }

    nonisolated func contactPicker(_ picker: CNContactPickerViewController, didSelect contactProperty: CNContactProperty) {
        guard let phone = contactProperty.value as? CNPhoneNumber else { return }
        let contact = contactProperty.contact
        let picked = PickedContact(contactID: contact.identifier, name: ContactsStore.displayName(of: contact),
                                   number: LabeledNumber(label: PhoneNumber.label(contactProperty.label), number: phone.stringValue),
                                   thumbnail: ContactsStore.thumbnail(of: contact))
        MainActor.assumeIsolated { finish(with: picked) }
    }

    nonisolated func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
        MainActor.assumeIsolated { Self.current = nil }
    }

    private func finish(with picked: PickedContact) {
        onPick(picked)
        Self.current = nil
    }
}

/// Shows Apple's message compose sheet, pre-filled. The user still taps Send:
/// third-party apps can't send texts on their own.
@MainActor
final class MessageComposer: NSObject, MFMessageComposeViewControllerDelegate {
    private static var current: MessageComposer?
    private let onResult: (MessageComposeResult) -> Void

    private init(onResult: @escaping (MessageComposeResult) -> Void) {
        self.onResult = onResult
    }

    static var canSendText: Bool { MFMessageComposeViewController.canSendText() }

    /// Returns false (and shows nothing) when this device can't send texts.
    @discardableResult
    static func present(to number: String, body: String, onResult: @escaping (MessageComposeResult) -> Void) -> Bool {
        guard canSendText, let top = Presenter.topViewController() else { return false }
        let compose = MFMessageComposeViewController()
        compose.recipients = [number]
        compose.body = body
        let delegate = MessageComposer(onResult: onResult)
        current = delegate
        compose.messageComposeDelegate = delegate
        top.present(compose, animated: true)
        return true
    }

    nonisolated func messageComposeViewController(_ controller: MFMessageComposeViewController,
                                                  didFinishWith result: MessageComposeResult) {
        MainActor.assumeIsolated {
            controller.dismiss(animated: true)
            onResult(result)
            Self.current = nil
        }
    }
}
