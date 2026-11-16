import SwiftUI

/// Developer overlay that reports the real screen, window and hinge geometry, so
/// the Duo's sizes can be measured on the device instead of guessed.
/// Open it by long-pressing the clock.
struct ScreenInfoView: View {
    @Environment(AppModel.self) private var app
    @State private var copied = false
    @State private var hingeText = "n/a"

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let report = Self.report(contentSize: proxy.size, fold: FoldGeometry.foldFrame(in: proxy), hinge: hingeText)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("Screen info").font(.dashTitle)
                            Spacer()
                            DashIconButton(symbol: "xmark", label: "Close", identifier: "screeninfo.close") {
                                app.showScreenInfo = false
                            }
                        }
                        Text(report)
                            .font(.system(size: 15, weight: .medium, design: .monospaced))
                            .textSelection(.enabled)
                            .accessibilityIdentifier("screeninfo.report")
                        DashPillButton(title: copied ? "Copied" : "Copy report", symbol: "doc.on.doc") {
                            UIPasteboard.general.string = report
                            copied = true
                        }
                    }
                    .padding(24)
                }
                .frame(maxWidth: 560)
                .fixedSize(horizontal: false, vertical: true)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.corner))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(16)
        .background(Color.black.opacity(0.55).ignoresSafeArea())
        .modifier(HingeObserver(text: $hingeText))
    }

    private static func report(contentSize: CGSize, fold: CGRect?, hinge: String) -> String {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        let screen = scene?.screen
        let window = scene?.windows.first { $0.isKeyWindow }
        func size(_ s: CGSize?) -> String {
            guard let s else { return "?" }
            return "\(Int(s.width.rounded())) × \(Int(s.height.rounded()))"
        }
        let orientation: String
        switch scene?.effectiveGeometry.interfaceOrientation {
        case .portrait: orientation = "portrait"
        case .portraitUpsideDown: orientation = "portrait (upside down)"
        case .landscapeLeft: orientation = "landscape left"
        case .landscapeRight: orientation = "landscape right"
        default: orientation = "unknown"
        }
        let insets = window?.safeAreaInsets ?? .zero
        let metrics = DashMetrics(size: contentSize)
        return """
        Device         \(UIDevice.current.model), iOS \(UIDevice.current.systemVersion)
        Screen (pt)    \(size(screen?.bounds.size))
        Native (px)    \(size(screen?.nativeBounds.size))
        Scale          \(screen.map { String(format: "%.1f", $0.scale) } ?? "?")
        Window (pt)    \(size(window?.bounds.size))
        Content (pt)   \(size(contentSize))
        Safe area      T\(Int(insets.top)) L\(Int(insets.left)) B\(Int(insets.bottom)) R\(Int(insets.right))
        Orientation    \(orientation)
        Layout         \(metrics.usesSidebar ? "sidebar" : "bottom dock")\(metrics.isCompact ? ", compact" : "")
        Fold region    \(fold.map { "x\(Int($0.minX)) y\(Int($0.minY)) \(Int($0.width))×\(Int($0.height))" } ?? "none active")
        Hinge          \(hinge)
        """
    }
}
