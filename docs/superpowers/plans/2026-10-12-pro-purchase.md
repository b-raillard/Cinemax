# Achat Pro (lot 2) — plan

**Spec** : `docs/superpowers/specs/2026-10-12-pro-purchase-design.md` (autorité : stories PRO-01…09).
**Branche** : `claude/pro-purchase`, empilée sur `claude/multi-accounts`.

## Contraintes globales
- Swift 6 strict, `@Observable` sans `didSet`, mutateurs explicites (règles racine).
- Toute chaîne via `loc.localized`, clés fr/en/de, script de parité vert.
- Nouveau fichier ⇒ `xcodegen generate` ; nouveau fichier de test ⇒ idem.
- Jamais de lecture d'`EntitlementStore` / `ProStore` sur un chemin de lecture.
- Tests : `UserDefaults.isolatedForTesting()`, `InMemoryCloudKeyValueStore`, jamais de `sleep` (`eventually`).
- Suites complètes iOS + tvOS, grep `✔ Test run with`, SwiftLint 0.63.2 strict.

## Tâches
1. **Palier : aperçu + « Lancé »** — `ProFeatureGate` (`#if PRO_PREVIEW`), `ProTierOverride.launched`, texte Debug. Tests purs.
2. **Révocation de son propre achat** — `CloudEntitlementMirror.remove()`, `EntitlementStore.revokeOwnPurchase(ownBundleID:)`. Tests miroir conservé / retiré.
3. **Politique pure** — `ProProduct` (ids, snapshots, issues), `ProPurchasePolicy.reconcile`. Tests : achat, partage familial, révoqué, non vérifié, autre produit, autre auteur, rien à faire.
4. **`ProStore`** — protocole `ProStoreClient`, client StoreKit 2 réel, store observable (produit, achat, restauration, attente, `Transaction.updates`, `currentEntitlements`), singleton + câblage `AppNavigation` (lancement + `.active`). Tests sur faux client.
5. **StoreKit local** — `StoreKit/JellyGlass.storekit` (2 produits, partage familial), `storeKitConfiguration` des deux schémas, suite `SKTestSession` (achat → enregistré, remboursement → retiré).
6. **Catalogue** — `ProFeatureCatalogue` (8 fonctions, `isGated`), test « pas de pivot tant qu'une fonction listée est libre ».
7. **Page Pro** — `ProScreen` iOS + tvOS (paliers, prix, attente, résultat, restaurer, mentions), `SettingsCategory.pro` en tête (bannière iOS, pilule tvOS), chaînes fr/en/de.
8. **Feuille contextuelle** — `ProUpsellSheet`, mention « Comptes mémorisés · PRO » dans `UserSwitchSheet` (palier gratuit), iOS + tvOS.
9. **Docs + vérifications** — `Shared/Entitlements/CLAUDE.md`, `Settings/CLAUDE.md`, mémoire ; suites, lint, parité ; contrôle simulateur (pas de demande de compte au lancement Debug, page Pro par palier).
10. **Revue finale** (sous-agent) puis PR empilée.
