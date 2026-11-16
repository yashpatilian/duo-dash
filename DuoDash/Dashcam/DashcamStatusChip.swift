import SwiftUI

/// A tiny "● Dashcam" chip for the status column / Dashboard: red and pulsing
/// while recording, orange when paused, grey when off.
struct DashcamStatusChip: View {
    @Environment(DashcamModel.self) private var dashcam
    var action: (() -> Void)? = nil

    var body: some View {
        let content = HStack(spacing: 6) {
            Image(systemName: "circle.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(tint)
                .symbolEffect(.pulse, isActive: dashcam.state.isRecording)
            Text("Dashcam")
                .font(.dashCaption)
                .foregroundStyle(dashcam.state.isRecording ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.surfaceRaised, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Dashcam, \(dashcam.state.summary)")
        .accessibilityIdentifier("dashcam.chip")

        if let action {
            Button(action: action) {
                content.frame(minWidth: Theme.minTouch, minHeight: Theme.minTouch).contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
        } else {
            content
        }
    }

    private var tint: Color {
        switch dashcam.state {
        case .recording: Theme.danger
        case .starting, .interrupted: Theme.warning
        case .idle, .unavailable, .permissionDenied: Color(white: 0.45)
        }
    }
}
