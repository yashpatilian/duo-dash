import StoreKit
import SwiftUI

/// The Duo Dash Pro paywall, drawn by RootView over the whole app as a Liquid Glass sheet
/// (inside the app's own window, so it fits the cover screen, Split View and the test canvas).
/// Prices are the App Store's `displayPrice`; the free trial is only mentioned when the
/// account is eligible. Restore Purchases, Terms of Use and Privacy Policy are always there
/// (App Review 3.1.2).
struct PaywallView: View {
    @Environment(ProStore.self) private var pro
    @Environment(\.openURL) private var openURL
    @State private var choice: ProProductKind = .yearly

    static let features: [(symbol: String, title: String, detail: String)] = [
        ("video.fill", "Dashcam", "Loop recording of the road, with clips you keep. Free in personal builds."),
        ("car.side.rear.and.collision.and.car.side.front", "Impact detection", "The dashcam saves a clip by itself after a crash-like jolt."),
        ("clock.arrow.circlepath", "Longer dashcam loops", "Keep the last 45 or 60 minutes of driving."),
        ("point.bottomleft.forward.to.point.topright.scurvepath", "Trip history", "Every drive with its route, distance and speeds, kept on your iPhone."),
        ("paintpalette.fill", "Themes", "Accent colours and wallpapers for the app grid."),
        ("rectangle.3.group.fill", "Home layout", "Reorder the dashboard and pick its third card."),
        ("app.badge.fill", "App icons", "Midnight, Silver, Ocean and Sunset icons."),
    ]

    /// The dashcam line only where it's actually a Pro feature (the App Store edition).
    private var features: [(symbol: String, title: String, detail: String)] {
        Edition.current.isCommercial
            ? [("video.fill", "Dashcam", "Loop recording of the road, with clips you keep.")] + Self.features.dropFirst()
            : Array(Self.features.dropFirst())
    }

