import SwiftUI

/// Settings → Duo Dash Pro: status, Themes, Home layout, App icon, Dashcam Pro, Trip history,
/// and the subscription. Drawn like the other Settings pages (inset groups, corner 26,
/// green switches). Without Pro every group is visible but locked: a tap opens the paywall.
struct ProSettingsSection: View {
    @Environment(ProStore.self) private var pro

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            ProStatusGroup()
            ProThemesGroup()
            ProHomeLayoutGroup()
            ProAppIconGroup()
            ProDashcamGroup()
            ProTripsGroup()
            ProSubscriptionGroup()
        }
        .task { await pro.refreshEntitlements() }
    }
}

/// Settings → Dashcam. In the App Store edition without Pro, the dashcam is locked: the page
/// says so and opens the paywall.
struct DashcamSettingsPage: View {
    @Environment(ProStore.self) private var pro

    private var available: Bool { ProGate.dashcamAvailable(edition: .current, isPro: pro.isPro) }

    var body: some View {
        ProGroup(footer: "The rear camera records the road while Duo Dash is on screen. iOS stops the camera when the phone locks or another app is in front.") {
            DashcamSettingsPanel().padding(16)
                .proLocked("settings.dashcam.locked", unlocked: available)
        }
        .onAppear { if !available { pro.showPaywall() } }
    }
}

// MARK: - Groups

private struct ProStatusGroup: View {
    @Environment(ProStore.self) private var pro

    var body: some View {
        if pro.isPro {
            ProGroup(footer: "Thank you for supporting Duo Dash.") {
                ProRow(title: "Duo Dash Pro", subtitle: statusText) {
                    Image(systemName: "checkmark.seal.fill").font(.title2).foregroundStyle(ProStyle.gold[1])
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("pro.status.active")
            }
        } else {
            Button { pro.showPaywall() } label: {
                HStack(spacing: 14) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 26, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 60, height: 60)
                        .background(LinearGradient(colors: ProStyle.gold, startPoint: .top, endPoint: .bottom),
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Unlock Duo Dash Pro").font(.system(size: 22, weight: .semibold))
                        Text(offerText).font(.dashCaption).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.white.opacity(0.3))
                }
                .padding(14)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: SettingsStyle.corner, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: SettingsStyle.corner, style: .continuous))
            }
            .buttonStyle(PressableStyle())
            .accessibilityIdentifier("pro.unlock")
        }
    }

    private var statusText: String {
        switch pro.activeKind {
        case .lifetime: "Active · Lifetime"
        case .yearly: "Active · Yearly subscription"
        case .monthly: "Active · Monthly subscription"
        case nil: "Active"
        }
    }

    private var offerText: String {
        if let yearly = pro.product(.yearly), let trial = yearly.trialText {
            return "Try it free for \(trial.replacingOccurrences(of: " free", with: "")), then \(yearly.displayPrice) a year."
        }
        return "Themes, Home layout, app icons, dashcam extras and trip history."
    }
}

private struct ProThemesGroup: View {
    @Environment(ThemeSettings.self) private var theme

    var body: some View {
        ProGroup(header: "THEMES", footer: "The accent colours buttons and selections; the wallpaper is behind the app grid.") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Accent colour").font(.dashBody.weight(.regular))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: Theme.minTouch), spacing: 6)], spacing: 6) {
                    ForEach(AccentChoice.allCases) { choice in
                        let selected = theme.accent == choice
                        Button { withAnimation(.snappy) { theme.accent = choice } } label: {
                            Circle().fill(choice.color)
                                .frame(width: 40, height: 40)
                                .overlay {
                                    if selected {
                                        Image(systemName: "checkmark").font(.system(size: 17, weight: .bold)).foregroundStyle(choice.onColor)
                                    }
                                }
                                .padding(4)
                                .overlay(Circle().strokeBorder(selected ? Color.white : .clear, lineWidth: 2))
                                .frame(width: Theme.minTouch, height: Theme.minTouch)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(choice.title)
                        .accessibilityIdentifier("pro.accent.\(choice.rawValue)")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }
            .padding(16)
            ProDivider()
            VStack(alignment: .leading, spacing: 10) {
                Text("App grid wallpaper").font(.dashBody.weight(.regular))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 10)], spacing: 10) {
                    ForEach(WallpaperChoice.allCases) { choice in
                        let selected = theme.wallpaper == choice
                        Button { withAnimation(.snappy) { theme.wallpaper = choice } } label: {
                            VStack(spacing: 6) {
                                WallpaperView(wallpaper: choice)
                                    .frame(height: 64)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .strokeBorder(selected ? Theme.accent : Color.white.opacity(0.15), lineWidth: selected ? 3 : 1)
                                    }
                                Text(choice.title).font(.dashCaption).lineLimit(1)
                                    .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(choice.title)
                        .accessibilityIdentifier("pro.wallpaper.\(choice.rawValue)")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }
            .padding(16)
        }
        .proLocked("pro.locked.themes")
    }
}

