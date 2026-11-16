import SwiftUI
import CoreImage.CIFilterBuiltins

// Illustrations for the welcome tour, drawn in SwiftUI from the app's own components
// (AppTile, Theme) and SF Symbols. Each one is laid out at a fixed design size and
// scaled to whatever space the page gives it, so nothing clips on any window.

/// Lays `content` out at `design` size and scales it to fit the space offered.
struct FittedArt<Content: View>: View {
    var design = CGSize(width: 360, height: 260)
    var maxScale: CGFloat = 1.7
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { proxy in
            let scale = max(0.1, min(proxy.size.width / design.width, proxy.size.height / design.height, maxScale))
            content
                .frame(width: design.width, height: design.height)
                .scaleEffect(scale)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Mini dashboard (welcome, dock tour)

/// A small Duo Dash screen: map with a route, a widget and the dock on the right.
struct MiniDashboard: View {
    var highlightDock = false
    var dockItems: [DockItem] = [.maps, .music, .phone, .messages, .weather]

    var body: some View {
        HStack(spacing: 6) {
            VStack(spacing: 6) {
                MiniMap()
                HStack(spacing: 6) {
                    miniCard(symbol: "music.note", tint: Color(red: 0.96, green: 0.2, blue: 0.33))
                    miniCard(symbol: "cloud.sun.fill", tint: Theme.accent)
                }
                .frame(height: 54)
            }
            VStack(spacing: 7) {
                Text("9:41").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                ForEach(dockItems) { item in AppTile(item: item, size: 34) }
                Spacer(minLength: 0)
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .padding(.vertical, 8)
            .frame(width: 50)
            .background(Theme.chrome, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                if highlightDock {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.accent, lineWidth: 2.5)
                }
            }
        }
        .padding(8)
        .background(Color.black, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1.5) }
    }

    private func miniCard(symbol: String, tint: Color) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Theme.surface)
            .overlay(alignment: .leading) {
                HStack(spacing: 6) {
                    Image(systemName: symbol).font(.system(size: 14, weight: .bold)).foregroundStyle(tint)
                    VStack(alignment: .leading, spacing: 4) {
                        Capsule().fill(Color.white.opacity(0.7)).frame(width: 46, height: 5)
                        Capsule().fill(Color.white.opacity(0.3)).frame(width: 30, height: 5)
                    }
                }
                .padding(.leading, 10)
            }
    }
}

