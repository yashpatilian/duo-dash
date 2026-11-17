import SwiftUI

/// Copy shared by the onboarding sheet and Settings → Duo Dash Mount.
enum DuoDockCopy {
    static let headline = "The car mount made for iPhone Duo."
    static let pitch = "Stops the left half sagging and keeps it straight and unfolded, like a head unit you can take with you."
    static let name = "Duo Dash Mount"
    static let about = "The Duo Dash mount is a car mount designed for the iPhone Duo. It holds both halves of the unfolded phone on one level cradle, so Duo Dash sits in your car like a built-in screen."
    static let price = "A$59 for the first 10 orders, then A$70. Register your interest and we'll email you when it's ready."
    static let benefits: [(symbol: String, text: String)] = [
        ("ruler", "Both halves held level, so the left half never sags."),
        ("rectangle.split.2x1", "Stays unfolded and straight, like a built-in head unit."),
        ("arrow.up.and.down.and.arrow.left.and.right", "Ball joint angles it to you; unclip and take it with you."),
    ]
}

/// The last page of the welcome tour: a sheet promoting the Duo Dash car mount.
struct DuoDockPromoSheet: View {
    let layout: OnboardingLayout
    let get: () -> Void
    let notNow: () -> Void
    @Namespace private var glass

    var body: some View {
        let p = layout.padding
        return ZStack(alignment: .bottom) {
            Theme.background
            sheet
                .padding(.horizontal, layout.wide ? p : 6)
                .padding(.top, max(p, layout.insets.top) + (layout.compact ? 6 : 24))
        }
        .frame(width: layout.size.width, height: layout.size.height)
    }

    private var sheet: some View {
        let p = layout.padding
        return VStack(spacing: 0) {
            Capsule().fill(Color.white.opacity(0.3)).frame(width: 40, height: 5).padding(.top, 8)
            Group {
                if layout.wide {
                    let fold = layout.verticalFold
                    HStack(spacing: fold.map { $0.width + 2 * p } ?? p) {
                        FittedArt(maxScale: 1.5) { DuoDockIllustration() }
                            .frame(width: fold.map { $0.minX - 3 * p })
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        VStack(alignment: .leading, spacing: 14) {
                            copy
                            buttons
                        }
                        .frame(width: fold.map { layout.size.width - $0.maxX - 2 * p } ?? min(440, layout.size.width * 0.48))
                    }
                } else {
                    VStack(spacing: layout.compact ? 10 : 16) {
                        FittedArt(maxScale: 1.5) { DuoDockIllustration() }
                            .frame(height: layout.size.height * (layout.compact ? 0.38 : 0.40))
                        copy.frame(maxHeight: .infinity, alignment: .top)
                        buttons
                    }
                }
            }
            .padding(.horizontal, p)
            .padding(.top, 8)
            .padding(.bottom, max(p, layout.insets.bottom))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface,
                    in: UnevenRoundedRectangle(topLeadingRadius: 34, bottomLeadingRadius: layout.wide ? 34 : 0,
                                               bottomTrailingRadius: layout.wide ? 34 : 0, topTrailingRadius: 34,
                                               style: .continuous))
        .padding(.bottom, layout.wide ? p : 0)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dock.promo")
    }

    private var copy: some View {
        ViewThatFits(in: .vertical) {
            copyText
            ScrollView { copyText }.scrollIndicators(.hidden)
        }
    }

    private var copyText: some View {
        VStack(alignment: .leading, spacing: layout.compact ? 8 : 12) {
            Text("DUO DASH MOUNT").font(.subheadline.weight(.heavy)).kerning(1.5).foregroundStyle(Theme.accent)
                .accessibilityIdentifier("onboarding.page.promo")
            Text(DuoDockCopy.headline)
                .font(layout.compact ? .title.weight(.bold) : .largeTitle.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("dock.promo.headline")
            Text(DuoDockCopy.pitch)
                .font(layout.compact ? .body : .title3)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(DuoDockCopy.price)
                .font(layout.compact ? .subheadline.weight(.semibold) : .headline)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("dock.promo.price")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var buttons: some View {
        GlassEffectContainer(spacing: 10) {
            VStack(spacing: 10) {
                OnboardingButton(title: "Register interest", symbol: "arrow.up.forward", prominent: true,
                                 id: "dock.promo.get", glass: glass, action: get)
                OnboardingButton(title: "Not now", id: "dock.promo.notNow", glass: glass, glassID: "secondary", action: notNow)
            }
        }
    }
}