private struct ProHomeLayoutGroup: View {
    @Environment(HomeLayoutSettings.self) private var layout
    private let rowHeight: CGFloat = Theme.minTouch + 2

    var body: some View {
        ProGroup(header: "HOME LAYOUT", footer: "Drag to reorder the Home cards. On wide screens the map goes on the left when it's in the top half, else on the right. On narrow screens the map always comes first.") {
            HomeCardReorderList(rowHeight: rowHeight)
            ProDivider()
            Text("Third card shows").font(.dashBody.weight(.regular)).padding(.horizontal, 18).padding(.top, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(HomeExtraCard.allCases) { option in
                ProDivider(inset: 18)
                Button { layout.extra = option } label: {
                    ProRow(title: option.title, subtitle: option.subtitle) {
                        if layout.extra == option {
                            Image(systemName: "checkmark").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.accent)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("pro.extra.\(option.rawValue)")
                .accessibilityAddTraits(layout.extra == option ? .isSelected : [])
            }
            ProDivider()
            ProRow(title: "Reset Home layout") {
                DashPillButton(title: "Reset", prominent: false, identifier: "pro.homeLayout.reset") {
                    withAnimation(.snappy) { layout.reset() }
                }
                .disabled(!layout.isCustomised)
            }
        }
        .proLocked("pro.locked.homeLayout")
    }
}

/// The Home cards with iOS-style reorder grips: drag a grip up or down and the other rows make
/// room as it passes them. (A SwiftUI List in edit mode can't reorder while nested in the
/// page's ScrollView, so the drag is done here.) VoiceOver: swipe up/down on a grip to move it.
private struct HomeCardReorderList: View {
    @Environment(HomeLayoutSettings.self) private var layout
    let rowHeight: CGFloat
    @State private var dragging: HomeCard?
    @State private var dragStart = 0
    @State private var offset: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(layout.order.enumerated()), id: \.element) { index, card in
                if index > 0 { ProDivider(inset: 64) }
                row(card, index: index)
                    .offset(y: dragging == card ? offset : 0)
                    .zIndex(dragging == card ? 1 : 0)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pro.homeCards")
    }

    private func row(_ card: HomeCard, index: Int) -> some View {
        HStack(spacing: 14) {
            Image(systemName: card.symbol)
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(card == .extra ? "\(card.title): \(layout.extra.title)" : card.title)
                .font(.dashBody.weight(.regular)).lineLimit(1).minimumScaleFactor(0.8)
                .accessibilityIdentifier("pro.homeCard.\(card.rawValue)")
            Spacer(minLength: 8)
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: Theme.minTouch, height: rowHeight)
                .contentShape(Rectangle())
                .highPriorityGesture(drag(card))
                .accessibilityElement()
                .accessibilityLabel("Reorder \(card.title)")
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("pro.homeCard.grip.\(card.rawValue)")
                .accessibilityAdjustableAction { direction in
                    let target = direction == .increment ? index - 1 : index + 1
                    guard layout.order.indices.contains(target) else { return }
                    move(card, to: target)
                }
        }
        .padding(.leading, 18)
        .frame(height: rowHeight)
        .background(dragging == card ? Theme.surfaceRaised : Theme.surface)
        .shadow(color: .black.opacity(dragging == card ? 0.4 : 0), radius: 10, y: 4)
    }

    private func drag(_ card: HomeCard) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if dragging != card {
                    dragging = card
                    dragStart = layout.order.firstIndex(of: card) ?? 0
                }
                let steps = Int((value.translation.height / rowHeight).rounded())
                let target = min(max(dragStart + steps, 0), layout.order.count - 1)
                if layout.order.firstIndex(of: card) != target {
                    withAnimation(.snappy(duration: 0.2)) { move(card, to: target) }
                }
                offset = value.translation.height - CGFloat(target - dragStart) * rowHeight
            }
            .onEnded { _ in
                withAnimation(.snappy(duration: 0.2)) {
                    dragging = nil
                    offset = 0
                }
            }
    }

    private func move(_ card: HomeCard, to target: Int) {
        guard let from = layout.order.firstIndex(of: card) else { return }
        layout.move(fromOffsets: IndexSet(integer: from), toOffset: target > from ? target + 1 : target)
    }
}