    var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width >= 760 && proxy.size.width > proxy.size.height
            ZStack(alignment: .bottom) {
                Color.black.opacity(0.55)
                    .ignoresSafeArea()
                    .onTapGesture { close() }
                    .accessibilityHidden(true)
                sheet(wide: wide)
                    .frame(maxWidth: wide ? 900 : 620)
                    .frame(maxHeight: proxy.size.height - (proxy.size.height > 560 ? 24 : 8))
                    .padding(.horizontal, proxy.size.width > 500 ? 16 : 6)
                    .padding(.bottom, 6)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottom)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("paywall")
    }

    private func sheet(wide: Bool) -> some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button { close() } label: {
                    Image(systemName: "xmark").font(.system(size: 18, weight: .semibold))
                        .frame(width: Theme.minTouch, height: Theme.minTouch)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Circle())
                .accessibilityLabel("Close")
                .accessibilityIdentifier("paywall.close")
            }
            .padding([.top, .horizontal], 10)
            ScrollView {
                if wide {
                    HStack(alignment: .top, spacing: 28) {
                        VStack(alignment: .leading, spacing: 18) { header; featureList }
                            .frame(maxWidth: .infinity)
                        VStack(spacing: 14) { options; buyButton; footer }
                            .frame(maxWidth: .infinity)
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
                } else {
                    // Prices first on narrow sheets, so they're on screen without scrolling.
                    VStack(spacing: 18) {
                        header
                        options
                        buyButton
                        featureList
                        footer
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 20)
                }
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 34, style: .continuous))
        .background(Theme.surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 34, style: .continuous))
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "star.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(LinearGradient(colors: ProStyle.gold, startPoint: .top, endPoint: .bottom),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .accessibilityHidden(true)
            Text("Duo Dash Pro").font(.system(size: 30, weight: .bold))
                .accessibilityAddTraits(.isHeader)
            Text("Everything you use today stays free. Pro adds:")
                .font(.dashCaption).foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(features, id: \.title) { feature in
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: feature.symbol)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(ProStyle.gold[1])
                        .frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(feature.title).font(.dashBody)
                        Text(feature.detail).font(.dashCaption).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("paywall.features")
    }

    @ViewBuilder
    private var options: some View {
        if pro.products.isEmpty {
            VStack(spacing: 10) {
                if pro.isLoadingProducts {
                    ProgressView().controlSize(.large)
                } else {
                    Text(pro.productsError ?? "Prices aren't available right now.")
                        .font(.dashCaption).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
                    DashPillButton(title: "Try Again", prominent: false, identifier: "paywall.retry") {
                        Task { await pro.loadProducts() }
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 120)
        } else {
            VStack(spacing: 10) {
                ForEach(pro.products) { product in
                    optionRow(product)
                }
            }
        }
    }

    private func optionRow(_ product: ProProduct) -> some View {
        let selected = choice == product.kind
        return Button { withAnimation(.snappy) { choice = product.kind } } label: {
            HStack(spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 24))
                    .foregroundStyle(selected ? ProStyle.gold[1] : Theme.textSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(product.kind.title).font(.dashBody)
                        if let trial = product.trialText {
                            Text(trial.uppercased())
                                .font(.system(size: 12, weight: .bold))
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Theme.positive.opacity(0.25), in: Capsule())
                                .foregroundStyle(Theme.positive)
                        }
                    }
                    Text(subtitle(product)).font(.dashCaption).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Text(product.displayPrice).font(.dashBody).monospacedDigit()
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: Theme.minTouch + 10)
            .background(Theme.surfaceRaised.opacity(selected ? 1 : 0.6), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(selected ? ProStyle.gold[1] : .clear, lineWidth: 2)
            }
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("paywall.option.\(product.kind.rawValue)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func subtitle(_ product: ProProduct) -> String {
        if let trial = product.trialText {
            return "\(trial), then \(product.displayPrice) \(product.kind.priceSuffix). Cancel anytime."
        }
        switch product.kind {
        case .lifetime: return "One-time purchase"
        default: return "\(product.displayPrice) \(product.kind.priceSuffix). Cancel anytime."
        }
    }

    private var selectedProduct: ProProduct? { pro.product(choice) ?? pro.products.first }

    private var buyButton: some View {
        VStack(spacing: 8) {
            Button {
                guard let product = selectedProduct else { return }
                Task { await pro.purchase(product) }
            } label: {
                Group {
                    if pro.purchasingID != nil {
                        ProgressView()
                    } else {
                        Text(buyTitle).font(.dashBody)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: Theme.minTouch)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.capsule)
            .tint(ProStyle.gold[1])
            .disabled(selectedProduct == nil || pro.purchasingID != nil)
            .accessibilityIdentifier("paywall.buy")
            if let message = pro.message {
                Text(message).font(.dashCaption).foregroundStyle(Theme.warning).multilineTextAlignment(.center)
                    .accessibilityIdentifier("paywall.message")
            }
        }
    }

    private var buyTitle: String {
        guard let product = selectedProduct else { return "Continue" }
        if product.trialText != nil { return "Start Free Trial" }
        return product.kind == .lifetime ? "Buy for \(product.displayPrice)" : "Subscribe for \(product.displayPrice)"
    }

    private var footer: some View {
        VStack(spacing: 6) {
            Button {
                Task { await pro.restore() }
            } label: {
                Group {
                    if pro.isRestoring { ProgressView() } else { Text("Restore Purchases") }
                }
                .font(.dashBody.weight(.regular))
                .frame(minHeight: Theme.minTouch)
                .padding(.horizontal, 16)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .accessibilityIdentifier("paywall.restore")
            HStack(spacing: 4) {
                Button("Terms of Use") { openURL(ProStore.termsURL) }
                    .accessibilityIdentifier("paywall.terms")
                Text("·").foregroundStyle(Theme.textSecondary)
                Button("Privacy Policy") { openURL(ProStore.privacyURL) }
                    .accessibilityIdentifier("paywall.privacy")
            }
            .font(.dashCaption)
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textSecondary)
            .frame(minHeight: 44)
            Text("Subscriptions renew automatically unless cancelled at least 24 hours before the end of the period. Manage or cancel in your Apple Account settings. Payment is charged to your Apple Account.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    private func close() {
        withAnimation(.smooth(duration: 0.3)) { pro.isPaywallPresented = false }
    }
}

enum ProStyle {
    /// Gold to orange, for the Pro icon and badges.
    static let gold = [Color(red: 1.0, green: 0.80, blue: 0.20), Color(red: 1.0, green: 0.58, blue: 0.0)]
}

/// The small "PRO" capsule on locked controls.
struct ProBadge: View {
    var body: some View {
        Text("PRO")
            .font(.system(size: 11, weight: .heavy))
            .tracking(0.6)
            .foregroundStyle(.black)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(LinearGradient(colors: ProStyle.gold, startPoint: .leading, endPoint: .trailing), in: Capsule())
            .accessibilityLabel("Pro")
    }
}

/// Locks a control behind Pro: without Pro it is dimmed, shows the PRO badge, and a tap
/// opens the paywall instead. With Pro it's untouched.
struct ProLockModifier: ViewModifier {
    @Environment(ProStore.self) private var pro
    var unlocked: Bool?
    let identifier: String
    var badgeAlignment: Alignment = .topTrailing

    func body(content: Content) -> some View {
        if unlocked ?? pro.isPro {
            content
        } else {
            content
                .opacity(0.55)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .overlay(alignment: badgeAlignment) { ProBadge().padding(6).allowsHitTesting(false) }
                .overlay {
                    Button { pro.showPaywall() } label: {
                        Color.clear.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Unlock with Duo Dash Pro")
                    .accessibilityIdentifier(identifier)
                }
        }
    }
}

extension View {
    /// See `ProLockModifier`. `unlocked` overrides the plain Pro check (edition-specific gates).
    func proLocked(_ identifier: String, unlocked: Bool? = nil, badge: Alignment = .topTrailing) -> some View {
        modifier(ProLockModifier(unlocked: unlocked, identifier: identifier, badgeAlignment: badge))
    }
}
