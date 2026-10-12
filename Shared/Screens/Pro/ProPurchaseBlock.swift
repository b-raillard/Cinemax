import SwiftUI

/// The purchase call-to-action shared by the Pro page and the contextual
/// sheet: the price read from StoreKit (never written by hand — spec R6) and
/// the « Demander à acheter » waiting state. Only drawn for a FREE user; the
/// caller decides that. The RESULT is not shown here: a verified purchase
/// flips the tier and removes this very view, so the alert lives on a
/// container that survives it (`proPurchaseResultAlert`).
struct ProPurchaseBlock: View {
    @Environment(ProStore.self) private var proStore
    @Environment(LocalizationManager.self) private var loc

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
                    Task { await proStore.purchase() }
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
    }
}

/// « Merci ! » / « Demande envoyée » / « Achat impossible » — the outcome
/// `ProStore` publishes (`lastOutcome`). Attached to the Pro page and to the
/// contextual sheet, i.e. to the containers that SURVIVE the tier flip a
/// purchase causes, and to exactly one of them at a time (a Pro page pushed
/// inside the sheet does not host it).
private struct ProPurchaseResultAlert: ViewModifier {
    @Environment(ProStore.self) private var proStore
    @Environment(LocalizationManager.self) private var loc
    let onPurchased: () -> Void

    func body(content: Content) -> some View {
        content.alert(
            title,
            isPresented: Binding(
                get: { proStore.lastOutcome != nil },
                set: { if !$0 { proStore.acknowledgeOutcome() } }
            )
        ) {
            Button(loc.localized("action.ok")) {
                // After the « Merci ! », not before it.
                let purchased = if case .purchased = proStore.lastOutcome { true } else { false }
                proStore.acknowledgeOutcome()
                if purchased { onPurchased() }
            }
        } message: {
            Text(message)
        }
    }

    private var title: String {
        switch proStore.lastOutcome {
        case .purchased: loc.localized("pro.result.success.title")
        case .pending: loc.localized("pro.result.pending.title")
        default: loc.localized("pro.result.failed.title")
        }
    }

    private var message: String {
        switch proStore.lastOutcome {
        case .purchased: loc.localized("pro.result.success.message")
        case .pending: loc.localized("pro.result.pending.message")
        default: loc.localized("pro.result.failed.message")
        }
    }
}

extension View {
    /// See `ProPurchaseResultAlert`. `onPurchased` runs once « Merci ! » is
    /// acknowledged — the contextual sheet closes itself there.
    func proPurchaseResultAlert(onPurchased: @escaping () -> Void = {}) -> some View {
        modifier(ProPurchaseResultAlert(onPurchased: onPurchased))
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
