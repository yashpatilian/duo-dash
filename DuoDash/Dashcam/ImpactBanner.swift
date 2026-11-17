import SwiftUI

/// "Impact detected: clip saved", over any screen, after the dashcam's impact detection
/// (Duo Dash Pro) kept a clip. Tap to open the Dashcam; it goes away by itself after 8 s.
struct ImpactBanner: View {
    @Environment(DashcamModel.self) private var dashcam
    @Environment(AppModel.self) private var app

    var body: some View {
        if let text = dashcam.impactBanner {
            Button {
                dashcam.impactBanner = nil
                app.open(.dashcam)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "car.side.rear.and.collision.and.car.side.front")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Theme.warning)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(text).font(.dashBody)
                        Text("Tap to see it in Dashcam").font(.dashCaption).foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(.horizontal, 18)
                .frame(minHeight: Theme.minTouch + 6)
                .glassEffect(.regular, in: Capsule())
            }
            .buttonStyle(.plain)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityIdentifier("dashcam.impactBanner")
            .task(id: text) {
                try? await Task.sleep(for: .seconds(8))
                if dashcam.impactBanner == text { withAnimation { dashcam.impactBanner = nil } }
            }
        }
    }
}