private struct ProAppIconGroup: View {
    @State private var icons = AppIconModel()

    var body: some View {
        ProGroup(header: "APP ICON", footer: icons.error ?? "iOS confirms the change with a short message.") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 10)], spacing: 12) {
                ForEach(AppIconChoice.allCases) { choice in
                    let selected = icons.current == choice
                    Button { Task { await icons.set(choice) } } label: {
                        VStack(spacing: 6) {
                            Image(choice.previewAsset).resizable().scaledToFit()
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                                        .strokeBorder(selected ? Theme.accent : Color.white.opacity(0.15), lineWidth: selected ? 3 : 1)
                                }
                            Text(choice.title).font(.dashCaption).lineLimit(1)
                                .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                        }
                        .frame(minHeight: Theme.minTouch)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(choice.title) icon")
                    .accessibilityIdentifier("pro.icon.\(choice.rawValue)")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(16)
            .disabled(!icons.isSupported)
        }
        .proLocked("pro.locked.appIcon")
    }
}

private struct ProDashcamGroup: View {
    @Environment(ProStore.self) private var pro

    var body: some View {
        ProGroup(header: "DASHCAM", footer: footer) {
            DashcamImpactSettings().padding(16)
        }
    }

    private var footer: String {
        var text = "Longer loops of 45 and 60 minutes are in Settings → Dashcam."
        if Edition.current.isCommercial { text = "The dashcam is part of Duo Dash Pro. " + text }
        return text
    }
}

private struct ProTripsGroup: View {
    @Environment(TripStore.self) private var trips

    var body: some View {
        @Bindable var trips = trips
        ProGroup(header: "TRIP HISTORY", footer: "Each drive is saved when you've driven faster than 15 km/h for 30 seconds, and ends after 5 minutes stopped. Trips stay on this iPhone.") {
            ProRow(title: "Record trips") {
                Toggle("", isOn: $trips.isRecordingEnabled).labelsHidden().tint(Theme.positive)
                    .accessibilityIdentifier("pro.trips.record")
            }
            ProDivider()
            Button { trips.isBrowsing = true } label: {
                ProRow(title: "Trip history", subtitle: "\(trips.trips.count) \(trips.trips.count == 1 ? "trip" : "trips")") {
                    Image(systemName: "chevron.right").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.white.opacity(0.3))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("pro.trips.open")
        }
        .proLocked("pro.locked.trips")
    }
}

private struct ProSubscriptionGroup: View {
    @Environment(ProStore.self) private var pro

    var body: some View {
        ProGroup(header: "PURCHASES", footer: pro.message) {
            if pro.hasSubscription {
                Button { pro.isManagingSubscriptions = true } label: {
                    ProRow(title: "Manage Subscription") {
                        Image(systemName: "arrow.up.forward").font(.dashCaption).foregroundStyle(Theme.textSecondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("pro.manage")
                ProDivider()
            } else if !pro.isPro {
                Button { pro.showPaywall() } label: {
                    ProRow(title: "See Plans") {
                        Image(systemName: "chevron.right").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.white.opacity(0.3))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("pro.plans")
                ProDivider()
            }
            Button { Task { await pro.restore() } } label: {
                ProRow(title: "Restore Purchases") {
                    if pro.isRestoring { ProgressView() }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .accessibilityIdentifier("pro.restore")
        }
    }
}

// MARK: - Building blocks (the Settings look; SettingsView's own are private to its file)

private struct ProGroup<Content: View>: View {
    var header: String? = nil
    var footer: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let header {
                Text(header).font(.dashCaption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 18)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(spacing: 0) { content }
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: SettingsStyle.corner, style: .continuous))
            if let footer {
                Text(footer)
                    .font(.dashCaption.weight(.regular))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 18)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct ProRow<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.dashBody.weight(.regular))
                if let subtitle {
                    Text(subtitle).font(.dashCaption.weight(.regular)).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
        .frame(minHeight: Theme.minTouch + 2)
    }
}

private struct ProDivider: View {
    var inset: CGFloat = 18
    var body: some View { Theme.separator.frame(height: 0.5).padding(.leading, inset) }
}
