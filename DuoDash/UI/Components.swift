import SwiftUI

/// A CarPlay-style dashboard tile: solid dark grey, rounded.
struct Card<Content: View>: View {
    var padding: CGFloat = 16
    var tint: Color? = nil
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(tint ?? Theme.surface,
                        in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
    }
}

/// A large round glass button that is never smaller than `Theme.minTouch`.
struct DashIconButton: View {
    let symbol: String
    var size: CGFloat = Theme.minTouch
    var prominent = false
    var tint: Color = Theme.accent
    var label: String? = nil
    var identifier: String? = nil
    let action: () -> Void

    var body: some View {
        let side = max(size, Theme.minTouch)
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: side * 0.40, weight: .bold))
                .foregroundStyle(prominent ? Theme.onAccent : Theme.textPrimary)
                .frame(width: side, height: side)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(prominent ? Glass.regular.tint(tint).interactive() : Glass.regular.interactive(), in: Circle())
        .accessibilityLabel(label ?? symbol)
        .accessibilityIdentifier(identifier ?? label ?? symbol)
    }
}

/// A wide glass pill button with text and optional symbol.
struct DashPillButton: View {
    let title: String
    var symbol: String? = nil
    var prominent = true
    var tint: Color = Theme.accent
    var identifier: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let symbol { Image(systemName: symbol) }
                Text(title).lineLimit(1).minimumScaleFactor(0.8)
            }
            .font(.dashBody)
            .foregroundStyle(prominent ? Theme.onAccent : Theme.textPrimary)
            .padding(.horizontal, 22)
            .frame(minWidth: Theme.minTouch * 1.5, minHeight: Theme.minTouch)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(prominent ? Glass.regular.tint(tint).interactive() : Glass.regular.interactive(), in: Capsule())
        .accessibilityIdentifier(identifier ?? title)
    }
}

/// Gives quick visual feedback on press without the default fade.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A row in a CarPlay-style list: artwork/icon, title, subtitle, chevron.
struct ListRow<Leading: View>: View {
    let title: String
    var subtitle: String = ""
    var identifier: String? = nil
    @ViewBuilder var leading: Leading
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                leading
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.dashBody).lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.dashCaption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.dashCaption)
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: Theme.minTouch + 8)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .accessibilityIdentifier(identifier ?? title)
    }
}

/// Big, centred message used for empty, denied and error states.
struct EmptyStateView: View {
    let symbol: String
    let title: String
    var message: String = ""
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text(title).font(.dashTitle).multilineTextAlignment(.center)
            if !message.isEmpty {
                Text(message)
                    .font(.dashCaption)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
            if let actionTitle, let action {
                DashPillButton(title: actionTitle, action: action)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
