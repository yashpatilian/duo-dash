import SwiftUI

/// Wrappers around the iOS 27.1 iPhone Duo APIs, so the rest of the app can use
/// them without availability checks and older systems simply get `nil`.
enum FoldGeometry {
    /// The fold's frame in `proxy`'s coordinates while the phone is partly open
    /// (the only time Apple reports the division region as active).
    static func foldFrame(in proxy: GeometryProxy) -> CGRect? {
        if #available(iOS 27.1, *) {
            return proxy.reservedRegions(kind: .division)
                .first(where: { $0.isActive })?
                .frame
        }
        return nil
    }
}

/// Publishes a readable description of the hinge (iOS 27.1+).
struct HingeObserver: ViewModifier {
    @Binding var text: String

    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content.onHingeChange { _, newContext in
                text = String(describing: newContext.hinge)
            }
        } else {
            content
        }
    }
}
