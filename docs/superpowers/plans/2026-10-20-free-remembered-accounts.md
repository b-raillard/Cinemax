# Comptes mémorisés en gratuit — plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** En gratuit, les comptes déjà connectés restent listés mais chaque bascule redemande une connexion (mot de passe ou Quick Connect) et ferme les autres sessions du serveur ; le Pro garde les sessions ouvertes.

**Architecture:** Un compte « déconnecté mais mémorisé » est un `SavedAccount` au jeton vide. `AppState` porte toute la décision gratuit / Pro (`keepsAccountSessions`) : `switchAccount` renvoie `.needsLogin` en gratuit après le contrôle parental, `addAccount` ferme (sans oublier) les sessions des autres comptes. Les écrans (iOS `AccountSwitcherView`, tvOS `WhoIsWatchingScreen`) deviennent communs aux deux paliers ; la reconnexion propose Quick Connect ou mot de passe, avec la ligne Pro sur l'étape mot de passe.

**Tech Stack:** Swift 6 strict, SwiftUI iOS 26 / tvOS 26, swift-testing, CinemaxKit.

**Spec:** `docs/superpowers/specs/2026-10-20-free-remembered-accounts-design.md`

## Global Constraints

- Gratuit = `!ProTier.unlocksProFeatures` via `AppState.multiAccountProvider` ; avant le pivot tout le monde est fondateur, on teste le gratuit par le « Palier simulé » Debug.
- « Une session ouverte » s'entend PAR SERVEUR.
- « Se déconnecter » volontaire retire le compte de la liste (inchangé) ; seule une bascule garde le compte quitté.
- Le code à 4 chiffres et Face ID par compte : Pro seulement ; en gratuit ni demandés ni effacés. « Qui regarde ? » au lancement : Pro seulement (inchangé).
- Toute chaîne via `loc.localized`, en fr / en / de (parité vérifiée par CI).
- Pas de nouveau fichier si possible (sinon `xcodegen generate`) ; aucun test n'écrit `UserDefaults.standard` (`UserDefaults.isolatedForTesting()`), aucun test ne dort (`eventually { }`).
- tvOS : focus initial jamais volé par une ligne Pro (règle « coin haut-gauche » de `Shared/DesignSystem/CLAUDE.md`).
- Lint SwiftLint strict épinglé, tests complets iOS + tvOS (`✔ Test run with N tests`).

## Review Focus

