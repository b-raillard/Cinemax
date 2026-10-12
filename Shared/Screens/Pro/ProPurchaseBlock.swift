import SwiftUI

/// The purchase call-to-action shared by the Pro page and the contextual
/// sheet: the price read from StoreKit (never written by hand — spec R6), the
/// « Demander à acheter » waiting state, and the result alert. Only drawn for a
/// FREE user; the caller decides that.
struct ProPurchaseBlock: View {
    @Environment(ProStore.self) private var proStore
    @Environment(LocalizationManager.self) private var loc

    /// Called once a VERIFIED purchase has been acknowledged — the contextual
    /// sheet closes itself on it.
    var onPurchased: () -> Void = {}

    @State private var outcome: ProPurchaseOutcome?

    var body: some View {
        VStack(spacing: CinemaSpacing.spacing3) {
            if proStore.isPending {
                ProNoticeCard(text: loc.localized("pro.pending"), systemImage: "hourglass")
            } else if let product = proStore.product {
                CinemaButton(
                    title: loc.localized("pro.buy", product.displayPrice),
                    style: .accent,
                    isLoading: proStore.isPurchasing
                ) {
                    Task {
                        // Cancelled = the user closed the system sheet: no
                        // message at all (spec R6).
                        let result = await proStore.purchase()
                        if result != .cancelled { outcome = result }
                    }
                }
                .disabled(proStore.isPurchasing)
                Text(loc.localized("pro.buy.footnote"))
                    .font(CinemaFont.dynamicLabel(.small))
                    .foregroundStyle(CinemaColor.onSurfaceMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else if proStore.productState == .unavailable {
                Text(loc.localized("pro.price.unavailable"))
                    .font(CinemaFont.dynamicLabel(.medium))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                    .multilineTextAlignment(.center)
                CinemaButton(title: loc.localized("pro.price.retry"), style: .ghost) {
                    Task { await proStore.loadProduct() }
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 54)
            }
        }
        .task { if proStore.product == nil { await proStore.loadProduct() } }
        .alert(
            alertTitle,
            isPresented: Binding(get: { outcome != nil }, set: { if !$0 { outcome = nil } })
        ) {
            Button(loc.localized("action.ok")) {
                // After the « Merci ! », not before it: a sheet closing on the
                // purchase itself would take the thank-you down with it.
                if case .purchased = outcome { onPurchased() }
                outcome = nil
            }
        } message: {
            Text(alertMessage)
        }
    }

    private var alertTitle: String {
        switch outcome {
        case .purchased: loc.localized("pro.result.success.title")
        case .pending: loc.localized("pro.result.pending.title")
        default: loc.localized("pro.result.failed.title")
        }
    }

    private var alertMessage: String {
        switch outcome {
        case .purchased: loc.localized("pro.result.success.message")
        case .pending: loc.localized("pro.result.pending.message")
        default: loc.localized("pro.result.failed.message")
        }
    }
}

/// A tinted information card — the founder thank-you, the pending purchase.
struct ProNoticeCard: View {
    @Environment(ThemeManager.self) private var themeManager
    let text: String
    let systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: CinemaSpacing.spacing3) {
            Image(systemName: systemImage)
                .font(CinemaFont.dynamicHeadline())
                .foregroundStyle(themeManager.accent)
                .accessibilityHidden(true)
            Text(text)
                .font(CinemaFont.dynamicBody)
                .foregroundStyle(CinemaColor.onSurface)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(CinemaSpacing.spacing4)
        .background(themeManager.accent.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.large))
        .accessibilityElement(children: .combine)
    }
}

/// The small « PRO » capsule on an entry that needs the Pro.
struct ProBadge: View {
    @Environment(LocalizationManager.self) private var loc

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "lock.fill")
                .font(.system(size: CinemaScale.pt(10), weight: .bold))
                .accessibilityHidden(true)
            Text(loc.localized("pro.badge"))
                .font(.system(size: CinemaScale.pt(12), weight: .heavy))
        }
        .foregroundStyle(CinemaColor.onSurfaceVariant)
        .padding(.horizontal, CinemaSpacing.spacing2)
        .padding(.vertical, 3)
        .background(CinemaColor.surfaceContainerHighest)
        .clipShape(Capsule())
    }
}
