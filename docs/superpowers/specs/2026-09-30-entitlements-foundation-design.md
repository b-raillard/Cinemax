# Droits Gratuit / Pro : la fondation

Date : 2026-09-30. Statut : stratégie décidée avec l'utilisateur ; cette PR ne pose que la fondation technique (aucun StoreKit, rien de verrouillé).

## 1. Intention

JellyGlass est gratuite (Tier 0) et le restera pour tout ce qui sert à **regarder**. Un déverrouillage « Pro » à **achat unique** financera le projet plus tard, sur des fonctions de confort et d'administration. La lecture est gratuite pour toujours : c'est une règle de produit, et une RULE dans `Shared/Entitlements/CLAUDE.md`.

## 2. Gratuit vs Pro (cible, rien n'est verrouillé aujourd'hui)

| Gratuit (pour toujours) | Pro (candidat) |
|---|---|
| Connexion, Quick Connect, multi-serveur | Administration du serveur (écrans Admin) |
| Bibliothèque, fiches, recherche, historique | **Créer** une séance « Regarder ensemble » (la **rejoindre** reste gratuit) |
| Le lecteur entier (VLC + natif, pistes, sous-titres, sauts, chapitres, PiP) | « Lire sur… » (télécommande d'un autre appareil) |
| Widgets, Top Shelf | Menu personnalisé |
| Minuteur de mise en veille | Thèmes saisonniers, accents, icônes |
| | Raccourcis / App Intents / Control Center |

## 3. Prix et séquence

- **Prix cible : ~7,99 € en achat unique**, non-consommable, avec **Partage familial**.
- **Séquence :**
  1. d'abord un **pot à pourboire** IAP (consommables), sans aucun verrouillage — on teste StoreKit, la fiche et la revue sans rien retirer à personne ;
  2. **Pro à la 3.0** ;
  3. **« Fondateurs »** : tout utilisateur dont `AppTransaction.originalPurchaseDate` est **antérieure au lancement de Pro** garde tout gratuitement. `AppTransaction` n'est appelé que sur un geste explicite de l'utilisateur (voir la RULE : en Debug, il déclenche une invite de compte sandbox).

## 4. Pourquoi un miroir par le iCloud Key-Value Store

Les bundle ids diffèrent (`com.cinemax.ios`, `com.cinemax.tvos`) : ce sont deux apps pour l'App Store, donc **pas d'achat universel** — un non-consommable acheté sur iPhone n'apparaît pas dans `Transaction.currentEntitlements` de l'Apple TV. Fusionner les bundle ids casserait l'installation existante (nouvelle app).

Le **iCloud Key-Value Store** partagé comble ce trou : les deux apps déclarent le même `com.apple.developer.ubiquity-kvstore-identifier` (`$(TeamIdentifierPrefix)com.cinemax.shared`), donc lisent le même magasin sur le même compte iCloud. La plateforme d'achat y écrit un `CloudEntitlementRecord` (clé `entitlement.pro.v1`) ; l'autre le lit et passe en `.pro(.cloudMirror)`. Pas de CloudKit, pas de conteneur `icloud-services` : c'est exactement ce qu'ajoute la case « Key-value storage » de Xcode.

Limites assumées : le KVS est une commodité (synchronisation différée, 1 Mo, pas de contrôle serveur). Sur la plateforme d'achat, la vérité sera StoreKit. L'enregistrement garde le JWS StoreKit (`signedTransaction`) pour qu'un lecteur futur vérifie plutôt que de croire le blob.

## 5. Ce que pose cette PR

- `Shared/Entitlements/` : `EntitlementState`, `EntitlementPolicy` (pure), `CloudEntitlementRecord` (versionné, décodage tolérant), `CloudKeyValueStore` (protocole + adaptateur `NSUbiquitousKeyValueStore`), `CloudEntitlementMirror`, `EntitlementStore` (`@MainActor @Observable`, singleton racine injecté).
- Entitlement KVS dans les deux apps (pas le widget ni le Top Shelf).
- Réglages → Lecture → Débogage : ligne « Droits » en lecture seule, « Simuler Pro » en Debug seulement.
- Tests : `EntitlementTests.swift`.

Hors périmètre : `import StoreKit`, `AppTransaction`, toute UI d'achat, tout verrouillage.

## 6. Risques App Review

- **5.2.3** (déjà sensible pour l'app : téléchargements hors ligne retirés deux fois) : verrouiller des fonctions d'un client d'un serveur tiers ne doit jamais ressembler à faire payer l'accès au contenu. D'où la RULE « la lecture n'est jamais payante » et une fiche qui dit clairement que le contenu vient du serveur de l'utilisateur.
- **3.1.1** : tout déverrouillage de fonction dans l'app passe par l'IAP ; aucun lien ni mention d'un autre moyen de paiement. Le miroir iCloud ne déverrouille que ce qui a été acheté par IAP sur l'autre plateforme du même compte (même logique que « Restaurer ») — à expliquer dans les notes de revue.
- **3.1.2 / Partage familial** : non-consommable partageable, rien d'autre.
- La capacité iCloud doit être active sur les deux App IDs avant la première archive : la signature automatique l'ajoute avec `-allowProvisioningUpdates`, la CI (non signée) ne le voit pas.