1. Compte gratuit qui a encore un jeton (reste d'une période Pro) : la bascule demande quand même la connexion, et ce jeton est révoqué après la connexion réussie. → test Task 2 `freeSwitchIgnoresLeftoverToken` + `freeSignInDropsLeftoverTokens`.
2. Hors ligne en gratuit : la bascule affiche « hors ligne » au lieu d'ouvrir une connexion vouée à l'échec. → test Task 2 `freeSwitchOffline`.
3. Quick Connect approuvé par un AUTRE utilisateur que la tuile choisie : on bascule sur celui qui a approuvé, la tuile choisie reste listée déconnectée. → couvert par `addAccount` (Task 2 `freeSignInKeepsOthersListed`), vérifié au simulateur (Task 4).
4. « Ajouter » (connexion SANS passer par une bascule) d'un compte moins bridé, code parental actif : la limite reste bridée (clamp). Seule la reconnexion issue d'une bascule autorisée saute le clamp. → test Task 2 `addAccountStillClampsWithoutGate`.
5. tvOS : l'étape mot de passe avec la ligne Pro s'ouvre le focus sur le champ ou le bouton de connexion, jamais sur la ligne. → vérification simulateur Task 4.

---

### Task 1: Registre — compte déconnecté mais mémorisé

**Files:**
- Modify: `Packages/CinemaxKit/Sources/CinemaxKit/Models/SavedAccount.swift`
- Modify: `Packages/CinemaxKit/Sources/CinemaxKit/Models/ServerRegistry.swift`
- Test: `Tests/CinemaxKitTests/MultiAccountTests.swift` (suite « Comptes mémorisés — registre »)

**Interfaces:**
- Produces: `SavedAccount.hasSession: Bool` (`!accessToken.isEmpty`) ; `ServerRegistry.droppingSession(userId: String, in entry: ServerEntry) -> ServerEntry` — garde le compte dans `savedAccounts` avec `accessToken = ""`, ne touche jamais au triplet actif (appelé seulement pour des comptes NON actifs).

- [ ] **Step 1: Tests** — `droppingSessionKeepsAccount` : household A actif + B mémorisé ; `droppingSession(userId: "B")` → `accounts(of:)` contient B avec `hasSession == false`, A intact (`accessToken == "tokA"`, `userId == "A"`). `droppingSessionOfUnknownIsNoOp` : userId inconnu → entrée inchangée. `activatingSessionlessAccount` : après `droppingSession("B")`, `activating(userId: "B")` rend une entrée dont `accessToken == ""` (le refus se fait dans `AppState`, Task 2). `upsertKeepsSessionlessAccount` : `upsert` d'une connexion de A ne réintroduit pas de jeton pour B.
- [ ] **Step 2:** lancer la suite iOS complète, constater l'échec de compilation (`droppingSession` inconnu).
- [ ] **Step 3:** implémenter `hasSession` et `droppingSession` (doc-comment : « session fermée, compte gardé — la bascule gratuite ; `forgetting` reste la sortie définitive »).
- [ ] **Step 4:** suite iOS complète verte.
- [ ] **Step 5: Commit** `feat(comptes): compte mémorisé sans session (registre)`.

### Task 2: AppState — bascule et connexion en gratuit

**Files:**
- Modify: `Shared/Navigation/AppState.swift` (`switchAccount`, `addAccount`, `requiresCode`, `clampSignInAgeCap` call site)
- Modify: `Shared/Screens/Accounts/AccountSwitchFlow.swift` (`hasOwnCode`, `isExpired` → `needsSignIn`)
- Test: `Tests/CinemaxKitTests/MultiAccountTests.swift` (suites « Multi-comptes — AppState », « Contrôle parental et bascule de compte », « Code par compte »)

**Interfaces:**
- Consumes: Task 1 `droppingSession`, `hasSession`.
- Produces:
  - `var keepsAccountSessions: Bool { multiAccountProvider() }` (AppState, internal) — LA question gratuit / Pro des écrans.
  - `func needsSignIn(_ account: SavedAccount) -> Bool` (extension AppState dans `AccountSwitchFlow.swift`, remplace les usages UI de `isExpired`) : `account.userId != currentUserId && (!keepsAccountSessions || !account.hasSession || isExpired(account))`.
  - `switchAccount` : code PROPRE au compte exigé seulement si `keepsAccountSessions` (dans `requiresCode`) ; contrôle parental inchangé ; puis, si `!keepsAccountSessions` → mémorise `pendingSignInKey = key` et renvoie `.needsLogin` (après la vérif `isOnlineProvider()`, donc `.offline` d'abord) ; en Pro, jeton vide → `.needsLogin` sans appel serveur (et `pendingSignInKey = key` aussi : la reconnexion d'un compte expiré a passé la même porte).
  - `private var pendingSignInKey: String?` ; `addAccount` saute `clampSignInAgeCap` quand la clé connectée == `pendingSignInKey`, puis le remet à `nil` (toujours).
  - `addAccount` en gratuit : pour CHAQUE autre compte du serveur ayant `hasSession` → `revokeTokenInBackground` + `droppingSession` ; plus aucun `forgetting` ni `forgetAccountData` sur ce chemin.
  - `AccountSwitchFlow.hasOwnCode` = `appState.keepsAccountSessions && locks.hasLock(key)`.

- [ ] **Step 1: Tests** (dans `MultiAccountAppStateTests`, avec `makeState(multiAccount: false, revoked:)`) :
  - `freeSwitchNeedsSignIn` : A actif, B mémorisé avec jeton ; `switchAccount(to: "B") == .needsLogin`, `currentUserId == "A"`, aucun appel `validateSession`.
  - `freeSwitchIgnoresLeftoverToken` : même chose avec `api.stubbedValidity = .valid` → toujours `.needsLogin`.
  - `freeSwitchOffline` : `isOnlineProvider = { false }` → `.offline`.
  - remplacer `addFree` par `freeSignInKeepsOthersListed` : connexion de C → `currentUserId == "C"`, `activeAccounts.map(\.userId)` contient `"A"` et `"C"`, A `hasSession == false`, `revoked.tokens == ["tokA"]` (`eventually`), instantané `AccountSettingsStore` de `S1|A` toujours présent (`settingsDefaults` isolé).
  - `freeSignInDropsLeftoverTokens` : A actif, B mémorisé avec `tokB` ; connexion de A à nouveau (même user) → B `hasSession == false`, `tokB` révoqué.
  - `proSwitchSessionlessNeedsLogin` : Pro, B déconnecté (`droppingSession`) → `.needsLogin`, aucun `validateSession`.
  - Pro inchangé : les tests existants « Bascule validée », « Ajout en Pro » restent verts sans modification.
  - Suite « Code par compte » : `freeIgnoresAccountCode` — gratuit, B avec code (`accountLockProvider = { $0 == "S1|B" }`) → `.needsLogin`, pas `.locked`.
  - Suite « Contrôle parental » : `freeParentalGateThenSignIn` — gratuit, code parental actif, B moins bridé → `switchAccount(to: "B") == .locked` ; `switchAccount(to: "B", unlocked: true) == .needsLogin` ; puis `addAccount(UserSession(B))` → la limite stockée de `S1|B` est INCHANGÉE (pas de clamp). `addAccountStillClampsWithoutGate` — même situation sans passer par `switchAccount` : `addAccount(B)` → limite de B ramenée à celle de A.
- [ ] **Step 2:** suite iOS complète : les nouveaux tests échouent (`.switched` / `.locked` au lieu de `.needsLogin`, comptes oubliés).
- [ ] **Step 3:** implémenter les interfaces ci-dessus ; mettre à jour les doc-comments de `switchAccount` (« en gratuit, une bascule est une connexion ») et `addAccount` (« gratuit : les autres sessions sont fermées, les comptes gardés »).
- [ ] **Step 4:** suite iOS complète verte, puis suite tvOS complète verte.
- [ ] **Step 5: Commit** `feat(comptes): en gratuit, chaque bascule est une connexion et ferme les autres sessions`.

### Task 3: Écrans — une liste pour tous, reconnexion Quick Connect ou mot de passe

**Files:**
- Modify: `Shared/Screens/Accounts/AccountSwitcherView.swift` (iOS : supprimer `freeContent`, `multiAccount`, le titre alternatif ; `isExpired:` des tuiles ← `appState.needsSignIn(account)` ; `flow.reconnect` ouvre un `confirmationDialog` « Se reconnecter » : Quick Connect / Mot de passe → `signInSheet(prefilled:)` avec `showsProReconnectHint: !appState.keepsAccountSessions`)
- Modify: `Shared/Screens/Accounts/WhoIsWatchingScreen.swift` (tvOS : tuiles ← `needsSignIn` ; `flow.reconnect` ouvre une étape de choix en plein écran sur le modèle de `addChoice` — titre `accounts.reconnect.title` (nom du compte), Quick Connect (accent) / Mot de passe / Annuler — et la ligne Pro en dessous en gratuit ; `TVAccountManageScreen` masque code et Face ID si `!keepsAccountSessions`)
- Modify: `Shared/Screens/UserSwitchSheet.swift` (remplacer `showsProHint` + `proHint` + le désarmement TV-09 par `showsProReconnectHint: Bool` affiché SOUS le bouton de l'étape mot de passe ; il ouvre `ProUpsellSheet(feature: .memorizedAccounts)`)
- Modify: `Shared/Screens/Accounts/AccountManageView.swift` (sections code / Face ID masquées si `!appState.keepsAccountSessions`)
- Modify: `Shared/Screens/Accounts/AccountSwitcherView.swift` `AccountTile` (libellé « déconnecté » quand déconnecté mais pas expiré)
- Modify: `Resources/{fr,en,de}.lproj/Localizable.strings`

**Interfaces:**
- Consumes: Task 2 `keepsAccountSessions`, `needsSignIn(_:)`, `AccountSwitchFlow.reconnect`.
- Produces: `UserSwitchSheet(prefilledUsername: String? = nil, showsProReconnectHint: Bool = false)`.
- Chaînes (fr / en / de) :
  - `accounts.reconnect.title` = « Se reconnecter à %@ » / « Sign in to %@ » / « Bei %@ anmelden »
  - `accounts.signedOut` = « Mot de passe requis » / « Password required » / « Passwort erforderlich »
  - `pro.reconnect.hint` = « Avec Pro, plus besoin de mot de passe pour changer de compte » / « With Pro, switch accounts without a password » / « Mit Pro wechselst du Konten ohne Passwort »

- [ ] **Step 1:** implémenter ; aucune logique nouvelle hors des vues (tout vient de Task 2).
- [ ] **Step 2:** builds iOS et tvOS (`** BUILD SUCCEEDED **`), parité des traductions (`python3 scripts/check-localization-parity.py`), lint strict sur les fichiers touchés.
- [ ] **Step 3: Commit** `feat(comptes): une liste de comptes pour tous, reconnexion Quick Connect ou mot de passe`.

### Task 4: Points d'entrée, textes Pro, docs et recette simulateur

**Files:**
- Modify: `Shared/Screens/Settings/SettingsScreen.swift` (« Changer de compte » : toujours `AccountSwitcherView` sur iOS / `WhoIsWatchingScreen(.cover)` sur tvOS ; supprimer `plainUserSwitchSheet` et `accountSwitchTier` s'ils n'ont plus d'usage)
- Modify: `Shared/Navigation/MainTabView.swift` (`showsTVAccountAvatar` → vrai dès qu'on est connecté, sans porte Pro)
- Modify: `Resources/{fr,en,de}.lproj/Localizable.strings` (`pro.feature.accounts.detail` : dire « chaque profil reste connecté, on bascule d'un geste, sans mot de passe, protégé par un code si besoin »)
- Modify: `docs/rules/server-setup-and-multi-server.md`, `Shared/Entitlements/CLAUDE.md`, `docs/superpowers/specs/2026-10-12-multi-accounts-design.md` (renvoi vers la spec du 20/10)

- [ ] **Step 1:** implémenter ; mettre à jour les docs (règle gratuit / Pro des comptes, avatar tvOS ouvert à tous).
- [ ] **Step 2:** suites complètes iOS et tvOS vertes, lint, parité.
- [ ] **Step 3: Recette simulateur** (iPhone de démo D5222D2F en FR, Apple TV de démo D8FA6F76 ; « Palier simulé » Gratuit ; restaurer après) :
  - iPhone : avatar → liste (compte courant + compte mémorisé « Mot de passe requis ») ; tuile → « Se reconnecter » Quick Connect / Mot de passe ; étape mot de passe avec la ligne Pro ; Pro : bascule d'un geste inchangée.
  - Apple TV : avatar à gauche de la barre présent en Gratuit ; tuile → étape de choix, focus initial sur Quick Connect ; étape mot de passe, focus initial jamais sur la ligne Pro ; Menu ramène à la liste.
  - Aucun aller-retour réel de connexion sur le compte personnel : uniquement le compte de démo (le mot de passe n'est jamais saisi par l'agent ; la recette s'arrête à l'écran de connexion).
- [ ] **Step 4: Commit** `feat(comptes): entrées et textes du gratuit, docs`.
