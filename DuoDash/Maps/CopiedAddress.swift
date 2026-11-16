import SwiftUI
import UIKit
import MapKit

/// Notices when an address has been copied (e.g. from Messages or Messenger) and
/// offers to navigate there. iOS doesn't let apps read other apps' messages, but
/// it does let us *detect* that the clipboard holds an address without reading it,
/// and Apple's PasteButton hands it over with no "Allow Paste" prompt.
@MainActor
@Observable
final class CopiedAddressWatcher {
    /// True while the clipboard holds an address the user hasn't dismissed.
    private(set) var hasAddress = false

    @ObservationIgnored private var dismissedChangeCount = -1
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        for name in [UIPasteboard.changedNotification, UIApplication.didBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        refresh()
    }

    func refresh() {
        let board = UIPasteboard.general
        let count = board.changeCount
        guard board.hasStrings, count != dismissedChangeCount else { hasAddress = false; return }
        Task {
            // Pattern detection doesn't read the text, so it never triggers the paste prompt.
            let patterns = (try? await board.detectedPatterns(for: [\.postalAddresses])) ?? []
            hasAddress = !patterns.isEmpty && board.changeCount == count && count != dismissedChangeCount
        }
    }

    func dismiss() {
        dismissedChangeCount = UIPasteboard.general.changeCount
        hasAddress = false
    }
}

/// "Copied address → Navigate" banner at the top of the Maps search panel.
struct CopiedAddressBanner: View {
    @Environment(CopiedAddressWatcher.self) private var watcher
    /// Receives the pasted address text.
    let onAddress: (String) -> Void

    var body: some View {
        if watcher.hasAddress {
            HStack(spacing: 12) {
                Image(systemName: "doc.on.clipboard.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Copied address").font(.dashBody)
                    Text("Navigate to the address you copied").font(.dashCaption).foregroundStyle(Theme.textSecondary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
                Spacer(minLength: 4)
                PasteButton(payloadType: String.self) { strings in
                    guard let text = strings.first?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
                    Task { @MainActor in
                        watcher.dismiss()
                        onAddress(text)
                    }
                }
                .buttonBorderShape(.capsule)
                .labelStyle(.titleAndIcon)
                .tint(Theme.accent)
                .controlSize(.large)
                .accessibilityIdentifier("maps.copiedAddress.paste")
                Button { watcher.dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 48, height: Theme.minTouch)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss copied address")
            }
            .padding(.leading, 14)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityIdentifier("maps.copiedAddress")
        }
    }
}
