import SwiftUI
import UIKit

/// Settings → Spotify: the connection, Sign Out, and (advanced) "Use my own Spotify developer
/// app", which walks through making one and takes its Client ID. With your own app you get the
/// full sign-in-once mode and aren't limited by Duo Dash's shared app's allow-list.
struct SpotifySettingsSection: View {
    @Environment(SpotifyModel.self) private var spotify
    @Environment(\.openURL) private var openURL
    @State private var clientIDText = ""
    @State private var showsOwnApp = false
    @State private var confirmingSignOut = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            connection
            ownApp
        }
        .confirmationDialog("Sign out of Spotify?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { spotify.signOut() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Duo Dash forgets your Spotify sign-in on this phone.")
        }
    }

    // MARK: Connection

    private var connection: some View {
        group(footer: modeFooter) {
            row(title: "Status", value: statusText, id: "settings.spotify.status")
            divider
            row(title: "Connects", value: spotify.mode == .signInOnce ? "Sign in once" : "Through the Spotify app",
                id: "settings.spotify.mode")
            if spotify.isSignedIn || spotify.status == .connected {
                divider
                button("Sign Out", id: "settings.spotify.signout", destructive: true) { confirmingSignOut = true }
            }
            if spotify.status == .limited {
                divider
                button("Open Spotify", id: "settings.spotify.open") { openURL(SpotifyModel.spotifyAppURL) }
            }
        }
    }

    private var statusText: String {
        switch spotify.status {
        case .notConfigured: "No Client ID in this build"
        case .notInstalled: "Spotify app not installed"
        case .notConnected: spotify.isSignedIn ? "Signed in, not connected" : "Not connected"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .disconnected: "Disconnected"
        case .limited: "Limited: open Spotify instead"
        }
    }

    private var modeFooter: String {
        switch spotify.mode {
        case .signInOnce:
            "You sign in once; Duo Dash renews the sign-in by itself."
        case .appRemoteOnly:
            "Duo Dash controls the Spotify app directly. When its access runs out, Spotify opens for a moment to renew it."
        }
    }

    // MARK: Own developer app

    private var ownApp: some View {
        group(footer: "For people who build Duo Dash themselves or want full control: your own free Spotify developer app (needs a computer and Spotify Premium). Its Client ID is stored on this phone only.") {
            if let own = spotify.ownClientID {
                row(title: "Using your developer app", value: "…" + own.suffix(6), id: "settings.spotify.ownID")
                divider
                button(SpotifyConfig.clientID() == nil ? "Remove My Client ID" : "Use Duo Dash's Spotify App",
                       id: "settings.spotify.ownID.remove", destructive: true) {
                    spotify.useOwnClientID(nil)
                }
            } else {
                button(showsOwnApp ? "Hide Steps" : "Use My Own Spotify Developer App", id: "settings.spotify.ownApp") {
                    withAnimation(.snappy) { showsOwnApp.toggle() }
                }
                if showsOwnApp {
                    divider
                    steps
                    divider
                    clientIDField
                }
            }
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(SpotifyWalkthrough.steps.enumerated()), id: \.offset) { index, step in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(index + 1). \(step.title)").font(.dashBody)
                    Text(step.message).font(.dashCaption.weight(.regular)).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("This app's bundle ID: \(SpotifyWalkthrough.bundleID)")
                .font(.dashCaption.monospaced())
                .textSelection(.enabled)
            Link(destination: SpotifyGuide.url) {
                Label("Full guide: SPOTIFY_SETUP.md", systemImage: "link")
                    .font(.dashCaption)
                    .frame(minHeight: Theme.minTouch, alignment: .leading)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .accessibilityIdentifier("settings.spotify.steps")
    }

    private var clientIDField: some View {
        let valid = SpotifyAccessSettings.normalisedClientID(clientIDText)
        return HStack(spacing: 10) {
            TextField("Client ID (32 characters)", text: $clientIDText)
                .font(.dashBody.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("settings.spotify.clientID")
            DictationButton(text: $clientIDText, identifier: "settings.spotify.clientID.dictate")
            DashPillButton(title: "Use", prominent: valid != nil, identifier: "settings.spotify.clientID.save") {
                guard let valid else { return }
                spotify.useOwnClientID(valid)
                clientIDText = ""
                showsOwnApp = false
            }
            .disabled(valid == nil)
        }
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .frame(minHeight: Theme.minTouch + 2)
    }

    // MARK: Building blocks (drawn like the other Settings groups)

    private func group<Content: View>(footer: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 0) { content() }
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: SettingsStyle.corner, style: .continuous))
            Text(footer)
                .font(.dashCaption.weight(.regular))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 18)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var divider: some View {
        Theme.separator.frame(height: 0.5).padding(.leading, 18)
    }

    private func row(title: String, value: String, id: String) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.dashBody.weight(.regular))
            Spacer(minLength: 8)
            Text(value).font(.dashCaption.weight(.regular)).foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.trailing)
                .accessibilityIdentifier(id)
        }
        .padding(.horizontal, 18)
        .frame(minHeight: Theme.minTouch + 2)
    }

    private func button(_ title: String, id: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.dashBody.weight(.regular))
                .foregroundStyle(destructive ? Theme.warning : Theme.accent)
                .frame(maxWidth: .infinity, minHeight: Theme.minTouch + 2, alignment: .leading)
                .padding(.horizontal, 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}
