import AVFoundation
import SwiftUI
import UIKit

/// The live camera picture, kept level with the horizon by a rotation coordinator
/// (it follows gravity, so the layout itself never checks orientation).
struct DashcamCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        if view.previewLayer.session !== session { view.previewLayer.session = session }
        view.setNeedsLayout()
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer {
            // layerClass guarantees the type.
            layer as! AVCaptureVideoPreviewLayer
        }

        private var coordinator: AVCaptureDevice.RotationCoordinator?
        private var observation: NSKeyValueObservation?

        override func layoutSubviews() {
            super.layoutSubviews()
            attachCoordinatorIfNeeded()
            applyRotation()
        }

        /// The camera input appears once the session is configured, so this retries on layout.
        private func attachCoordinatorIfNeeded() {
            guard coordinator == nil, window != nil,
                  let input = previewLayer.session?.inputs.compactMap({ $0 as? AVCaptureDeviceInput })
                    .first(where: { $0.device.hasMediaType(.video) }) else { return }
            let coordinator = AVCaptureDevice.RotationCoordinator(device: input.device, previewLayer: previewLayer)
            self.coordinator = coordinator
            observation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.applyRotation() }
            }
        }

        private func applyRotation() {
            guard let coordinator, let connection = previewLayer.connection else { return }
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
        }
    }
}

/// The demo's stand-in picture: a dark road at dusk.
struct DashcamDemoRoad: View {
    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width, h = proxy.size.height
            let horizon = h * 0.42
            ZStack {
                LinearGradient(colors: [Color(red: 0.10, green: 0.12, blue: 0.22), Color(red: 0.28, green: 0.20, blue: 0.30)],
                               startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.42))
                Path { path in
                    path.addRect(CGRect(x: 0, y: horizon, width: w, height: h - horizon))
                }
                .fill(LinearGradient(colors: [Color(white: 0.10), Color(white: 0.04)], startPoint: .top, endPoint: .bottom))
                Path { path in
                    path.move(to: CGPoint(x: w * 0.47, y: horizon))
                    path.addLine(to: CGPoint(x: w * 0.53, y: horizon))
                    path.addLine(to: CGPoint(x: w * 0.95, y: h))
                    path.addLine(to: CGPoint(x: w * 0.05, y: h))
                    path.closeSubpath()
                }
                .fill(Color(white: 0.16))
                Path { path in
                    path.move(to: CGPoint(x: w * 0.5, y: horizon))
                    path.addLine(to: CGPoint(x: w * 0.5, y: h))
                }
                .stroke(Color.white.opacity(0.7), style: StrokeStyle(lineWidth: max(2, w * 0.006), dash: [h * 0.06, h * 0.05]))
                Text("Demo camera")
                    .font(.dashCaption)
                    .foregroundStyle(Theme.textSecondary)
                    .position(x: w / 2, y: horizon * 0.5)
            }
        }
        .accessibilityHidden(true)
    }
}
