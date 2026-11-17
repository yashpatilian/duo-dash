import Foundation
import StoreKit
import UIKit

/// Duo Dash Pro through StoreKit 2. In the Simulator, the shared scheme's Run action uses
/// DuoDash/StoreKit/DuoDashPro.storekit, so purchases work offline.
@MainActor
final class StoreKitProBackend: ProStoreBackend {
    private var cache: [String: Product] = [:]

    func loadProducts(ids: [String]) async throws -> [ProProduct] {
        let products = try await Product.products(for: ids)
        var result: [ProProduct] = []
        for product in products {
            guard let kind = ProProductKind(productID: product.id) else { continue }
            cache[product.id] = product
            result.append(ProProduct(id: product.id, kind: kind, displayName: product.displayName,
                                     description: product.description, displayPrice: product.displayPrice,
                                     trialText: await Self.trialText(for: product)))
        }
        return result
    }

    /// "1 week free", only when the offer is a free trial and this Apple Account can still get it.
    private static func trialText(for product: Product) async -> String? {
        guard let subscription = product.subscription,
              let offer = subscription.introductoryOffer, offer.paymentMode == .freeTrial,
              await subscription.isEligibleForIntroOffer else { return nil }
        return "\(describe(offer.period)) free"
    }

    static func describe(_ period: Product.SubscriptionPeriod) -> String {
        let unit: String
        switch period.unit {
        case .day: unit = period.value == 7 ? "week" : "day"
        case .week: unit = "week"
        case .month: unit = "month"
        case .year: unit = "year"
        @unknown default: unit = "period"
        }
        let value = period.unit == .day && period.value == 7 ? 1 : period.value
        return value == 1 ? "1 \(unit)" : "\(value) \(unit)s"
    }

    func entitledProductIDs() async -> Set<String> {
        var ids = Set<String>()
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result, transaction.revocationDate == nil else { continue }
            if let expiry = transaction.expirationDate, expiry < .now { continue }
            ids.insert(transaction.productID)
        }
        return ids
    }

    func purchase(productID: String) async throws -> ProPurchaseResult {
        let product: Product
        if let cached = cache[productID] {
            product = cached
        } else if let fetched = try await Product.products(for: [productID]).first {
            product = fetched
        } else {
            throw ProStoreError.productUnavailable
        }
        let scene = UIApplication.shared.connectedScenes
            .first { $0.activationState == .foregroundActive } as? UIWindowScene
        let result = if let scene { try await product.purchase(confirmIn: scene) } else { try await product.purchase() }
        switch result {
        case .success(let verification):
            guard case .verified(let transaction) = verification else { throw ProStoreError.unverified }
            await transaction.finish()
            return .purchased
        case .pending:
            return .pending
        case .userCancelled:
            return .cancelled
        @unknown default:
            return .cancelled
        }
    }

    func sync() async throws {
        try await AppStore.sync()
    }

    func observeTransactions(_ onChange: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        Task.detached {
            for await result in Transaction.updates {
                if case .verified(let transaction) = result { await transaction.finish() }
                await onChange()
            }
        }
    }
}