/// A stylised map tile with a blue route.
struct MiniMap: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(red: 0.13, green: 0.15, blue: 0.17))
            .overlay {
                GeometryReader { proxy in
                    let w = proxy.size.width, h = proxy.size.height
                    ZStack {
                        // Streets.
                        Path { p in
                            p.move(to: CGPoint(x: 0, y: h * 0.3)); p.addLine(to: CGPoint(x: w, y: h * 0.22))
                            p.move(to: CGPoint(x: 0, y: h * 0.75)); p.addLine(to: CGPoint(x: w, y: h * 0.82))
                            p.move(to: CGPoint(x: w * 0.3, y: 0)); p.addLine(to: CGPoint(x: w * 0.36, y: h))
                            p.move(to: CGPoint(x: w * 0.72, y: 0)); p.addLine(to: CGPoint(x: w * 0.66, y: h))
                        }
                        .stroke(Color.white.opacity(0.12), lineWidth: 5)
                        // Park.
                        RoundedRectangle(cornerRadius: 8).fill(Color(red: 0.16, green: 0.3, blue: 0.2))
                            .frame(width: w * 0.22, height: h * 0.28).position(x: w * 0.52, y: h * 0.5)
                        // Route.
                        Path { p in
                            p.move(to: CGPoint(x: w * 0.12, y: h * 0.78))
                            p.addLine(to: CGPoint(x: w * 0.35, y: h * 0.76))
                            p.addLine(to: CGPoint(x: w * 0.32, y: h * 0.27))
                            p.addLine(to: CGPoint(x: w * 0.82, y: h * 0.2))
                        }
                        .stroke(Theme.route, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                        Circle().fill(Theme.route).frame(width: 14, height: 14)
                            .overlay { Circle().strokeBorder(.white, lineWidth: 2.5) }
                            .position(x: w * 0.12, y: h * 0.78)
                        Image(systemName: "mappin.circle.fill")
                            .font(.system(size: 20)).foregroundStyle(.white, Theme.danger)
                            .position(x: w * 0.82, y: h * 0.2)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Music choice

struct MusicChoiceArt: View {
    var body: some View {
        HStack(spacing: 22) {
            AppTile(item: .music, size: 96)
            Image(systemName: "plus").font(.system(size: 28, weight: .bold)).foregroundStyle(Theme.textSecondary)
            AppTile(item: .spotify, size: 96)
        }
        .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
    }
}

// MARK: - Tour

/// The dock: scrolls, hold to reorder, and the Dashboard / app grid button at the bottom.
struct DockTourArt: View {
    var body: some View {
        HStack(spacing: 18) {
            VStack(alignment: .trailing, spacing: 16) {
                callout("arrow.up.and.down", "Scrolls")
                callout("hand.tap.fill", "Hold to reorder")
                Spacer(minLength: 0)
                callout("square.grid.2x2.fill", "Dashboard / apps")
            }
            .padding(.vertical, 22)
            VStack(spacing: 9) {
                Text("9:41").font(.system(size: 14, weight: .semibold)).monospacedDigit()
                AppTile(item: .maps, size: 44)
                AppTile(item: .music, size: 44)
                    .scaleEffect(1.15)
                    .shadow(color: .black.opacity(0.6), radius: 8, y: 4)
                    .offset(x: -10)
                AppTile(item: .phone, size: 44)
                AppTile(item: .messages, size: 44).opacity(0.45)
                Spacer(minLength: 0)
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .padding(.vertical, 10)
            .frame(width: 66)
            .background(Theme.chrome, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.accent, lineWidth: 2.5) }
        }
    }

    private func callout(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 8) {
            Text(text).font(.system(size: 16, weight: .semibold))
            Image(systemName: symbol).font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.accent)
                .frame(width: 28)
        }
    }
}

/// Maps with the assistant's sparkle button and a spoken request.
struct AssistantTourArt: View {
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            MiniMap()
            Image(systemName: "sparkles")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 60, height: 60)
                .background(Color(red: 0.55, green: 0.36, blue: 0.96), in: Circle())
                .overlay { Circle().strokeBorder(Color.white.opacity(0.5), lineWidth: 2) }
                .padding(14)
        }
        .overlay(alignment: .topLeading) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "waveform").font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.accent)
                Text("“Take me to Sam's, stop for petrol on the way”")
                    .font(.system(size: 17, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(width: 214, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.12)) }
            .padding(12)
        }
    }
}

/// Favourite contacts and the add-from-Contacts button.
struct FavouritesTourArt: View {
    private let people: [(String, Color)] = [
        ("SM", Color(red: 0.36, green: 0.55, blue: 0.98)),
        ("AJ", Color(red: 0.98, green: 0.55, blue: 0.25)),
        ("Mum", Color(red: 0.62, green: 0.4, blue: 0.95)),
    ]

    var body: some View {
        VStack(spacing: 20) {
            HStack(spacing: 18) {
                AppTile(item: .phone, size: 56)
                AppTile(item: .messages, size: 56)
            }
            HStack(spacing: 14) {
                ForEach(people, id: \.0) { initials, colour in
                    VStack(spacing: 6) {
                        Text(initials).font(.system(size: 20, weight: .bold))
                            .frame(width: 66, height: 66)
                            .background(colour.gradient, in: Circle())
                        Capsule().fill(Color.white.opacity(0.5)).frame(width: 40, height: 5)
                    }
                }
                VStack(spacing: 6) {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 66, height: 66)
                        .background(Theme.surfaceRaised, in: Circle())
                        .overlay { Circle().strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [5, 4])) }
                    Text("Contacts").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                }
            }
        }
    }
}

/// A few Settings rows.
struct SettingsTourArt: View {
    private let rows: [(String, String, Color)] = [
        ("sparkles", "AI Assistant", Color(red: 0.55, green: 0.36, blue: 0.96)),
        ("waveform", "Voice & Dictation", Color(red: 0.98, green: 0.30, blue: 0.45)),
        ("mappin.and.ellipse", "Saved Places", Theme.danger),
        ("square.grid.2x2.fill", "Dock", Color(white: 0.45)),
        ("info.circle.fill", "About", Color(white: 0.45)),
    ]

