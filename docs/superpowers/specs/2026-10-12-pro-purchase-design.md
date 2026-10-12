# Achat de JellyGlass Pro (lot 2)

Date : 2026-10-12. Branche `claude/pro-purchase`, empilée sur `claude/multi-accounts` (PR #313).

**Autorité** : les stories PRO-01 à PRO-09 et les maquettes « Achat Pro » (iPhone) et « Pro TV » du canevas https://claude.ai/artifact/TCMdw94pHz52ynawSHdjBL, validées par l'utilisateur le 12/10 (« Tu peux réaliser le développement », puis « Go pour le lot 2 »). Décisions produit déjà prises : 7,99 € en achat unique, sans essai, Partage familial, pas de pot à pourboire, fondateurs gratuits, la lecture n'est jamais payante. Ce document fixe ce que les stories laissent ouvert.

## 1. Périmètre

Dans le lot :
- moteur d'achat StoreKit 2 (`ProStore`) : produit, achat, restauration, achat en attente, mises à jour, remboursement, Partage familial ;
- branchement sur `EntitlementStore` (enregistrement local + miroir iCloud `entitlement.pro.v1`, existants) ;
- page « JellyGlass Pro » en tête des Réglages, iPhone/iPad et Apple TV ;
- feuille contextuelle d'une fonction verrouillée, appliquée à la seule fonction déjà verrouillée : les comptes mémorisés ;
- « Palier simulé » (Debug) gagne « Lancé » ;
- interrupteur de compilation `PRO_PREVIEW` pour les builds aperçu TestFlight.

Hors lot (lot 3) : verrouiller admin, « Regarder ensemble » (création), « Lire sur… », menu personnalisé, accents et icônes, thèmes hors saison, Raccourcis. Chacun avec son audit fondateurs. Avant le pivot, rien de tout cela ne se voit.

## 2. Règles tranchées

**R1 — Tester avant le lancement : `PRO_PREVIEW`, jamais une détection à l'exécution.** Avant le pivot, tout le monde est fondateur, donc une build TestFlight n'offre pas d'achat. La revue Apple tourne dans le même environnement « bac à sable » que TestFlight (`AppTransaction.environment == .sandbox` dans les deux cas, même reçu) : une règle « sandbox ⇒ lancé » mettrait un paywall devant le réviseur de chaque version 2.x, pour une fonction gratuite en production, avec un achat intégré non soumis. `ProFeatureGate.proLaunched` répond donc `true` sous `#if PRO_PREVIEW`, condition passée UNIQUEMENT sur la ligne de commande des archives aperçu (`SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) PRO_PREVIEW'`). **Une build aperçu ne se soumet jamais à la revue.** Après le pivot (3.0), les testeurs TestFlight sont « non production », donc pas fondateurs, donc gratuits : la recette PRO-09 se fait naturellement sur la RC 3.0.

**R2 — Produits** : un non-consommable par app, les bundle ids étant différents :
- `com.cinemax.ios.pro` (app iOS) ;
- `com.cinemax.tvos.pro` (app tvOS).
Partage familial activé, prix de base 7,99 €, nom « JellyGlass Pro ». À créer par l'utilisateur dans App Store Connect (l'accord « Applications payantes » doit être actif). L'app lit le prix dans `Product.displayPrice`, jamais en dur.

**R3 — La vérité sur la plateforme d'achat est `Transaction.currentEntitlements`.** À chaque lancement et retour au premier plan, `ProStore` parcourt les droits courants :
- un droit VÉRIFIÉ sur notre produit, non révoqué (achat ou Partage familial) ⇒ `recordPurchase` (local + miroir) si l'enregistrement diffère ;
- aucun droit et un enregistrement local écrit par CETTE app ⇒ retrait (`revokeOwnPurchase`).
`currentEntitlements` est un cache local de StoreKit : il répond hors ligne, sans contrôle réseau bloquant (PRO-08). Un compte App Store déconnecté ne voit plus son droit : comportement standard d'Apple, et sans perte de données (MC-12).

**R4 — Le miroir suit la révocation de SON auteur seulement.** `revokeOwnPurchase()` efface l'enregistrement local et retire le miroir iCloud quand son `writerBundleID` est celui de cette app ; le miroir de l'autre plateforme n'est jamais touché (règle existante de `clearLocal`). Sans ce retrait, un remboursement sur l'iPhone laisserait l'Apple TV en Pro pour toujours.

**R5 — Seule une transaction vérifiée débloque, puis `finish()`.** `.unverified` est journalisé et ignoré. `Transaction.updates` est écouté dès le lancement (PRO-05 : une approbation « Demander à acheter » débloque même app fermée entre-temps ; un remboursement arrive par là aussi). `AppStore.sync()` uniquement sur le geste « Restaurer les achats » (il peut demander le mot de passe Apple).

**R6 — Résultats d'achat** : succès ⇒ fenêtre « Merci ! » ; `.pending` ⇒ « Demande envoyée », le bouton d'achat est remplacé par cet état jusqu'à la fin du processus ; annulation ⇒ rien ; échec ⇒ « Achat impossible. Rien n'a été débité ». Produit introuvable (hors ligne, produit absent d'App Store Connect) ⇒ bouton désactivé et « Prix indisponible », jamais un prix inventé.

**R7 — Ce que la page affiche, par palier** : gratuit ⇒ liste Pro + « Toujours gratuit » + bouton d'achat + mentions ; fondateur ⇒ « Fondateur : tout est inclus », sans prix ; Pro ⇒ « Pro est actif ». « Restaurer les achats » reste visible dans tous les paliers (exigence de la revue). Conditions = licence standard d'Apple, Confidentialité = `https://b-raillard.github.io/Cinemax/privacy.html` (liens sur iOS, texte sur tvOS qui n'a pas de navigateur).

**R8 — Liste honnête.** Le catalogue `ProFeatureCatalogue` décrit les 8 fonctions des maquettes, chacune marquée `isGated`. Seuls les comptes mémorisés le sont dans ce lot. Un test échoue si le pivot de production est fixé alors qu'une fonction listée n'est pas encore verrouillée : on ne vend pas ce qui reste gratuit.

**R9 — Jamais de relance** : aucune fenêtre Pro au lancement, aucune relance automatique, jamais de cadenas sur un chemin de lecture.

**R10 — Debug** : « Palier simulé » passe à automatique → lancé → gratuit → Pro → fondateur. « Lancé » = `proLaunched` vrai et état réel : c'est lui qui permet le parcours gratuit → achat → Pro avec le fichier StoreKit local. « Gratuit » garde son sens (force gratuit).

## 3. Composants

- `Shared/Entitlements/ProProduct.swift` — identifiants par plateforme, `ProductSnapshot` (id, prix affiché, nom), `ProPurchaseOutcome`, `ProRestoreOutcome`.
- `Shared/Entitlements/ProPurchasePolicy.swift` — pur : `reconcile(localRecord:, entitlements:, ownBundleID:) -> Action` (`.record(record)` / `.revoke` / `.none`).
- `Shared/Entitlements/ProStore.swift` — `@MainActor @Observable`, singleton `AppNavigation.sharedProStore`, derrière un protocole `ProStoreClient` (réel : StoreKit 2 ; tests : faux). Publie `product`, `isPurchasing`, `isPending`, `lastOutcome`.
- `Shared/Entitlements/ProFeatureCatalogue.swift` — les 8 fonctions (titre, description, `isGated`).
- `EntitlementStore.revokeOwnPurchase()` + `CloudEntitlementMirror.remove()`.
- `ProFeatureGate` : `#if PRO_PREVIEW`, `ProTierOverride.launched`.
- UI : `Shared/Screens/Pro/ProScreen.swift` (iOS + tvOS), `ProUpsellSheet.swift`, `ProPurchaseResultView`. `SettingsCategory.pro` en tête (bannière sur iOS, pilule sur tvOS). La feuille contextuelle s'ouvre depuis la mention « Comptes mémorisés · PRO » de `UserSwitchSheet` (le chemin gratuit du changement de compte).
- `StoreKit/JellyGlass.storekit` — les deux produits, branché sur les schémas `Cinemax` / `CinemaxTV` (`storeKitConfiguration` de XcodeGen) pour les lancements depuis Xcode ; les tests passent par `SKTestSession`.

## 4. Tests

- Purs : `ProFeatureGate` (« Lancé », aperçu lu par `#if`), `ProPurchasePolicy` (achat, partage familial, révocation, autre auteur, non vérifié), catalogue honnête (R8).
- `ProStore` sur un faux client : succès, attente, annulation, échec, restauration vide, mise à jour révoquée.
- `EntitlementStore.revokeOwnPurchase` : miroir retiré si auteur = cette app, conservé sinon.
- StoreKit réel par `SKTestSession` sur `JellyGlass.storekit` : achat → droit courant → `recordPurchase` ; remboursement (`refundTransaction`) → retrait. Règle existante : `setSimulatedError(nil)` attendu en tête de test.
- Vérifier au simulateur, build Debug sans fichier StoreKit, qu'aucune demande de compte Apple n'apparaît au lancement (la règle `AppTransaction` ne s'étend pas d'office à `currentEntitlements`).
