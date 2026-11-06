# Multi-comptes sur un serveur — plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** mémoriser plusieurs comptes Jellyfin d'un même serveur, basculer d'un geste (code facultatif par compte), réglages propres à chaque compte, « Qui regarde ? » sur Apple TV — derrière la porte « Pro ou fondateur ».

**Architecture:** le triplet `accessToken/userId/username` de `ServerEntry` reste le compte ACTIF (tous les lecteurs existants inchangés) ; un champ optionnel `savedAccounts` porte les comptes mémorisés. Toute bascule et tout ajout passent par la fin de `AppState.applyActiveServer` (miroir, client, limite d'âge, extensions, rechargement niveau 1). Les réglages par compte gardent les clés globales comme valeur courante et échangent des instantanés à la bascule.

**Tech Stack:** Swift 6, SwiftUI (iOS 26 / tvOS 26), swift-testing, CinemaxKit (SPM local), xcodegen.

**Spec:** `docs/superpowers/specs/2026-10-12-multi-accounts-design.md`

## Global Constraints

- Tout champ ajouté à `ServerEntry` est OPTIONNEL (sinon `getServers()` renvoie `[]`).
- Aucune lecture d'`EntitlementStore` / de la porte sur un chemin de lecture.
- Une bascule ne révoque jamais un jeton ; seule « Retirer ce compte » / la déconnexion révoque, via `POST /Sessions/Logout`.
- Valider le jeton cible HORS du client partagé (`AppState.sessionValidator`).
- `@Observable` sans `didSet` ; mutateurs explicites.
- Toutes les chaînes via `loc.localized` en fr, en ET de ; un compte via `loc.counted` + `.one`.
- Nouveau fichier sous `Shared/` ou `Tests/` → `xcodegen generate`.
- Tests : `UserDefaults.isolatedForTesting()`, jamais d'attente fixe, suites complètes iOS + tvOS (jamais `-only-testing`), `set -o pipefail`.
- Builds locaux : `DEVELOPER_DIR=/Applications/Xcode-27.1-RC.app/Contents/Developer`, jamais iOS et tvOS en parallèle sur le même DerivedData.
- tvOS : pas de `.toolbar`, cover = chrome `WatchedHistoryScreen.tvHeader`, au moins un focusable dans chaque état.

## Review Focus

1. Registre déjà en trousseau sans `savedAccounts` → décode, le compte actif apparaît dans le sélecteur (Task 1 : test de décodage legacy + `accounts(of:)` qui inclut le triplet).
2. Retirer un compte NON actif pendant qu'on regarde avec un autre → la session active reste (seul le jeton retiré est révoqué) (Task 2 : en-tête du jeton révoqué ; Task 4 : `removeAccount` ne touche pas le triplet).
3. Bascule pendant que le serveur est lent → rien n'est détruit, on reste sur le compte courant (Task 4 : `.indeterminate`).
4. Compte ajouté depuis un appareil bridé à 10 ans → le nouveau compte hérite de 10 ans, jamais « aucune » (Task 5 : héritage).
5. Utilisateur gratuit (après lancement Pro) qui change de compte → l'ancien est oublié et révoqué, aucune accumulation silencieuse de jetons (Task 4).

---

### Task 1: Modèle `SavedAccount` + opérations pures du registre

**Files:**
- Create: `Packages/CinemaxKit/Sources/CinemaxKit/Models/SavedAccount.swift`
- Modify: `Packages/CinemaxKit/Sources/CinemaxKit/Models/ServerEntry.swift` (champ + init)
- Modify: `Packages/CinemaxKit/Sources/CinemaxKit/Models/ServerRegistry.swift` (`upsert`, nouvelles fonctions)
- Test: `Tests/CinemaxKitTests/ServerRegistryTests.swift` (nouvelle suite « Comptes mémorisés »)

**Interfaces — Produces:**
```swift
public struct SavedAccount: Codable, Sendable, Equatable, Identifiable {
    public var id: String { userId }
    public var userId: String
    public var username: String
    public var accessToken: String
    public var lastUsedAt: Date
}
// ServerEntry
public var savedAccounts: [SavedAccount]?
// ServerRegistry
public static func accounts(of entry: ServerEntry) -> [SavedAccount]          // mémorisés ∪ triplet actif, sans doublon, triés lastUsedAt desc
public static func remembering(userId: String, username: String, accessToken: String, at: Date, in entry: ServerEntry) -> ServerEntry
public static func activating(userId: String, in entry: ServerEntry) -> ServerEntry?   // nil si inconnu
public static func forgetting(userId: String, in entry: ServerEntry) -> ServerEntry   // si actif : triplet vidé
public static func nextAccount(after userId: String, in entry: ServerEntry) -> SavedAccount?
public static func accountKey(serverId: String, userId: String) -> String       // "serverId|userId"
```

- [ ] Step 1: tests — décodage d'un JSON `ServerEntry` sans `savedAccounts` ; `accounts(of:)` contient le triplet actif ; `remembering` insère puis met à jour par `userId` ; `activating` recopie dans le triplet et mémorise l'ancien actif ; `forgetting` de l'actif vide le triplet ; `upsert` conserve `savedAccounts` de l'entrée stockée ET met à jour le jeton du compte entrant ; `nextAccount` exclut le compte donné et prend le plus récent.
- [ ] Step 2: implémenter ; `upsert` : `merged.savedAccounts = existing.savedAccounts`, puis si `entry.userId/accessToken` présents → `remembering(...)` sur le fusionné.
- [ ] Step 3: build + suite iOS ; commit `feat(comptes): modèle SavedAccount et opérations du registre`.

### Task 2: Révocation par jeton (`POST /Sessions/Logout`)

**Files:**
- Modify: `Packages/CinemaxKit/Sources/CinemaxKit/Networking/ServerReachability.swift` (`ServerSessionRevoker.revoke`)
- Test: `Tests/CinemaxKitTests/ServerRegistryTests.swift` (suite « Révocation de session »), stub `URLProtocol` local au fichier

- [ ] Step 1: test — la requête est `POST`, chemin `<base>/Sessions/Logout` (sous-chemin conservé), en-tête `Authorization` contenant `Token="<jeton révoqué>"`, aucune query `id`.
- [ ] Step 2: implémenter (même session éphémère, même timeout, résultat ignoré) ; mettre à jour le commentaire (non-admin jamais révoqué, admin tuait tous les comptes).
- [ ] Step 3: commit `fix(session): révoquer le seul jeton du compte via /Sessions/Logout`.

### Task 3: Porte Pro pure

**Files:**
- Create: `Shared/Entitlements/ProFeatureGate.swift`
- Test: `Tests/CinemaxKitTests/EntitlementTests.swift` (suite « Porte des fonctions Pro »)

**Interfaces — Produces:**
```swift
enum ProFeatureGate {
    static func isUnlocked(proLaunched: Bool, isPro: Bool, isEarlyAdopter: Bool) -> Bool
    static var proLaunched: Bool   // EarlyAdopterConfiguration.production a un pivot
}
extension EntitlementStore { /* rien */ }
@MainActor func multiAccountUnlocked(entitlements: EntitlementStore, earlyAdopter: EarlyAdopterService) -> Bool
```
- [ ] Step 1: tests (table de vérité 8 lignes ; `proLaunched == false` aujourd'hui).
- [ ] Step 2: implémenter ; xcodegen ; commit `feat(droits): porte des fonctions Pro (ouverte avant le lancement)`.

### Task 4: Orchestration `AppState` (bascule, ajout, retrait)

**Files:**
- Modify: `Shared/Navigation/AppState.swift`
- Modify: `Shared/Screens/UserSwitchSheet.swift` (`performAuth` → `addAccount`)
- Modify: `Shared/ViewModels/LoginViewModel.swift` (`completeSession` mémorise via `upsertActiveEntry` — inchangé, `upsert` mémorise déjà)
- Test: `Tests/CinemaxKitTests/ServerRegistryTests.swift` (suite « Multi-comptes AppState »)

**Interfaces — Produces:**
```swift
var activeAccountKey: String?                                   // calculé
var multiAccountEnabled: Bool                                   // injecté par AppNavigation (porte)
var activeAccounts: [SavedAccount]                              // comptes du serveur actif
var expiredAccountIds: Set<String>                              // marqués par une validation .invalid
enum AccountSwitchResult { case switched, offline, needsLogin(SavedAccount), unreachable }
func switchAccount(to userId: String) async -> AccountSwitchResult
func addAccount(session: UserSession) async                     // gratuit : remplace + révoque l'ancien ; Pro : mémorise
func removeAccount(userId: String) async -> LogoutOutcome       // actif → bascule vers nextAccount sinon logout(.userInitiated)
```
- [ ] Step 1: tests — bascule valide (triplet, `currentUserId`, client reconnecté avec le jeton cible, niveau 1 posté) ; `.invalid` (compte ajouté à `expiredAccountIds`, rien d'autre ne change) ; `.indeterminate` (rien ne change) ; hors ligne ; `addAccount` gratuit (ancien oublié + révoqué) et Pro (deux comptes) ; `removeAccount` d'un compte non actif (triplet intact) puis de l'actif (bascule vers l'autre) ; `logout(.userInitiated)` avec un autre compte sur le même serveur → bascule vers lui avant tout autre serveur.
- [ ] Step 2: implémenter ; `switchAccount` construit l'entrée cible via `ServerRegistry.activating` puis appelle `applyActiveServer` ; `addAccount` écrit le miroir puis `applyActiveServer(entry)` (supprime l'écriture directe dans `UserSwitchSheet`) ; `logout` : candidat même serveur d'abord.
- [ ] Step 3: commit `feat(comptes): bascule, ajout et retrait de comptes dans AppState`.

### Task 5: Réglages par compte

**Files:**
- Create: `Shared/ViewModels/AccountSettingsStore.swift` (instantanés `accentColor` / `darkMode` / `privacy.maxContentAge` par clé de compte, clé `account.settings`)
- Modify: `Shared/Navigation/AppState.swift` (échange de la limite d'âge AVANT reconnect/niveau 1)
- Modify: `Shared/Navigation/AppNavigation.swift` (observateur `activeAccountKey` à la place de `activeServerId`, en premier ; échange accent/thème via `ThemeManager`)
- Modify: `Shared/Navigation/MenuConfig.swift` (`activate(profileId:seedFrom:knownProfileIds:)`)
- Modify: `Shared/ViewModels/SearchHistoryStore.swift`, `SearchViewModel.swift`, `Shared/Screens/SearchScreen.swift`
- Modify: `Shared/DesignSystem/SettingsKeys.swift`
- Test: `Tests/CinemaxKitTests/AccountSettingsTests.swift` (nouveau) + ajustements `MenuConfigStoreTests`, `SearchHistoryTests`

- [ ] Step 1: tests — échange (A→B sauve A, charge B) ; héritage (B sans instantané garde les valeurs courantes) ; profil de menu d'un compte semé une fois depuis celui du serveur (marqueur) ; historique de recherche par compte semé une fois depuis celui du serveur ; retrait d'un compte efface ses instantanés.
- [ ] Step 2: implémenter ; commit `feat(comptes): réglages propres à chaque compte`.

### Task 6: Code par compte

**Files:**
- Modify: `Packages/CinemaxKit/Sources/CinemaxKit/Models/ParentalLock.swift` (`makeCredential(pin:minimumLength:…)`, défaut = `minPINLength`)
- Modify: `Packages/CinemaxKit/Sources/CinemaxKit/Persistence/KeychainService.swift` (`getAccountLock/saveAccountLock/deleteAccountLock(key:)`, compte `account_lock.<key>`, privé)
- Create: `Shared/Screens/Accounts/AccountLockStore.swift`
- Modify: `Shared/Screens/Settings/ParentalLockGate.swift` (`ParentalPINPad(maxLength:)`, `ParentalPINDots` interne)
- Test: `Tests/CinemaxKitTests/AccountLockTests.swift` (nouveau)

- [ ] Step 1: tests — code à 4 chiffres accepté pour un compte, refusé (6 mini) pour le contrôle parental ; vérification + back-off identiques ; deux comptes = deux identifiants indépendants.
- [ ] Step 2: implémenter ; commit `feat(comptes): code facultatif par compte`.

### Task 7: Interface iOS / iPadOS

**Files:**
- Create: `Shared/Screens/Accounts/AccountSwitcherView.swift` (grille, ajouter, gérer, mes serveurs ; code ; session expirée)
- Create: `Shared/Screens/Accounts/AccountManageView.swift` (liste + détail : code, Face ID, limite d'âge derrière `ParentalLockGate`, retirer)
- Create: `Shared/Screens/Accounts/AccountAvatarButton.swift`
- Modify: `Shared/Screens/HomeScreen.swift` (`ToolbarItem(.topBarTrailing)` iOS)
- Modify: `Shared/Screens/Settings/SettingsScreen+iOS.swift` (« Changer de compte » ouvre le sélecteur quand la porte est ouverte)
- Modify: `Resources/{fr,en,de}.lproj/Localizable.strings`

- [ ] Step 1: construire, présenter en `.popover` (feuille en largeur compacte) ; « Ajouter » ouvre `UserSwitchSheet` ; porte fermée → `UserSwitchSheet` direct.
- [ ] Step 2: build iOS + suite ; commit `feat(comptes): sélecteur de profils iOS et iPadOS`.

### Task 8: Interface tvOS

**Files:**
- Create: `Shared/Screens/Accounts/WhoIsWatchingScreen.swift` (modes `.launch` et `.tab`)
- Modify: `Shared/Navigation/AppNavigation.swift` (cover au lancement avant « Quoi de neuf »)
- Modify: `Shared/Navigation/MainTabView.swift` (onglet « Profil » de tête — remplacé le 14/10 par un avatar à gauche de la barre, TV-10)
- Modify: `Shared/Navigation/TVBackNavigation.swift` si le repli doit ignorer l'onglet
- Modify: `Shared/Screens/Settings/SettingsTVProfileSection.swift`
- Modify: `Shared/DesignSystem/SettingsKeys.swift` (`accounts.askOnLaunch`, défaut `true`)

- [ ] Step 1: construire ; build tvOS + suite ; commit `feat(comptes): « Qui regarde ? » sur Apple TV`.

### Task 9: Docs, recette, PR

- [ ] Mettre à jour `docs/rules/server-setup-and-multi-server.md`, `Shared/Navigation/CLAUDE.md`, `Shared/Screens/Settings/CLAUDE.md`, `Shared/Entitlements/CLAUDE.md`, `Packages/CinemaxKit/CLAUDE.md` (révocation).
- [ ] Suites complètes iOS + tvOS, SwiftLint, parité de localisation.
- [ ] Recette au simulateur (compte de démo, iPhone D5222D2F + Apple TV démo D8FA6F76 uniquement).
- [ ] PR (fusion manuelle).