    var body: some View {
        VStack(spacing: 6) {
            ForEach(rows, id: \.1) { symbol, title, tint in
                HStack(spacing: 12) {
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(tint, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Text(title).font(.system(size: 17, weight: .semibold))
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                }
                .padding(.horizontal, 12)
                .frame(height: 42)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .frame(width: 290)
    }
}

/// Four things Duo Dash does that the car's own phone screen doesn't.
struct WhatsNewArt: View {
    static let items: [(symbol: String, title: String, detail: String, tint: Color)] = [
        ("sparkles", "Assistant", "Plans stops on the way", Color(red: 0.55, green: 0.36, blue: 0.96)),
        ("video.fill", "Dashcam", "Records the road ahead", Theme.danger),
        ("car.fill", "Car data", "Live OBD-II gauges", Theme.warning),
        ("cloud.sun.fill", "Weather", "Here and where you're going", Theme.accent),
    ]

    var body: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow { tile(Self.items[0]); tile(Self.items[1]) }
            GridRow { tile(Self.items[2]); tile(Self.items[3]) }
        }
    }

    private func tile(_ item: (symbol: String, title: String, detail: String, tint: Color)) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: item.symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(item.tint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(item.title).font(.system(size: 17, weight: .bold))
            Text(item.detail).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textSecondary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(width: 170, height: 118, alignment: .topLeading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Spotify developer dashboard mocks

/// A browser window showing a stylised Spotify developer dashboard (no Spotify artwork).
struct DashboardMock<Content: View>: View {
    var address = "developer.spotify.com/dashboard"
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0.opacity(0.8)).frame(width: 9, height: 9) }
                HStack(spacing: 5) {
                    Image(systemName: "lock.fill").font(.system(size: 9))
                    Text(address).font(.system(size: 11, weight: .medium)).lineLimit(1)
                }
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 22)
                .background(Color.white.opacity(0.08), in: Capsule())
                .padding(.leading, 6)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(Color(white: 0.16))
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(white: 0.07))
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.15)) }
    }
}

private let mockGreen = Color(red: 0.12, green: 0.84, blue: 0.38)

/// A labelled input field in the mock dashboard.
struct MockField: View {
    let label: String
    var value = ""
    var placeholder = ""
    var highlighted = false
    var monospaced = false
    var trailing: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.textSecondary)
            HStack(spacing: 6) {
                Text(value.isEmpty ? placeholder : value)
                    .font(.system(size: 13, weight: .medium, design: monospaced ? .monospaced : .default))
                    .foregroundStyle(value.isEmpty ? Theme.textSecondary.opacity(0.6) : Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Spacer(minLength: 0)
                if let trailing {
                    Text(trailing).font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 10).frame(height: 22)
                        .background(Color.white.opacity(0.14), in: Capsule())
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(highlighted ? mockGreen : Color.white.opacity(0.18), lineWidth: highlighted ? 2 : 1)
            }
        }
    }
}

/// A pill button in the mock dashboard; highlighted ones glow.
struct MockButton: View {
    let title: String
    var highlighted = true
    var filled = true

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(filled ? Color.black : Theme.textPrimary)
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background(filled ? mockGreen : Color.white.opacity(0.12), in: Capsule())
            .overlay { if highlighted { Capsule().strokeBorder(.white, lineWidth: 2).padding(-4) } }
            .shadow(color: highlighted ? mockGreen.opacity(0.7) : .clear, radius: 8)
    }
}

struct MockCheckbox: View {
    let label: String
    var checked = true

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .font(.system(size: 16))
                .foregroundStyle(checked ? mockGreen : Theme.textSecondary)
            Text(label).font(.system(size: 13, weight: .medium))
        }
    }
}

/// The illustration for one step of the Spotify walkthrough (follows docs/SPOTIFY_SETUP.md).
struct SpotifyStepArt: View {
    let step: Int
    let bundleID: String

    var body: some View {
        DashboardMock(address: address) {
            switch step {
            case 1:
                Text("Spotify for Developers").font(.system(size: 18, weight: .bold))
                MockField(label: "Email or username", value: "you@example.com")
                MockField(label: "Password", value: "••••••••••")
                HStack { Spacer(); MockButton(title: "Log in") }
                MockCheckbox(label: "I accept the Developer Terms")
            case 2:
                HStack {
                    Text("Dashboard").font(.system(size: 18, weight: .bold))
                    Spacer()
                    MockButton(title: "Create app")
                }
                MockField(label: "App name", value: "Duo Dash")
                MockField(label: "App description", value: "Personal car dashboard")
                MockField(label: "Website", placeholder: "Leave blank")
            case 3:
                Text("Create app").font(.system(size: 18, weight: .bold))
                MockField(label: "App name", value: "Duo Dash")
                MockField(label: "Redirect URI", value: "duodash://spotify-callback", highlighted: true, monospaced: true, trailing: "Add")
                Text("Type it exactly, no slash at the end").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            case 4:
                Text("Which API/SDKs are you planning to use?").font(.system(size: 14, weight: .bold))
                HStack(spacing: 18) {
                    MockCheckbox(label: "iOS")
                    MockCheckbox(label: "Web API")
                    MockCheckbox(label: "Android", checked: false)
                }
                MockCheckbox(label: "I understand and agree to the terms")
                Spacer(minLength: 0)
                HStack { Spacer(); MockButton(title: "Save") }
            case 5:
                tabs(selected: "Basic Information", title: "Settings · Edit")
                MockField(label: "iOS app bundles", value: bundleID, highlighted: true, monospaced: true, trailing: "Add")
                MockField(label: "Redirect URIs", value: "duodash://spotify-callback", monospaced: true)
                HStack { Spacer(); MockButton(title: "Save") }
            case 6:
                tabs(selected: "User Management", title: "Settings")
                MockField(label: "Full name", value: "Your name")
                MockField(label: "Email", value: "your Spotify account email", highlighted: true)
                HStack { Spacer(); MockButton(title: "Add user") }
            default:
                tabs(selected: "Basic Information", title: "Settings")
                MockField(label: "Client ID", value: "3f9a…c21e  (32 characters)", highlighted: true, monospaced: true, trailing: "Copy")
                MockField(label: "Client secret", value: "Not needed: never share it")
                    .opacity(0.45)
            }
        }
        .frame(width: 340, height: 250)
    }

    private var address: String {
        step >= 5 ? "developer.spotify.com/dashboard/app" : "developer.spotify.com/dashboard"
    }

    private func tabs(selected: String, title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Duo Dash · \(title)").font(.system(size: 16, weight: .bold))
            HStack(spacing: 6) {
                ForEach(["Basic Information", "User Management"], id: \.self) { tab in
                    Text(tab).font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 9).frame(height: 22)
                        .foregroundStyle(tab == selected ? Color.black : Theme.textPrimary)
                        .background(tab == selected ? Color.white : Color.white.opacity(0.1), in: Capsule())
                }
            }
        }
    }
}

/// The Spotify intro: a free developer app made on a computer gives the Client ID for the phone.
struct SpotifyIntroArt: View {
    var body: some View {
        HStack(spacing: 18) {
            VStack(spacing: 8) {
                Image(systemName: "laptopcomputer").font(.system(size: 64, weight: .light))
                Text("Developer app").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textSecondary)
            }
            VStack(spacing: 6) {
                Image(systemName: "key.fill").font(.system(size: 22, weight: .bold)).foregroundStyle(mockGreen)
                Image(systemName: "arrow.right").font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.textSecondary)
                Text("Client ID").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.textSecondary)
            }
            VStack(spacing: 8) {
                Image(systemName: "iphone").font(.system(size: 64, weight: .light))
                Text("This phone").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

// MARK: - QR code

enum QRCode {
    /// A crisp black-on-white QR code for `string`.
    static func image(for string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

/// The QR code for the Spotify guide, on a white card with the link under it.
struct GuideQRCard: View {
    var body: some View {
        VStack(spacing: 10) {
            if let image = QRCode.image(for: SpotifyGuide.url.absoluteString) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 170, height: 170)
                    .padding(12)
                    .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .accessibilityLabel("QR code for the Spotify setup guide")
                    .accessibilityIdentifier("onboarding.spotify.qr")
            }
            Text("Scan for the full guide").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textSecondary)
        }
    }
}

// MARK: - Duo Dock

/// The Duo Dock car mount, stylised: an unfolded phone held level across both halves by a
/// cradle on a ball joint, on a vent clip. Not a drawing of any real phone's bezels.
struct DuoDockIllustration: View {
    var body: some View {
        ZStack {
            // Soft floor glow.
            Ellipse()
                .fill(RadialGradient(colors: [Theme.accent.opacity(0.35), .clear], center: .center, startRadius: 0, endRadius: 170))
                .frame(width: 360, height: 120)
                .offset(y: 70)

            // Arm and base (behind the phone).
            VStack(spacing: 0) {
                Spacer().frame(height: 150)
                metal(RoundedRectangle(cornerRadius: 7)).frame(width: 18, height: 48)
                // Vent clip.
                ZStack {
                    metal(RoundedRectangle(cornerRadius: 10, style: .continuous)).frame(width: 96, height: 22)
                    HStack(spacing: 10) {
                        ForEach(0..<4, id: \.self) { _ in Capsule().fill(Color.black.opacity(0.35)).frame(width: 12, height: 4) }
                    }
                }
                Spacer(minLength: 0)
            }

            // Cradle bar across both halves, with clamps over the outer edges.
            ZStack {
                metal(Capsule()).frame(width: 300, height: 16)
                HStack {
                    clamp
                    Spacer()
                    clamp.scaleEffect(x: -1)
                }
                .frame(width: 316)
            }
            .offset(y: 36)

            // The unfolded phone.
            UnfoldedPhone()
                .frame(width: 290, height: 150)
                .offset(y: -18)

            // Ball joint.
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Color(white: 0.85), Color(white: 0.35), Color(white: 0.15)],
                                         center: UnitPoint(x: 0.35, y: 0.3), startRadius: 1, endRadius: 22))
                    .frame(width: 34, height: 34)
                Circle().strokeBorder(Color.black.opacity(0.4), lineWidth: 1).frame(width: 34, height: 34)
            }
            .offset(y: 62)

            // "Level" marker: both halves straight.
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.positive)
                Text("Level").font(.system(size: 13, weight: .bold))
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Theme.surface, in: Capsule())
            .offset(x: 120, y: -108)
        }
        .frame(width: 360, height: 260)
    }

    private var clamp: some View {
        metal(UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 6, bottomTrailingRadius: 2, topTrailingRadius: 2))
            .frame(width: 14, height: 40)
            .offset(y: -10)
    }

    private func metal<S: Shape>(_ shape: S) -> some View {
        shape
            .fill(LinearGradient(colors: [Color(white: 0.55), Color(white: 0.28), Color(white: 0.18)], startPoint: .top, endPoint: .bottom))
            .overlay { shape.stroke(Color.white.opacity(0.18), lineWidth: 1) }
    }
}

/// Two screens side by side with a hinge between them, showing the dashboard.
private struct UnfoldedPhone: View {
    var body: some View {
        HStack(spacing: 3) {
            half { MiniMap() }
            half {
                HStack(spacing: 4) {
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 6).fill(Theme.surface)
                            .overlay { Image(systemName: "music.note").font(.system(size: 18, weight: .bold)).foregroundStyle(Color(red: 0.96, green: 0.2, blue: 0.33)) }
                        RoundedRectangle(cornerRadius: 6).fill(Theme.surface)
                            .overlay { Image(systemName: "cloud.sun.fill").font(.system(size: 16)).foregroundStyle(.white, .yellow) }
                    }
                    VStack(spacing: 4) {
                        ForEach(0..<4, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 4)
                                .fill([Theme.accent, Color(red: 0.96, green: 0.2, blue: 0.33), Theme.positive, Theme.positive][i].gradient)
                                .frame(width: 18, height: 18)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 3)
                    .frame(width: 24)
                    .background(Theme.chrome, in: RoundedRectangle(cornerRadius: 5))
                }
            }
        }
        .padding(5)
        .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color(white: 0.32), lineWidth: 1.5) }
        .shadow(color: .black.opacity(0.6), radius: 14, y: 8)
    }

    private func half<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}
