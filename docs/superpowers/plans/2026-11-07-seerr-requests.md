# Demandes Seerr intégrées — plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Demander un film, une série, des saisons ou les films manquants d'une saga depuis JellyGlass (recherche, fiche série, saga, page acteur), suivre ses demandes, valider celles des autres, avec Seerr derrière et sans jamais retarder ni déplacer le contenu Jellyfin.

**Architecture:** Un client Seerr autonome dans CinemaxKit (`Seerr/`, sa propre `URLSession` éphémère, transport injectable, CSRF et cookie gérés à la main), une configuration par utilisateur dans les DisplayPreferences Jellyfin, des secrets dans le trousseau de l'appareil. Côté app, un magasin racine `SeerrSession` (`@MainActor @Observable`) porte l'identité Seerr du compte actif, la reprise silencieuse et le jeton anti-réponse-périmée ; des politiques pures décident visibilité, « manquant » et badges ; chaque écran ajoute une section APRÈS le contenu possédé. Quatre PR : 1a base + Réglages, 1b recherche, 2 fiches, 3 suivi.

**Tech Stack:** Swift 6 strict, SwiftUI iOS 26 / tvOS 26, swift-testing, CinemaxKit, jellyfin-sdk-swift 3.2.0 (aucune dépendance ajoutée).

**Spec:** `docs/superpowers/specs/2026-11-06-seerr-requests-design.md` — lire en entier, surtout « Spike findings » (qui prime sur les sections plus haut quand ils diffèrent) et le tableau « Test connection ».

## Global Constraints

- Seerr ≥ 3.4 (`ServerVersion("3.4")`) ; Jellyfin ≥ 10.9 (plancher du projet) ; vérifié sur 10.11.0 et 12.0.0.
- DisplayPreferences : `displayPreferencesId` = `jellyglass-seerr`, `client` = `jellyglass`, `CustomPrefs["seerr.enabled"]` = `"true"`, `CustomPrefs["seerr.url"]` = l'adresse ; POST = remplacement complet ⇒ lecture-modification-écriture qui renvoie TOUT le dictionnaire.
- Trousseau : `seerr_sessions` (JSON `[accountKey: cookie]`, clé = `ServerRegistry.accountKey(serverId:userId:)`) et `seerr_api_keys` (JSON `[activeServerId: clé]`), non synchronisables, ajoutés à `KeychainService.privateAccounts`.
- Clé d'API : toute requête autre que `/status`, `/settings/public`, `/user/jellyfin/{id}` et `/settings/jellyfin` porte `X-API-User` — imposé par le TYPE (`SeerrCredential.apiKey` exige un `SeerrUserID`).
- `language=` (code de l'app) sur `/search`, `/movie/{id}`, `/tv/{id}`, `/collection/{id}`, `/person/{id}`, `/person/{id}/combined_credits` ; jamais d'autre paramètre de requête que ceux du `seerr-api.yml` (400 sinon).
- `GET /request` : Mes demandes et l'arrivée passent `requestedBy=<mon id Seerr>` (sinon un gestionnaire voit les demandes de toute la maison) ; À valider n'en passe pas.
- Une session morte et une clé refusée répondent 403 (jamais 401) : 403 ⇒ sonde (`/auth/me` ou `/user/jellyfin/{id}` sans `X-API-User`) avant de conclure.
- Jamais journalisés : en-têtes, cookies, `secret` Quick Connect, corps de `/settings/jellyfin`. `LogScrubber.tokenMarkers` reçoit `X-Api-Key:`, `connect.sid=`, `secret=`.
- Tout ce qui vient de Seerr se place APRÈS le contenu possédé ; rien de Seerr sur un compte bridé par âge (`privacy.maxContentAge` > 0 sur l'appareil OU `policy.maxParentalRating` non nil) ; aucun appel Seerr hors ligne, sans Pro, ou sans `seerr.enabled` ; le mot « Seerr » n'apparaît qu'en Réglages et dans l'invitation à se connecter.
- Chaînes via `loc.localized` / `loc.counted` en fr / en / de (parité CI) ; tvOS : aucune saisie hors adresse et clé de l'admin.
- Nouveaux fichiers sous `Shared/` ou `Tests/` ⇒ `xcodegen generate` ; aucun test n'écrit `UserDefaults.standard` ni ne dort (sauf un délai mesuré, comme l'échéance des squelettes) ; tests complets iOS ET tvOS (`-only-testing` exécute 0 test swift-testing).
- Commandes de vérification (les deux, en série, jamais en parallèle) :
  - `set -o pipefail; xcodebuild test -project Cinemax.xcodeproj -scheme Cinemax -destination 'platform=iOS Simulator,id=5AB90411-C80E-4060-A3C0-996579E229B9' -skipPackagePluginValidation 2>&1 | tee "$TMPDIR/ios-test.log" | grep -E '✘|✔ Test run|error:'` → attendu `✔ Test run with N tests … passed`
  - idem `-scheme CinemaxTV -destination 'platform=tvOS Simulator,id=699CCA2B-3C12-4BDC-B06A-B1C584B14CC9'`
- SwiftLint `--strict` bloque ; commits terminés par `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`, `git add` chemin par chemin ; aucune fusion sans demande explicite pour CETTE PR.

## Review Focus

1. **Bascule de profil pendant un chargement Seerr** (admin → enfant) : la réponse tardive n'apparaît jamais sur le profil suivant. → test Task 7 `staleAnswerIsDropped` + Task 15 `profileSwitchDropsSeerrSection`.
2. **Seerr éteint ou très lent** : la recherche montre ses résultats Jellyfin, le squelette disparaît sans message à l'échéance. → test Task 12 `slowSeerrSkeletonExpires` + Task 15 `unreachableSeerrShowsNothing`.
3. **Seerr derrière un sous-chemin avec `/api/v1` collé** (`https://hote/seerr/api/v1/`) : toutes les URL gardent `/seerr`. → test Task 2 `subPathAndPastedAPIPrefix`.
4. **CSRF activé, HTTP simple** : la première mutation reçoit `invalid csrf token`, le client rafraîchit la paire et réussit ; un second 403 CSRF ne boucle pas. → test Task 2 `csrfRefreshedOnceThenFails`.
5. **Session Seerr expirée** : un seul reconnexion silencieuse, puis l'état « Se connecter à Seerr » ; un vrai refus de droit (`/auth/me` = 200) ne déclenche aucune reconnexion. → tests Task 7 `deadSessionReSignsInOnce`, `genuineForbiddenDoesNotReSignIn`.

---

# PR 1 — Lot 1a : base et Réglages → Demandes

### Task 1: Modèles Seerr (CinemaxKit)

**Files:**
- Create: `Packages/CinemaxKit/Sources/CinemaxKit/Seerr/SeerrModels.swift`
- Test: `Tests/CinemaxKitTests/SeerrModelTests.swift` (nouveau ⇒ `xcodegen generate`)

**Interfaces:**
- Produces (tous `public`, `Sendable`, `Decodable`, `Equatable`) :
  - `SeerrStatusInfo { version: String }`
  - `SeerrPublicSettings { mediaServerType: Int; mediaServerLogin: Bool; newPlexLogin: Bool; partialRequestsEnabled: Bool; enableSpecialEpisodes: Bool; cacheImages: Bool }` + `var isJellyfin: Bool { mediaServerType == 2 }`
  - `SeerrPermissions: OptionSet` (`rawValue: Int`) : `admin` 2, `manageRequests` 16, `request` 32, `autoApprove` 128, `autoApproveMovie` 256, `autoApproveTV` 512, `requestView` 16384, `requestMovie` 262144, `requestTV` 524288 ; `func allows(_ p: SeerrPermissions) -> Bool` (vrai si `admin` ou tous les bits de `p`) ; `var canManageRequests: Bool` ; `func autoApproves(_ kind: SeerrMediaKind) -> Bool`
  - `SeerrUserID: Hashable, Sendable { rawValue: Int }`
  - `SeerrUser { id: SeerrUserID; permissions: SeerrPermissions; jellyfinUserId: String?; displayName: String? }` — décodé depuis `id`, `permissions`, `jellyfinUserId`, `displayName` (repli `jellyfinUsername`)
  - `SeerrMediaKind: String { movie, tv }`
  - `SeerrMediaStatus: Int` 1 unknown … 7 deleted, valeur inconnue ⇒ `.unknown`
  - `SeerrRequestStatus: Int` 1 pending, 2 approved, 3 declined, 4 failed, 5 completed, inconnu ⇒ `.pending`
  - `SeerrMediaInfo { status: SeerrMediaStatus; seasons: [SeerrSeasonInfo]; requests: [SeerrRequestSummary]; jellyfinMediaId: String? }`, `SeerrSeasonInfo { seasonNumber: Int; status: SeerrMediaStatus }`, `SeerrRequestSummary { id: Int; status: SeerrRequestStatus; seasons: [Int] }` (depuis `seasons[].seasonNumber`)
  - `SeerrTitle { kind: SeerrMediaKind; tmdbId: Int; title: String; year: Int?; overview: String?; posterPath: String?; mediaInfo: SeerrMediaInfo? }` — décodé d'un résultat Seerr (`mediaType`, `id`, `title` ou `name`, `releaseDate` ou `firstAirDate`) ; `mediaType` `person` / `collection` ⇒ ligne ignorée
  - `SeerrSearchPage { results: [SeerrTitle]; totalPages: Int }` (ignore les entrées non film / série)
  - `SeerrTVDetails { tmdbId: Int; name: String; seasons: [SeerrSeason]; mediaInfo: SeerrMediaInfo? }`, `SeerrSeason { seasonNumber: Int; episodeCount: Int }`
  - `SeerrCollection { id: Int; name: String; parts: [SeerrTitle] }`
  - `SeerrPerson { knownForDepartment: String? }`, `SeerrCombinedCredits { cast: [SeerrTitle]; crew: [SeerrTitle] }`
  - `SeerrRequest { id: Int; status: SeerrRequestStatus; kind: SeerrMediaKind; seasons: [Int]; createdAt: Date; updatedAt: Date; requestedBy: SeerrUser; media: SeerrRequestMedia }`, `SeerrRequestMedia { tmdbId: Int; status: SeerrMediaStatus; jellyfinMediaId: String? }`
  - `SeerrRequestPage { results: [SeerrRequest]; total: Int }` (depuis `pageInfo.results`)
  - `SeerrQuickConnectCode { code: String; secret: String }`
  - `enum SeerrJSON { static func decoder() -> JSONDecoder }` (dates ISO 8601 avec fractions)

- [ ] **Step 1: Écrire les tests de décodage** — un `@Suite("Seerr models")` avec des littéraux JSON tirés des réponses relevées dans l'essai (formes de la spec, § Spike findings) :
  - `searchDropsPeopleAndCollections` : `{"page":1,"totalPages":1,"totalResults":3,"results":[{"mediaType":"movie","id":438631,"title":"Dune","releaseDate":"2021-09-15"},{"mediaType":"person","id":1},{"mediaType":"tv","id":90228,"name":"Dune : Prophecy","firstAirDate":"2024-11-17","mediaInfo":{"status":2,"seasons":[],"requests":[{"id":2,"status":1,"seasons":[{"seasonNumber":1}]}]}}]}` → 2 titres, `[0].year == 2021`, `[1].kind == .tv`, `[1].mediaInfo?.requests.first?.seasons == [1]`
  - `unknownStatusesFallBack` : `"status": 9` ⇒ `.unknown` ; requête `"status": 9` ⇒ `.pending`
  - `permissionsAdminPassesEverything` : `SeerrPermissions(rawValue: 2).allows(.manageRequests)` ; `SeerrPermissions(rawValue: 32).canManageRequests == false`
  - `requestPageTotalComesFromPageInfo` : `{"pageInfo":{"pages":5,"pageSize":1,"results":5,"page":1},"results":[…]}` → `total == 5`, `media.jellyfinMediaId` lu
  - `tvKeepsSeasonZero` : `seasons` `[{"seasonNumber":0,"episodeCount":17},{"seasonNumber":1,"episodeCount":6}]` conservées telles quelles
- [ ] **Step 2: `xcodegen generate`, lancer la suite iOS** → échec de compilation (types absents).
- [ ] **Step 3: Implémenter les types** dans `SeerrModels.swift` (`init(from:)` à la main seulement là où `title`/`name` et `releaseDate`/`firstAirDate` fusionnent, et pour les valeurs d'énumération inconnues).
- [ ] **Step 4: Relancer la suite iOS** → `Suite "Seerr models"` verte.
- [ ] **Step 5: Commit** — `feat(seerr): modèles CinemaxKit`.

### Task 2: Adresse, transport et cœur du client (CSRF, erreurs, langue, redirections)

**Files:**
- Create: `Packages/CinemaxKit/Sources/CinemaxKit/Seerr/SeerrAddress.swift`, `Packages/CinemaxKit/Sources/CinemaxKit/Seerr/SeerrClient.swift`
- Test: `Tests/CinemaxKitTests/SeerrClientTests.swift` (nouveau) — y définir `final class StubSeerrTransport: SeerrTransport, @unchecked Sendable` (file de réponses `(status, headers, body)` + requêtes enregistrées)

**Interfaces:**
- Consumes: Task 1 ; `URLComponents.setEndpointPath(_:preservingBasePathOf:)` (interne au module) ; `ServerURLNormalizer.normalize(_ url: URL)`.
- Produces:
  - `public enum SeerrAddress { static func normalize(_ raw: String) -> URL? }` — sans schéma ⇒ `http://` (Seerr écoute en HTTP sur 5055 ; une adresse publique se colle en entier depuis le navigateur), puis `ServerURLNormalizer.normalize`, puis retrait d'un suffixe `/api/v1` (avec ou sans `/` final)
  - `public protocol SeerrTransport: Sendable { func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) }` ; `public static func makeDefaultTransport() -> any SeerrTransport` = `URLSession` `.ephemeral`, `urlCache = nil`, `httpCookieStorage = nil`, `httpShouldSetCookies = false`, délai 10 s, délégué de tâche qui ne suit une redirection que si `AuthenticatedRedirect.keepsCredentials(from:to:)` l'admet (même hôte, passage à https) et la refuse sinon, confiance système (pas de `ServerTrustDelegate` : non-goal)
  - `public enum SeerrCredential: Sendable, Equatable { case session(cookie: String); case apiKey(key: String, user: SeerrUserID) }`
  - `public enum SeerrLookupAuth: Sendable, Equatable { case session(cookie: String); case adminKey(String) }` — seule forme admise pour `/user/jellyfin/{id}` et `/settings/jellyfin`
  - `public enum SeerrError: Error, Equatable { case unreachable, notSeerr, redirected, forbidden, csrfRejected, notFound, duplicate, noSeasonsAvailable, accessDenied, http(Int) }`
  - `public final class SeerrClient: Sendable { public init(baseURL: URL, languageCode: String?, transport: any SeerrTransport = SeerrClient.makeDefaultTransport()); public let baseURL: URL }` et, interne : `func get<T: Decodable>(_ path: String, query: [URLQueryItem], auth: Auth, localized: Bool) async throws -> T`, `func mutate<T: Decodable>(_ method: String, _ path: String, body: Encodable?, auth: Auth) async throws -> (T?, Int)` où `enum Auth { case none, credential(SeerrCredential), lookup(SeerrLookupAuth) }`
- Règles d'implémentation (que les tests verrouillent) :
  - URL = `baseURL` + `/api/v1` + chemin via `setEndpointPath`, `language=` ajouté seulement si `localized` et code non nil.
  - En-têtes : session ⇒ `Cookie: connect.sid=<cookie>` ; clé ⇒ `X-Api-Key` (+ `X-API-User` pour `.apiKey`) ; mutation ⇒ en plus la paire CSRF si connue (`_csrf` ajouté au `Cookie`, `X-XSRF-TOKEN`).
  - Cookies lus par `HTTPCookie.cookies(withResponseHeaderFields:for:)` (jamais un découpage de `Set-Cookie` à la main : sans stockage de cookies les trois cookies arrivent joints par des virgules, et leurs `Expires=` en contiennent).
  - Paire CSRF : relevée dans le `Set-Cookie` de TOUTE réponse (`_csrf`, `XSRF-TOKEN`), gardée sous un `NSLock` ; 403 dont le corps `message` contient `csrf` ⇒ `GET /status`, puis UNE nouvelle tentative ; second échec ⇒ `.csrfRejected`.
  - Statuts : transport en erreur ⇒ `.unreachable` ; 3xx refusé ⇒ `.redirected` ; corps 2xx non décodable sur `/status` ⇒ `.notSeerr` ; 403 ⇒ `.forbidden` (corps `{"message":"Access denied."}` ⇒ `.accessDenied`) ; 404 ⇒ `.notFound` ; 409 ⇒ `.duplicate` ; 202 sur `POST /request` ⇒ `.noSeasonsAvailable` ; autre ⇒ `.http(code)`.
  - Aucun `Logger` ne reçoit d'URL complète, d'en-tête ni de corps (échec de décodage compris) : seulement méthode + chemin + statut.

- [ ] **Step 1: Écrire les tests** (`@Suite("Seerr client core")`) :
  - `subPathAndPastedAPIPrefix` : `SeerrAddress.normalize("https://hote/seerr/api/v1/")` → `https://hote/seerr` ; requête `search` construite → chemin `/seerr/api/v1/search`
  - `bareHostGetsHTTP` : `"192.168.1.20:5055"` → `http://192.168.1.20:5055`
  - `languageOnlyOnLocalizedRoutes` : `get("/search", localized: true)` porte `language=fr` ; `get("/status", localized: false)` n'en porte pas
  - `apiKeyAlwaysCarriesUser` : `.apiKey(key: "k", user: SeerrUserID(rawValue: 3))` ⇒ en-têtes `X-Api-Key: k` et `X-API-User: 3` ; `.lookup(.adminKey("k"))` ⇒ `X-Api-Key` sans `X-API-User`
  - `csrfRefreshedOnceThenFails` : réponses `403 {"message":"invalid csrf token"}`, `200 /status` avec `Set-Cookie: _csrf=a; …`, `Set-Cookie: XSRF-TOKEN=b; …`, puis `201` ⇒ succès, la 3e requête porte `Cookie` contenant `_csrf=a` et `X-XSRF-TOKEN: b` ; même scénario avec un second 403 CSRF ⇒ `.csrfRejected`, exactement 3 requêtes
  - `statusMapping` : 302 refusé ⇒ `.redirected` ; 403 `{"error":"You do not have permission…"}` ⇒ `.forbidden` ; 403 `{"message":"Access denied."}` ⇒ `.accessDenied` ; 409 ⇒ `.duplicate` ; erreur transport ⇒ `.unreachable` ; `/status` 200 `<html>` ⇒ `.notSeerr`
- [ ] **Step 2: `xcodegen generate`, lancer la suite iOS** → échec de compilation.
- [ ] **Step 3: Implémenter `SeerrAddress` et `SeerrClient`** selon les règles ci-dessus (la paire CSRF dans un `struct` sous `NSLock`, comme `ClientState`).
- [ ] **Step 4: Relancer** → `Suite "Seerr client core"` verte.
- [ ] **Step 5: Commit** — `feat(seerr): client CinemaxKit — adresse, CSRF, erreurs`.

### Task 3: Points d'accès du client

**Files:**
- Create: `Packages/CinemaxKit/Sources/CinemaxKit/Seerr/SeerrClient+Endpoints.swift`
- Test: `Tests/CinemaxKitTests/SeerrClientTests.swift` (ajout)

**Interfaces:**
- Consumes: Task 2 (`get`, `mutate`, `Auth`).
- Produces (méthodes `public` de `SeerrClient`) :
  - `status() async throws -> SeerrStatusInfo`, `publicSettings() async throws -> SeerrPublicSettings`
  - `quickConnectInitiate() async throws -> SeerrQuickConnectCode`, `quickConnectCheck(secret: String) async throws -> Bool`, `quickConnectAuthenticate(secret: String) async throws -> (cookie: String, user: SeerrUser)` (cookie lu dans `Set-Cookie: connect.sid=…`)
  - `me(_ c: SeerrCredential) async throws -> SeerrUser`
  - `user(forJellyfinUserId id: String, auth: SeerrLookupAuth) async throws -> SeerrUser?` (404 ⇒ `nil`)
  - `jellyfinServerId(adminKey: String) async throws -> String` (lit seulement `serverId` ; le corps n'est jamais journalisé)
  - `search(_ query: String, _ c: SeerrCredential) async throws -> [SeerrTitle]` (page 1)
  - `movie(tmdbId: Int, _ c) -> SeerrTitle`, `tv(tmdbId: Int, _ c) -> SeerrTVDetails`, `collection(id: Int, _ c) -> SeerrCollection`, `person(id: Int, _ c) -> SeerrPerson`, `combinedCredits(personId: Int, _ c) -> SeerrCombinedCredits`
  - `public enum SeerrNewRequest: Sendable, Equatable { case movie(tmdbId: Int); case tv(tmdbId: Int, seasons: [Int]) }` ; `createRequest(_ r: SeerrNewRequest, _ c) async throws -> SeerrRequest` (corps `{mediaType, mediaId, seasons}`)
  - `public enum SeerrRequestFilter: String { all, pending, available }` ; `requests(filter: SeerrRequestFilter, take: Int, skip: Int, requestedBy: SeerrUserID?, _ c) async throws -> SeerrRequestPage` (`sort=modified` toujours ; `requestedBy` seulement s'il est fourni)
  - `approve(requestId: Int, _ c) async throws`, `decline(requestId: Int, _ c) async throws`
  - `logout(cookie: String) async` (erreurs avalées)

- [ ] **Step 1: Tests** (`@Suite("Seerr client endpoints")`) — pour chaque méthode, méthode HTTP + chemin + paramètres exacts sur le `StubSeerrTransport` :
  - `requestsQuery` → `GET /api/v1/request?take=20&skip=40&filter=pending&sort=modified` sans `requestedBy` quand `nil`, avec `requestedBy=2` quand fourni
  - `createTVRequestBody` → corps JSON `{"mediaType":"tv","mediaId":90228,"seasons":[4,5]}`
  - `quickConnectAuthenticateReadsCookie` → trois `Set-Cookie` (`connect.sid=s%3Aabc.def; Path=/; Expires=Thu, 07 Dec 2026 06:11:38 GMT; HttpOnly`, `_csrf=x; …`, `XSRF-TOKEN=y; …`) ⇒ `cookie == "s%3Aabc.def"`, paire CSRF `x` / `y`
  - `lookupNotFoundIsNil` → 404 ⇒ `nil`
  - `approveIsPOST` → `POST /api/v1/request/7/approve`
- [ ] **Step 2: Lancer** → échec de compilation.
- [ ] **Step 3: Implémenter** les méthodes sur `get` / `mutate`.
- [ ] **Step 4: Relancer** → verte.
- [ ] **Step 5: Commit** — `feat(seerr): points d'accès du client`.

### Task 4: Connexion en un geste (Quick Connect)

**Files:**
- Create: `Packages/CinemaxKit/Sources/CinemaxKit/Seerr/SeerrQuickConnectSignIn.swift`
- Test: `Tests/CinemaxKitTests/SeerrClientTests.swift` (ajout)

**Interfaces:**
- Consumes: Task 3 ; côté Jellyfin, `AuthAPI.authorizeQuickConnect(code:) async throws -> Bool` (erreur brute `Get.APIError.unacceptableStatusCode(Int)`).
- Produces:
  - `public enum SeerrSignInError: Error, Equatable { case seerr(SeerrError); case otherJellyfin; case jellyfinRefused; case notImported; case timedOut }`
  - `public struct SeerrQuickConnectSignIn: Sendable { public init(client: SeerrClient, approve: @escaping @Sendable (String) async throws -> Bool, maxChecks: Int = 10, pause: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(1)) }); public func run() async throws(SeerrSignInError) -> (cookie: String, user: SeerrUser) }`
  - `public static func classifyApproval(_ error: Error) -> SeerrSignInError` : statut 404 ⇒ `.otherJellyfin`, 403 ⇒ `.jellyfinRefused`, sinon `.seerr(.unreachable)`. `approve` qui renvoie `false` ⇒ `.otherJellyfin`.
  - Ordre : `initiate` → `approve(code)` → `check` (premier appel SANS pause ; puis `pause()` entre deux, au plus `maxChecks`) → `authenticate` ; `authenticate` 403 `accessDenied` ⇒ `.notImported`.

- [ ] **Step 1: Tests** (`@Suite("Seerr Quick Connect sign-in")`, `pause: {}` partout — aucun test ne dort) :
  - `signsInWithoutTyping` : initiate `{code:"123456",secret:"s"}`, approve renvoie `true`, check `{"authenticated":true}`, authenticate 200 + cookie ⇒ cookie et `SeerrUser.id == 2` ; `approve` appelé avec `"123456"`
  - `approval404IsOtherJellyfin` : approve lève `unacceptableStatusCode(404)` ⇒ `.otherJellyfin`
  - `approval403IsRefused` ⇒ `.jellyfinRefused`
  - `unimportedUser` : authenticate `403 {"message":"Access denied."}` ⇒ `.notImported`
  - `checkGivesUp` : check toujours `false`, `maxChecks: 3` ⇒ `.timedOut`, 3 appels `check`
- [ ] **Step 2: Lancer** → échec de compilation.
- [ ] **Step 3: Implémenter.**
- [ ] **Step 4: Relancer** → verte.
- [ ] **Step 5: Commit** — `feat(seerr): connexion Quick Connect sans saisie`.

### Task 5: Secrets du trousseau et configuration DisplayPreferences

**Files:**
- Modify: `Packages/CinemaxKit/Sources/CinemaxKit/Persistence/KeychainService.swift` (nouvelles méthodes à côté de `getTrustedCertificates` — les primitives sont `private`, l'extension doit vivre dans CE fichier ; comptes ajoutés à `privateAccounts`, L377)
- Create: `Packages/CinemaxKit/Sources/CinemaxKit/Seerr/SeerrUserConfig.swift`, `Packages/CinemaxKit/Sources/CinemaxKit/Networking/JellyfinAPIClient+DisplayPreferences.swift`
- Modify: `Packages/CinemaxKit/Sources/CinemaxKit/Networking/APIClientProtocol.swift` (nouvelle tranche + typealias L734), `Tests/CinemaxKitTests/MockAPIClient.swift` (dictionnaire en mémoire + `MockKeychain` conforme)
- Test: `Tests/CinemaxKitTests/SeerrModelTests.swift` (ajout)

**Interfaces:**
- Produces:
  - `public protocol SeerrSecretStorage: Sendable { func seerrSessions() -> [String: String]; func saveSeerrSessions(_ s: [String: String]); func seerrAPIKeys() -> [String: String]; func saveSeerrAPIKeys(_ k: [String: String]) }` ; `extension KeychainService: SeerrSecretStorage` (comptes `seerr_sessions`, `seerr_api_keys`)
  - `public protocol UserPreferencesAPI: Sendable { func getDisplayPreferences(id: String, client: String, userId: String?) async throws -> DisplayPreferencesDto; func updateDisplayPreferences(_ prefs: DisplayPreferencesDto, id: String, client: String, userId: String?) async throws }` avec implémentations par défaut qui lèvent `JellyfinError.notConnected` ; conformance déclarée dans `JellyfinAPIClient+DisplayPreferences.swift` (RULE CinemaxKit L14) ; `APIClientProtocol` gagne `& UserPreferencesAPI`. Implémentation : `Paths.getDisplayPreferences(displayPreferencesID:userID:client:)` / `Paths.updateDisplayPreferences(...)`, `notifyIfUnauthorized` sur erreur.
  - `public struct SeerrUserConfig: Equatable, Sendable { public var isEnabled: Bool; public var url: URL? ; static let preferencesId = "jellyglass-seerr"; static let client = "jellyglass"; static func read(_ dto: DisplayPreferencesDto?) -> SeerrUserConfig; static func merged(_ c: SeerrUserConfig, into dto: DisplayPreferencesDto?) -> DisplayPreferencesDto }` — `merged` garde TOUTES les autres clés de `customPrefs` (dont les six clés héritées injectées par Jellyfin), pose `id`/`client`, écrit `seerr.enabled` = `"true"` ou retire la clé, écrit/retire `seerr.url`.

- [ ] **Step 1: Tests** (`@Suite("Seerr configuration")`) :
  - `mergeRoundTripsLegacyKeys` : dto `customPrefs` = `["skipForwardLength":"30000","chromecastVersion":"stable"]` + config activée ⇒ les deux clés intactes, `seerr.enabled == "true"`, `seerr.url == "http://h:5055"`
  - `disableKeepsAddress` : `merged(SeerrUserConfig(isEnabled: false, url: u), …)` ⇒ pas de `seerr.enabled`, `seerr.url` conservée
  - `readIgnoresGarbage` : `seerr.enabled = "yes"` ⇒ `isEnabled == false` ; `seerr.url = "not a url"` ⇒ `url == nil`
  - `secretsRoundTripInMock` : `MockKeychain` enregistre puis relit `["srv|usr": "cookie"]`
- [ ] **Step 2: Lancer** → échec de compilation.
- [ ] **Step 3: Implémenter** (et le mock : `var displayPreferences: [String: DisplayPreferencesDto]` indexé par `"\(userId ?? "me")|\(id)|\(client)"`, appels enregistrés).
- [ ] **Step 4: Relancer** → verte.
- [ ] **Step 5: Commit** — `feat(seerr): configuration par utilisateur et secrets de l'appareil`.

### Task 6: Politiques d'accès et masquage des journaux

**Files:**
- Create: `Shared/Seerr/SeerrAccess.swift` (nouveau dossier ; `xcodegen generate`)
- Modify: `Shared/Diagnostics/LogScrubber.swift:72` (`tokenMarkers`)
- Test: `Tests/CinemaxKitTests/SeerrPolicyTests.swift` (nouveau)

**Interfaces:**
- Produces:
  - `enum SeerrAccess` : `static func isAgeCapped(deviceMaxAge: Int, policy: UserPolicy?) -> Bool` (`deviceMaxAge > 0 || policy?.maxParentalRating != nil`) ; `static func showsBrowse(proAllows: Bool, ageCapped: Bool, config: SeerrUserConfig?, isOnline: Bool) -> Bool` (tout vrai, `config.isEnabled`, `config.url != nil`) ; `static func showsSettingsCategory(ageCapped: Bool, isAdmin: Bool, config: SeerrUserConfig?) -> Bool` (`!ageCapped && (isAdmin || config?.isEnabled == true)`) ; `static func refusalFailure(policy: UserPolicy?) -> SeerrTestFailure` → `.jellyfinDevice` si `enableAllDevices == false`, sinon `.jellyfinSessions` si `(maxActiveSessions ?? 0) > 0`, sinon `.jellyfinRefused`
  - `enum SeerrTestFailure: Equatable, Sendable { case unreachable, notSeerr, redirected, tooOld(String), notJellyfin, otherJellyfin, quickConnectOff, jellyfinDevice, jellyfinSessions, jellyfinRefused, keyRefused, notInSeerr }` avec `var titleKey: String` / `var fixKey: String` (`seerr.test.<cas>.title` / `.fix`) — les messages de la spec (plus `redirected` : « Cette adresse renvoie ailleurs. » Saisis l'adresse complète de Seerr, avec https:// s'il est derrière un proxy), réutilisés partout où une connexion échoue pour cette raison (test, « Se connecter à Seerr » des Réglages et de la recherche)
- `tokenMarkers` gagne `"X-Api-Key:"`, `"connect.sid="`, `"secret="` (et leurs formes `%3D` : `"connect.sid%3D"`, `"secret%3D"`). Un cookie vaut `s%3A<sid>.<signature>` et `%` termine aujourd'hui une valeur (`valueTerminators`, L89) : `private static let percentTolerantMarkers: Set<String> = ["connect.sid=", "connect.sid%3D"]` — pour ces marqueurs `%` ne termine pas la valeur (avaler trop est le sens sûr, commentaire L84).

- [ ] **Step 1: Tests** (`@Suite("Seerr access")`) :
  - `deviceCapHides` : `isAgeCapped(deviceMaxAge: 12, policy: nil)` ; `serverCapHides` : policy `maxParentalRating = 10` ; `uncapped` : 0 + nil ⇒ faux
  - `browseNeedsEverything` : table de vérité (pro faux, bridé, désactivé, sans URL, hors ligne ⇒ faux ; tout bon ⇒ vrai)
  - `settingsForAdminEvenDisabled` ; `settingsHiddenWhenCapped` même admin
  - `refusalPicksDeviceFirst` : `enableAllDevices = false, maxActiveSessions = 1` ⇒ `.jellyfinDevice` ; `true, 1` ⇒ `.jellyfinSessions` ; `true, 0` ⇒ `.jellyfinRefused`
  - `scrubsSeerrSecrets` (dans le suite LogScrubber existant `DiagnosticsTests.swift`) : `"X-Api-Key: abc"`, `"Cookie: connect.sid=s%3AsessXYZ.sigABC"`, `"check?secret=deadbeef"` ⇒ ni `abc`, ni `sessXYZ`, ni `sigABC`, ni `deadbeef` dans la sortie
- [ ] **Step 2: Lancer** → échec.
- [ ] **Step 3: Implémenter.**
- [ ] **Step 4: Relancer** → verte.
- [ ] **Step 5: Commit** — `feat(seerr): politiques d'accès, limite d'âge, masquage des secrets`.

### Task 7: `SeerrSession` — l'identité Seerr du compte actif

**Files:**
- Create: `Shared/Seerr/SeerrSession.swift`
- Modify: `Shared/Navigation/AppState.swift` (nouveau crochet `var onCurrentUserRefreshed: @MainActor () -> Void = {}` appelé à la FIN de `refreshCurrentUser` L215 — couvre connexion, bascule L569, restauration L205, premier plan L726 ; `onAccountForgotten` L88 efface aussi le cookie Seerr du compte ; `removeServer` L799 efface `seerr_api_keys[entry.id]`), `Shared/Navigation/AppNavigation.swift` (singleton `static let sharedSeerrSession`, `@State`, `.environment` ; `onCurrentUserRefreshed = { Task { await seerr.reload(appState:) } }` ; `onChange(of: appState.activeAccountKey)` L589 ⇒ `seerr.reset()` SYNCHRONE)
- Test: `Tests/CinemaxKitTests/SeerrSessionTests.swift` (nouveau)

**Interfaces:**
- Consumes: Tasks 3–6 ; `AppState.activeAccountKey`, `activeServerId`, `currentUser?.policy`, `isAdministrator`, `serverInfo?.id`, `apiClient` (`UserPreferencesAPI`, `AuthAPI`) ; `SettingsKey.privacyMaxContentAge`.
- Produces:
  - `@MainActor @Observable final class SeerrSession` ; `init(storage: any SeerrSecretStorage = KeychainService(), defaults: UserDefaults = .standard, transport: (any SeerrTransport)? = nil)`
  - `enum Connection: Equatable { case unavailable; case notConnected; case connected(SeerrUser); case notLinked }`
  - `struct Snapshot: Equatable, Sendable { let accountKey: String; let generation: Int }`
  - `private(set) var config: SeerrUserConfig?`, `connection: Connection`, `publicSettings: SeerrPublicSettings?`, `usesDeviceKey: Bool`, `isAgeCapped: Bool`
  - `func reset()` — synchrone : `generation += 1`, `config = nil`, `connection = .unavailable`, `isAgeCapped = true`, client et approbateur oubliés ; appelé au changement de compte AVANT toute autre chose, et en tête de `reload`
  - `func reload(appState: AppState) async` — `reset()` d'abord (avant le premier `await`) ; `appState.currentUser == nil` ⇒ reste bridé (on ne sait pas encore : fermé par défaut) ; garde un approbateur `@Sendable (String) async throws -> Bool` bâti sur `appState.apiClient.authorizeQuickConnect` pour la reprise silencieuse ; puis lit la config (`getDisplayPreferences(id: SeerrUserConfig.preferencesId, client: SeerrUserConfig.client, userId: nil)`), calcule `isAgeCapped`, et si non bridé + activé + URL : `publicSettings`, puis identité (clé de l'appareil ⇒ `user(forJellyfinUserId:auth: .adminKey)` ⇒ `.connected`/`.notLinked` ; sinon cookie ⇒ `me` ⇒ `.connected`, cookie absent ⇒ `.notConnected`). Toute écriture après un `await` est jetée si la génération a changé.
  - `func snapshot() -> Snapshot?`, `func isCurrent(_ s: Snapshot) -> Bool`
  - `func credential() -> SeerrCredential?` ; `var client: SeerrClient?`
  - `func perform<T: Sendable>(_ op: @Sendable (SeerrClient, SeerrCredential) async throws -> T) async throws -> T` — sur `.forbidden` : sonde (`me` en mode compte / `user(forJellyfinUserId:auth: .adminKey)` en mode clé) ; sonde 403 en mode compte ⇒ UNE reconnexion silencieuse (`SeerrQuickConnectSignIn` sur `config.url` seulement, avec l'approbateur gardé par `reload`) puis une nouvelle tentative ; échec ⇒ `connection = .notConnected`, cookie effacé, l'erreur remonte ; mode clé : sonde 403 ⇒ `SeerrError.forbidden` remonte et l'état passe « clé refusée », 404 ⇒ `.notLinked`, jamais de nouvelle tentative ; sonde 200 ⇒ l'erreur `.forbidden` remonte telle quelle.
  - `func signIn(address: URL, appState: AppState) async -> Result<SeerrUser, SeerrSignInError>` (enregistre le cookie sous `activeAccountKey` ; le test de connexion passe l'adresse SAISIE, les Réglages et la recherche passent `config.url`)
  - `func signOut() async` (`logout` + effacement du cookie)
  - `func setDeviceKey(_ key: String?, appState: AppState) async` (écrit/retire `seerr_api_keys[activeServerId]`, puis `reload`)
  - `func isVisible(proAllows: Bool, isOnline: Bool) -> Bool` = `SeerrAccess.showsBrowse(…)` ET `connection` `.connected` — lu au RENDU par chaque surface
  - `func showsConnectPrompt(proAllows: Bool, isOnline: Bool) -> Bool` = `SeerrAccess.showsBrowse(…)` ET `connection == .notConnected` (jamais en mode clé)

- [ ] **Step 1: Tests** (`@Suite("Seerr session")`, `MockAPIClient` + `StubSeerrTransport` + `MockKeychain` + `UserDefaults.isolatedForTesting()`, `@MainActor`) :
  - `cappedAccountMakesNoSeerrCall` : `maxParentalRating = 10` ⇒ `isAgeCapped`, zéro requête sur le transport
  - `disabledMakesNoSeerrCall` : config désactivée ⇒ zéro requête
  - `cookieRestoresConnection` : cookie stocké + `/auth/me` 200 ⇒ `.connected`
  - `deviceKeyResolvesUser` : clé stockée + `/user/jellyfin/{id}` 200 ⇒ `.connected`, `credential() == .apiKey(key:user:)` ; 404 ⇒ `.notLinked`
  - `deadSessionReSignsInOnce` : appel 403, `/auth/me` 403, Quick Connect stubé OK, nouvel appel 200 ⇒ succès, `authorizeQuickConnectCalls.count == 1` ; si la reprise échoue ⇒ `.notConnected` et l'erreur remonte, pas de deuxième reprise
  - `genuineForbiddenDoesNotReSignIn` : appel 403, `/auth/me` 200 ⇒ `.forbidden`, aucun appel `authorizeQuickConnect`
  - `policyUnknownIsCapped` : `currentUser == nil` ⇒ `isAgeCapped`, zéro requête
  - `reloadResetsBeforeFirstAwait` : `.connected` puis `reload` retenu par un `TestLatch` sur la lecture des préférences ⇒ pendant l'attente, `connection == .unavailable` et `isVisible(…) == false`
  - `staleAnswerIsDropped` : `reload` A bloqué sur un `TestLatch`, `reload` B (autre compte) termine, puis A se débloque ⇒ `config`/`connection` restent ceux de B
  - `promptOnlyWhenNotConnected` : `.notConnected` ⇒ `showsConnectPrompt` vrai ; `.connected`, mode clé, bridé ⇒ faux
- [ ] **Step 2: `xcodegen generate`, lancer** → échec.
- [ ] **Step 3: Implémenter** `SeerrSession` et le câblage racine (même place que `ProFeatureAccess`).
- [ ] **Step 4: Relancer iOS** → verte.
- [ ] **Step 5: Commit** — `feat(seerr): session Seerr du compte actif, reprise silencieuse`.

### Task 8: « Tester la connexion »

**Files:**
- Create: `Shared/Seerr/SeerrConnectionTest.swift`
- Test: `Tests/CinemaxKitTests/SeerrSessionTests.swift` (ajout)

**Interfaces:**
- Consumes: Tasks 3, 4, 6 (`SeerrTestFailure`), 7 ; `AuthAPI.isQuickConnectEnabled()`, `appState.serverInfo` (`id`, `name`), `currentUser?.policy`.
- Produces:
  - `struct SeerrTestReport: Equatable { var verified: [String]; var warning: String?; var failure: SeerrTestFailure? }` (lignes déjà localisées)
  - `@MainActor enum SeerrConnectionTest { static func run(address: URL, deviceKey: String?, session: SeerrSession, appState: AppState, loc: LocalizationManager) async -> SeerrTestReport }`
  - Ordre (arrêt au premier échec, spec § Test connection + Spike 3–4) : `status` (`.redirected` ⇒ `.redirected`) → version ≥ 3.4 → `publicSettings.isJellyfin` → mode clé : `user(forJellyfinUserId: moi, .adminKey)` (403 ⇒ `keyRefused`, 404 ⇒ `notInSeerr`) puis `jellyfinServerId` ≠ `serverInfo.id` ⇒ `otherJellyfin` ; mode compte : `isQuickConnectEnabled` faux ⇒ `quickConnectOff`, puis `session.signIn(address: address, appState:)` (`.otherJellyfin`, `.jellyfinRefused` ⇒ `SeerrAccess.refusalFailure(policy:)`, `.notImported` ⇒ `notInSeerr`). Succès : « Seerr <v> », « Relié à ton serveur Jellyfin « <nom> » », (compte) « Connexion en un geste disponible », « Ton compte Seerr : … » ; avertissement « Ton compte Seerr ne peut pas valider les demandes… » si `!permissions.canManageRequests`.

- [ ] **Step 1: Tests** (`@Suite("Seerr connection test")`) — un test par ligne du tableau de la spec, chacun sur sa réponse stubée : `reportsUnreachable`, `reportsNotSeerr`, `reportsTooOld` (`{"version":"3.3.2"}` ⇒ `.tooOld("3.3.2")`), `reportsNotJellyfin` (`mediaServerType: 1`), `reportsQuickConnectOff`, `reportsOtherJellyfinFromApproval404`, `reportsOtherJellyfinFromServerId`, `reportsDeviceRestriction`, `reportsKeyRefused`, `reportsNotInSeerr`, `successListsVerifiedAndWarnsWithoutManage` (permissions 32 ⇒ 4 lignes + l'avertissement).
- [ ] **Step 2: Lancer** → échec.
- [ ] **Step 3: Implémenter.**
- [ ] **Step 4: Relancer** → verte.
- [ ] **Step 5: Commit** — `feat(seerr): test de connexion et messages explicites`.

### Task 9: Activation par l'admin

**Files:**
- Create: `Shared/Seerr/SeerrActivation.swift`
- Test: `Tests/CinemaxKitTests/SeerrSessionTests.swift` (ajout)

**Interfaces:**
- Consumes: Task 5 (`UserPreferencesAPI`, `SeerrUserConfig.merged`), Task 7 (`SeerrSession.perform`, `credential`), `AuthAPI.getUsers()`.
- Produces:
  - `enum SeerrUserLineKind: Equatable { case ageCapped; case linked(autoApproves: Bool); case willBeCreated; case mustBeAdded; case unknown }` ; `static func kind(policy: UserPolicy?, seerrUser: SeerrUser?, lookupFailed: Bool, newPlexLogin: Bool) -> SeerrUserLineKind`
  - `struct SeerrUserLine: Identifiable, Equatable { let id: String; let name: String; var isEnabled: Bool; var kind: SeerrUserLineKind }`
  - `@MainActor @Observable final class SeerrActivationModel { private(set) var lines: [SeerrUserLine]; var enabledCount: Int; func load(appState:session:) async; func setEnabled(_ on: Bool, userId: String, appState:, loc: LocalizationManager) async -> String?; func enableAll(appState:, loc: LocalizationManager) async -> String; func disableAll(appState:) async; func setAddress(_ url: URL, appState:) async }` — chaque écriture = lecture (`userId:`) puis `merged` puis écriture ; un utilisateur bridé n'est jamais écrit à `true` ; `setAddress` réécrit tous les activés + l'admin.
  - `static func activationSummary(enabled: Int, refusedNames: [String], loc: LocalizationManager) -> String` → « Activé pour 3 utilisateurs. Tom n'a pas pu être activé : limite d'âge sur son compte. » (noms joints, pluriels par `loc.counted`)

- [ ] **Step 1: Tests** (`@Suite("Seerr activation")`) :
  - `cappedUserIsRefusedWithReason` : `setEnabled(true, userId: tom)` ⇒ message « Tom n'a pas pu être activé : son compte a une limite d'âge. Retire-la dans Jellyfin pour lui ouvrir les demandes. », aucune écriture pour Tom
  - `enableAllSkipsCappedAndSummarises` : 4 utilisateurs dont 1 bridé ⇒ 3 écritures, résumé exact (FR)
  - `writePreservesOtherPrefs` : dto existant avec `skipForwardLength` ⇒ conservé dans la requête d'écriture
  - `disableAllKeepsAdminAddress`
  - `lineKinds` : table de vérité de `kind(...)`
- [ ] **Step 2: Lancer** → échec.
- [ ] **Step 3: Implémenter.**
- [ ] **Step 4: Relancer** → verte.
- [ ] **Step 5: Commit** — `feat(seerr): activation par utilisateur, refus motivé pour une limite d'âge`.

### Task 10: Fonction Pro et catégorie Réglages → Demandes (iOS + tvOS)

**Files:**
- Modify: `Shared/Entitlements/ProFeatureCatalogue.swift:102` (cas `.requests`), `Shared/Entitlements/ProFeatureGate.swift:132` (bras du `switch`), l'entrée `Feature(id: .requests, titleKey: "pro.feature.requests.title", detailKey: "pro.feature.requests.detail", icon: "tray.and.arrow.down", isGated: true)` (+ `rowKey`)
- Modify: `Shared/Screens/Settings/SettingsScreen.swift` (`SettingsCategory` : cas `.requests` après `.account` ; `icon`, `localizedName`, `proFeature` ⇒ `.requests` ; `visibleCases(isAdmin:isTVOS:showsDebug:showsRequests:)` ; commentaire L101 révisé), `SettingsScreen+iOS.swift` (switch interne L274 + appel `visibleCases`), `SettingsScreen+tvOS.swift` (switch L466 ; `tvLandingCategories` passe `showsRequests` ; `tvCategoryButton` appelle `proAccess?.admit` comme iOS — `proAccess` est déjà dans l'environnement de `SettingsScreen`, L241)
- Create: `Shared/Screens/Settings/RequestsSettingsScreen.swift` (struct autonome, deux plateformes : RULE racine L40)
- Modify: `Resources/{fr,en,de}.lproj/Localizable.strings` (bloc `// MARK: - Seerr`), `Tests/CinemaxKitTests/MenuConfigStoreTests.swift:692-704,766`, `Tests/CinemaxKitTests/ProPurchaseTests.swift:425`

**Interfaces:**
- Consumes: Tasks 7–9 ; `ProFeatureAccess.allows/admit` ; `GlassTextField` (adresse, clé `isSecure: true`) ; `iOSSettingsRow`, `iOSSettingsSectionHeader`, `tvActionRow`, `SettingsToggleRow`.
- Produces: `struct RequestsSettingsScreen: View` — sections dans l'ordre : **Connexion** (« Connecté à Seerr en tant que X » + « Se déconnecter » / « Se connecter à Seerr » ; en mode clé « Clé de l'appareil · profil X ») ; **Configuration** (admin) : adresse, « Tester la connexion » + rapport (succès en liste, échec titre + correction, avertissement) et, sous le bouton en mode compte, « Le test te connecte à Seerr : Seerr peut créer ton compte, et Jellyfin affichera un appareil « Seerr ». », « Qui peut demander · N sur M », un interrupteur par utilisateur + sa ligne d'état, « Activer pour tous » / « Tout désactiver », note de bas ; **Sur cet appareil** (admin) : « Clé d'API (facultatif) » + explication de la spec. Messages d'activation en toast (`toasts.success` / `toasts.info`), confirmation « Tout désactiver » en `.alert` destructive (forme de la déconnexion, `+iOS.swift:368` / `+tvOS.swift:121`). Garde `@State …Attempted` sur le `.task` tvOS (RULE Réglages L23).
- Clés de chaînes (fr de référence, en / de traduits) : toutes celles de la spec § Settings, § Age-capped, § Test connection (titre + correction), `pro.feature.requests.*`, `settings.requests` = « Demandes ».

- [ ] **Step 1: Mettre à jour les tests existants** : `nonAdminOrder` / `adminGating` avec `showsRequests` (vrai ⇒ `.requests` après `.account` sur les deux plateformes ; faux ⇒ listes actuelles) ; `debugLastOrAbsent` (~L706) reçoit l'argument ; `administrationIsTheProCategory` devient `onlyAdministrationAndRequestsArePro` ; `gatedSet` gagne `.requests`.
- [ ] **Step 2: Lancer** → échec.
- [ ] **Step 3: Implémenter** le cas Pro, la catégorie, l'écran et les chaînes ; `xcodegen generate`.
- [ ] **Step 4: Relancer iOS puis tvOS** → vertes, `localize-check` sans écart, `scripts/check-localization-parity.py` OK.
- [ ] **Step 5: Vérifier au simulateur de test** (5AB90411 / 699CCA2B, jamais un simulateur personnel ou de démo) contre le banc de l'essai (`docker start jf-bench seerr-spike`, Seerr `http://127.0.0.1:5055`, comptes de `~/seerr-spike/users.txt`) : test OK, test en erreur (port 8096 ⇒ « ne mène pas à Seerr »), activation de Tom refusée avec son message, connexion de Léa en un geste, redirection http→https d'un proxy suivie. Captures dans `_artifacts/seerr-lot1a/`.
- [ ] **Step 6: Commit** — `feat(seerr): Réglages → Demandes, configuration et connexion (iOS + tvOS)`.

### Task 11: Règles, documentation, PR 1

**Files:**
- Create: `Shared/Seerr/CLAUDE.md` (fichier de zone : RULEs « tout après le possédé », « 403 ⇒ sonde », « CSRF géré par le client », « X-API-User par le type », « jamais journalisé », « bridé ⇒ aucun appel », « réponse périmée jetée », « Seerr absent des surfaces de navigation »)
- Modify: `CLAUDE.md` racine (une ligne au tableau *Where the rules live* : `Shared/Seerr/`, `RequestsSettingsScreen`), `Shared/Screens/Settings/CLAUDE.md` (exception tvOS admin de la catégorie Demandes ; lignes `@AppStorage` des clés ajoutées), `Packages/CinemaxKit/CLAUDE.md` (tranche `UserPreferencesAPI`, client Seerr hors SDK, items `seerr_*`), `Shared/Entitlements/CLAUDE.md` (`.requests`)

- [ ] **Step 1:** Écrire les règles (invariants seulement, les mesures restent dans la spec).
- [ ] **Step 2:** Suites iOS + tvOS complètes vertes, SwiftLint strict propre.
- [ ] **Step 3:** Commit `docs(seerr): règles de zone`, pousser la branche, ouvrir la PR « Seerr : base et Réglages » (corps terminé par `🤖 Generated with [Claude Code](https://claude.com/claude-code)`), ne PAS fusionner.

---

# PR 2 — Lot 1b : section de la recherche

### Task 12: « Manquant » et badges (pur)

**Files:**
- Create: `Shared/Seerr/SeerrMissing.swift`, `Shared/Seerr/SeerrSession+Sections.swift`
- Test: `Tests/CinemaxKitTests/SeerrMissingTests.swift` (nouveau)

**Interfaces:**
- Produces:
  - `enum SeerrBadge: Equatable, Sendable { case request, pending, processing, declined }`
  - `struct SeerrMissingTitle: Identifiable, Equatable, Sendable { let title: SeerrTitle; let badge: SeerrBadge; var id: String { "\(title.kind.rawValue)-\(title.tmdbId)" } }`
  - `struct SeerrMissingSeason: Identifiable, Equatable, Sendable { let seriesTmdbId: Int; let seasonNumber: Int; let badge: SeerrBadge; var id: String { "tv-\(seriesTmdbId)-s\(seasonNumber)" } }`
  - `enum MissingSection<Element: Equatable & Sendable>: Equatable { case hidden, loading, loaded([Element]) }` (`loaded([])` ne rend RIEN)
  - LE chargement commun des quatre surfaces (`SeerrSession+Sections.swift`) : `func loadSection<T: Equatable & Sendable>(deadline: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(6)) }, _ op: @escaping @Sendable (SeerrClient, SeerrCredential) async throws -> [T]) async -> MissingSection<T>?` — prend un `snapshot()`, court `perform(op)` contre `deadline()`, rend `nil` si la réponse est périmée (`!isCurrent(snapshot)` ou tâche annulée : l'appelant n'écrit RIEN), `.hidden` sur erreur ou échéance, `.loaded(…)` sinon ; aucune surface ne réécrit cette course
  - `enum SeerrImages { static func posterURL(path: String?, seerrBase: URL, cacheImages: Bool) -> URL? }` → `/imageproxy/tmdb/t/p/w300<path>` sur Seerr (via `setEndpointPath`, sous-chemin gardé) si `cacheImages`, sinon `https://image.tmdb.org/t/p/w300<path>` ; utilisé par la feuille de demande et Mes demandes seulement
  - `enum SeerrMissing` : `static func ownedTmdbIds(_ items: [BaseItemDto]) -> Set<Int>` (`providerIDs?["Tmdb"]`, insensible à la casse de la clé) ; `static func titles(_ candidates: [SeerrTitle], owned: Set<Int>) -> [SeerrMissingTitle]` (retire possédés et `mediaInfo.status` ∈ {4, 5, 6}, garde 7, dédoublonne par `id`, ordre Seerr conservé) ; `static func badge(_ info: SeerrMediaInfo?) -> SeerrBadge` (aucune / 1 inconnu / 7 ⇒ `.request` ; demande en attente ⇒ `.pending` ; 3 traitement ou demande approuvée ⇒ `.processing` ; dernière demande refusée ⇒ `.declined`) ; `static func seasons(_ tv: SeerrTVDetails, ownedSeasonNumbers: Set<Int>, includeSpecials: Bool) -> [SeerrMissingSeason]` (saison 0 seulement si `includeSpecials` ; saison disponible ou partielle dans `mediaInfo.seasons` ⇒ retirée ; badge par saison depuis `mediaInfo.requests[].seasons`)

- [ ] **Step 1: Tests** (`@Suite("Seerr missing")`) : `slowSeerrSkeletonExpires` (`deadline` = un `TestLatch` ouvert par le test, Seerr jamais servi ⇒ `.hidden` ; aucun test ne dort), `staleSectionIsNil` (bascule de compte pendant `op` ⇒ `nil`), `errorIsHidden`, `jellyfinWinsByTmdbId`, `availableAndBlocklistedDropped` (4, 5, 6), `deletedStaysMissing` (7), `pendingSeasonFromRequestNotMediaSeasons` (`mediaInfo.seasons` vide + demande en attente sur `[1]` ⇒ saison 1 `.pending`, saison 2 `.request`), `specialsOnlyWhenEnabled`, `declinedBadge`, `ownedIdsReadLowercaseKey` (`"tmdb"`), `posterURLKeepsSubPath` (`https://h/seerr`, `cacheImages` ⇒ `https://h/seerr/imageproxy/tmdb/t/p/w300/x.jpg`).
- [ ] **Step 2: `xcodegen generate`, lancer** → échec.
- [ ] **Step 3: Implémenter.**
- [ ] **Step 4: Relancer** → verte.
- [ ] **Step 5: Commit** — `feat(seerr): calcul des titres et saisons manquants`.

### Task 13: La demande — feuille iOS, confirmation tvOS, envoi

**Files:**
- Create: `Shared/Seerr/SeerrRequestPresenter.swift`
- Modify: `Shared/Navigation/AppNavigation.swift` (présentateur racine, comme `AddToPlaylistPresenter` L87/279/284)
- Test: `Tests/CinemaxKitTests/SeerrMissingTests.swift` (ajout)

**Interfaces:**
- Consumes: Tasks 3, 7, 12 ; `ToastCenter`.
- Produces:
  - `enum SeerrRequestDraft: Identifiable, Equatable { case movie(SeerrTitle); case series(SeerrTitle, seasons: [Int], preselected: Set<Int>); case films([SeerrTitle]) }`
  - `@MainActor @Observable final class SeerrRequestPresenter { var draft: SeerrRequestDraft?; func present(_ d: SeerrRequestDraft); func badge(for id: String, default: SeerrBadge) -> SeerrBadge; func submit(_ d: SeerrRequestDraft, selection: Set<Int>, session: SeerrSession, loc: LocalizationManager, toasts: ToastCenter) async }` — `overrides: [String: SeerrBadge]` indexé par `SeerrMissingTitle.id` (`"tv-90228"`) ou, pour une saison, `"tv-90228-s4"`, mis à jour après envoi (les sections les lisent : la carte bascule sans recharger) ; `partialRequestsEnabled == false` ⇒ envoie toutes les saisons manquantes ; `.duplicate` ⇒ badge `.pending` + toast info « Déjà demandé » ; `.forbidden` ⇒ toast erreur « Seerr a refusé la demande » + correction (droits ou quota) ; `.noSeasonsAvailable` ⇒ toast erreur « Aucune saison à demander » ; succès ⇒ « Demande envoyée : <titre> » (plusieurs ⇒ `loc.counted`).
  - `static func nextStepKey(permissions: SeerrPermissions, kind: SeerrMediaKind) -> String` ⇒ « le téléchargement démarre tout de suite » si auto-approuvé (admin, `autoApprove`, `autoApproveMovie` / `autoApproveTV`), sinon « l'admin doit valider ta demande, tu seras prévenu à son arrivée »
  - `struct SeerrRequestPresentation: ViewModifier` — iOS `.sheet(item:)` : affiche (`SeerrImages.posterURL`), titre, type, année, résumé deux lignes, liste à cocher pour saisons / films (tout coché par défaut), bouton « Demander ce film » / « Demander la série » / « Demander N saisons » / « Demander les N », ligne `nextStepKey` ; tvOS `.confirmationDialog` : « Demander ce film », « Demander la saison 4 », « Demander les saisons 4 à 6 », « Demander les 3 films », « Annuler » — aucune case, aucune saisie. Réinjecte `appState`, `loc`, `themeManager`, `toasts` (contexte de présentation séparé).

- [ ] **Step 1: Tests** (`@Suite("Seerr request flow")`) : `nonPartialSendsAllMissingSeasons`, `duplicateFlipsToPending`, `forbiddenShowsRefusal`, `noSeasonsIsAFailure` (202), `autoApproveLine` (permissions 2 / 128 / 256 film / 32).
- [ ] **Step 2: Lancer** → échec.
- [ ] **Step 3: Implémenter.**
- [ ] **Step 4: Relancer** → verte.
- [ ] **Step 5: Commit** — `feat(seerr): demande en un geste, iOS et tvOS`.

### Task 14: Carte en pointillé, squelettes, rangée « Pas encore dans ta bibliothèque »

**Files:**
- Create: `Shared/Seerr/Views/MissingTitleCard.swift`, `Shared/Seerr/Views/MissingTitlesRow.swift`
- Modify: `Shared/DesignSystem/CLAUDE.md` (exception documentée à « No 1px borders » : la carte manquante est LE seul contour, en pointillé, décidé par le produit le 2026-11-06)

**Interfaces:**
- Consumes: Task 12 (`MissingSection`, `SeerrMissingTitle`, `SeerrMissingSeason`, `SeerrBadge`), Task 13 (`SeerrRequestPresenter.badge`) ; `SkeletonBlock`, `ContentRow(data:id:header:itemView:)`, `CinemaTVCardButtonStyle`, `CinemaColor.onSurfaceMuted`, `CinemaTVLayout.posterCardWidth`.
- Produces:
  - `struct MissingTitleCard: View { let title: String; let subtitle: String?; let badge: SeerrBadge; let aspectRatio: CGFloat }` — boîte `Color.clear` + `.aspectRatio`, contour `RoundedRectangle(cornerRadius: CinemaRadius.large).strokeBorder(CinemaColor.onSurfaceMuted, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))`, titre centré dans la boîte, badge en bas (`.request` = « Demander » à l'accent, `.pending` « En attente », `.processing` « En préparation », `.declined` « Refusée »), `.contentShape(Rectangle())` ; tvOS : enveloppé par l'appelant dans un `Button` `CinemaTVCardButtonStyle` (même focus que les autres cartes).
  - `struct MissingHeaderAction { let label: String; let perform: () -> Void }`
  - `struct MissingTitlesRow<Element: Identifiable & Equatable & Sendable, Card: View>: View` — `init(title: String, count: String?, section: MissingSection<Element>, headerAction: MissingHeaderAction?, @ViewBuilder card: @escaping (Element) -> Card)` : `.hidden` / `.loaded([])` ⇒ `EmptyView` ; `.loading` ⇒ 4 `SkeletonBlock` (non focalisables sur tvOS : `.focusable(false)`, `accessibilityHidden`) ; `.loaded` ⇒ `ContentRow` avec en-tête titre + compteur + action à droite ; `.scrollClipDisabled()` sur tvOS.
  - Libellé du badge pour VoiceOver : « <titre>, pas encore dans ta bibliothèque, Demander ».

- [ ] **Step 1:** Implémenter les deux vues ; aperçus `#Preview` pour les quatre badges et le squelette.
- [ ] **Step 2: Lancer iOS + tvOS** → compilation et suites vertes ; `design-system-review` sur les fichiers.
- [ ] **Step 3: Commit** — `feat(seerr): carte en pointillé et rangée des manquants`.

### Task 15: Recherche — section après les résultats, invitation à se connecter

**Files:**
- Modify: `Packages/CinemaxKit/Sources/CinemaxKit/Networking/APIClientProtocol.swift:218` + `JellyfinAPIClient+Library.swift:382` (`searchItems(..., includeProviderIds: Bool)` ⇒ `params.fields = [.providerIDs]` si vrai), `Shared/ViewModels/LibrarySearchRanker.swift:133` (`rank(..., includeProviderIds: Bool = false)` passé tel quel — AUCUNE logique Seerr dans le classeur), `Shared/Intents/` appelant (`false`), `Tests/CinemaxKitTests/MockAPIClient.swift`
- Modify: `Shared/ViewModels/SearchViewModel.swift` (état `seerrSection: MissingSection<SeerrMissingTitle>`, remis à `.hidden` au point de remise à zéro L394), `Shared/Screens/SearchScreen.swift` (dans `SearchResultsGrid`, entre la grille L791 et `Spacer` L793 ; nouvelles propriétés ajoutées au `==` L716 ; branche « aucun résultat » L362 : l'état vide reste, la section Seerr s'affiche dessous)
- Modify: `Shared/DesignSystem/SettingsKeys.swift` (`seerr.searchPromptDismissed.<accountKey>` via préfixe `SettingsKey.seerrSearchPromptDismissedPrefix`) + ligne du tableau `@AppStorage`
- Test: `Tests/CinemaxKitTests/SearchViewModelTests.swift` (ajout)

**Interfaces:**
- Consumes: Tasks 7, 12–14.
- Produces: `SearchViewModel.seerrSection` (la carte d'invitation, elle, est décidée par la vue : `seerr.showsConnectPrompt(…)` et pas encore écartée), `var allowsSeerr: @MainActor () -> Bool = { false }` (posé par l'écran : `{ seerr.isVisible(proAllows: proAccess?.allows(.requests) ?? true, isOnline: network.isOnline) }`, lu avant l'appel ET re-vérifié par la vue au rendu), et le délai injectable de `loadSection` pour les tests.
- Déroulé dans le `searchTask` existant (même anti-rebond 400 ms) : résultats Jellyfin écrits d'abord ; puis si `allowsSeerr()` : `seerrSection = .loading`, puis `if let s = await seerr.loadSection({ … search … }) { seerrSection = s }` avec `SeerrMissing.titles(_, owned: ownedTmdbIds(results))` appliqué au résultat ; la section suit les puces de `scope` (`.all` ⇒ films + séries, `.movies` ⇒ films, `.series` ⇒ séries). Carte d'invitation (à la place de la section) : « Il te manque un titre ? » + « Se connecter à Seerr » (⇒ `session.signIn`, échec ⇒ toast titre + correction de `SeerrTestFailure`) + « Plus tard » (écrit la clé d'écart du compte).

- [ ] **Step 1: Tests** (`@Suite("Search — Seerr section")`) : `seerrSectionAfterLibraryResults` (les résultats Jellyfin sont écrits avant que la réponse Seerr, retenue par un `TestLatch`, arrive), `ownedTitleNotListedTwice`, `scopeFiltersSeerrKinds` (`.series` ⇒ aucun film manquant), `unreachableSeerrShowsNothing`, `profileSwitchDropsSeerrSection` (`reload` d'un autre compte pendant l'attente ⇒ section jamais écrite), `notAllowedMakesNoSeerrCall` (`allowsSeerr` faux ⇒ transport intact).
- [ ] **Step 2: Lancer** → échec.
- [ ] **Step 3: Implémenter** VM + vue (iOS et tvOS : section dans le même `LazyVStack`, cartes `MissingTitleCard` en ratio 2:3 ; toucher ⇒ `presenter.present(.movie)` / `.series(seasons: toutes les saisons manquantes)` après un `tv(tmdbId:)` pour une série).
- [ ] **Step 4: Relancer iOS + tvOS** → vertes.
- [ ] **Step 5: Vérifier au simulateur de test** contre le banc : « dune » ⇒ section après les résultats ; Seerr arrêté (`docker stop seerr-spike`) ⇒ rien, aucun message ; Tom (bridé) ⇒ rien. Captures `_artifacts/seerr-lot1b/`.
- [ ] **Step 6: Commit, mettre à jour `docs/rules/search.md` et `Shared/Seerr/CLAUDE.md`, ouvrir la PR « Seerr : recherche »** (ne pas fusionner).

---

# PR 3 — Lot 2 : fiches

### Task 16: Fiche série — saisons manquantes

**Files:**
- Modify: `Shared/ViewModels/MediaDetailViewModel.swift` (`seerrSeasons: MissingSection<SeerrMissingSeason>` ; chargé en tâche annexe après `loadSeriesDetail` L629 par `seerr.loadSection`, garde `loadGeneration` en plus), `Shared/Screens/MediaDetailScreen.swift` (`seasonsSection` L1700 : iOS — rangée `MissingTitlesRow` après le défilement des épisodes L1834, le `Menu` inchangé ; tvOS — pastilles en pointillé ajoutées APRÈS le `ForEach` des pastilles possédées, dans le même `HStack` du `ScrollView` L1710, quand `showSeasonPicker` (squelettes de pastilles non focalisables pendant `.loading`), sinon la rangée après les épisodes L1774)
- Test: `Tests/CinemaxKitTests/MediaDetailViewModelTests.swift` (ajout)

**Interfaces:**
- Consumes: Tasks 7, 12–14 ; `item.providerIDs?["Tmdb"]` (fiche complète), `seasons[].indexNumber`.
- Produces: `MediaDetailViewModel.seerrSeasons`, `var allowsSeerr: @MainActor () -> Bool` (même câblage que la recherche). Carte « Saison 4 » ⇒ `.series(…, seasons: manquantes, preselected: [4])` ; en-tête « Demander les N » ⇒ `preselected: toutes`. Pastille tvOS : `SeasonTabButtonStyle` gardé, contour pointillé, sélection ⇒ la confirmation tvOS de Task 13.

- [ ] **Step 1: Tests** (`@Suite("Detail — missing seasons")`) : `missingSeasonsAfterOwned` (possédées 1–3, TMDb 1–6 ⇒ 4, 5, 6), `noTmdbIdNoCall`, `staleSeasonsDropped` (navigation vers une autre fiche pendant l'attente), `oneSeasonSeriesStillGetsRow`.
- [ ] **Step 2: Lancer** → échec.
- [ ] **Step 3: Implémenter.**
- [ ] **Step 4: Relancer iOS + tvOS** → vertes ; vérifier au simulateur (série du banc avec une saison possédée, iOS et tvOS : rien au-dessus des épisodes ne bouge).
- [ ] **Step 5: Commit** — `feat(seerr): saisons manquantes sur la fiche série`.

### Task 17: Saga — fiche BoxSet et fiche film

**Files:**
- Modify: `APIClientProtocol.swift:162` (`ItemFieldSet.cardWithProviderIds` ⇒ `[.childCount, .providerIDs]`) + `JellyfinAPIClient+Library.swift:224`, `MediaDetailViewModel.swift` (`loadCollectionChildren` L519 et `loadCollection` L535 demandent `.cardWithProviderIds` quand `allowsSeerr()` ; les deux gagnent la garde `loadGeneration` qui leur manque ; `seerrSaga: MissingSection<SeerrMissingTitle>` chargé par `seerr.loadSection`, `sagaName: String?`), `Shared/Screens/MediaDetailSimilarSection.swift` (paramètre `trailing: MissingSection<SeerrMissingTitle> = .hidden`, inclus dans `==` ; la rangée itère `enum SimilarRowItem: Identifiable { case owned(BaseItemDto); case missing(SeerrMissingTitle); case skeleton(Int) }` — possédés d'abord, puis manquants ou squelettes), `MediaDetailScreen.swift` (`secondaryColumnSections` L536 : BoxSet — section « Pour compléter la saga » après « Dans cette collection » L568 ; film avec rangée « Fait partie de » L552 — manquants passés en `trailing` de cette rangée ; film sans rangée mais `TmdbCollection` — rangée « Pour compléter la saga <nom> » APRÈS « Similaires » L578)
- Test: `Tests/CinemaxKitTests/MediaDetailViewModelTests.swift` (ajout)

**Interfaces:**
- Consumes: Tasks 12–14 ; `providerIDs["TmdbCollection"]` (BoxSet ou film), `collectionItems`, `collectionChildren`.
- Produces: `seerrSaga` ; possédés = `ownedTmdbIds(collectionChildren ou collectionItems + item)`. En-tête « 3 films manquants » (`loc.counted`) + « Demander les 3 » ⇒ `.films(manquants)` ; carte ⇒ `.movie`.

- [ ] **Step 1: Tests** (`@Suite("Detail — saga")`) : `boxSetSectionListsOnlyMissing`, `movieRowAppendsAtEnd` (les possédés gardent leur index), `noRowMakesNewRowAtEnd`, `currentMovieNeverListed`, `collectionLoadersAreGenerationGuarded`.
- [ ] **Step 2: Lancer** → échec.
- [ ] **Step 3: Implémenter.**
- [ ] **Step 4: Relancer iOS + tvOS** → vertes ; simulateur (collection du banc).
- [ ] **Step 5: Commit** — `feat(seerr): films manquants d'une saga`.

### Task 18: Page acteur

**Files:**
- Modify: `APIClientProtocol.swift:267` + `JellyfinAPIClient+Library.swift:668` (`getPersonItems(..., includeProviderIds: Bool)`), `Shared/Screens/PersonDetailScreen.swift` (pas de view model aujourd'hui : en créer un minimal `PersonDetailSeerrModel` `@MainActor @Observable` DANS ce fichier, porteur de `section: MissingSection<SeerrMissingTitle>`, chargé par `seerr.loadSection` ; section après la rangée Séries L77)
- Test: `Tests/CinemaxKitTests/SeerrMissingTests.swift` (ajout)

**Interfaces:**
- Consumes: Tasks 12–14 ; `person?.providerIDs?["Tmdb"]`.
- Produces: `static func creditTitles(_ credits: SeerrCombinedCredits, person: SeerrPerson) -> [SeerrTitle]` (cast ; crew ajouté seulement si `knownForDepartment != "Acting"` ; dédoublonné, ordre de popularité de Seerr conservé).

- [ ] **Step 1: Tests** : `actorUsesCastOnly`, `directorAddsCrew`, `ownedDropped`.
- [ ] **Step 2: Lancer** → échec.
- [ ] **Step 3: Implémenter.**
- [ ] **Step 4: Relancer iOS + tvOS** → vertes ; simulateur.
- [ ] **Step 5: Commit, mettre à jour `docs/rules/media-detail.md`, ouvrir la PR « Seerr : fiches »** (ne pas fusionner).

---

# PR 4 — Lot 3 : suivi

### Task 19: Mes demandes

**Files:**
- Create: `Shared/Seerr/SeerrMyRequests.swift` (modèle + vue de section)
- Modify: `Shared/Screens/Settings/RequestsSettingsScreen.swift` (section « Mes demandes » en tête)
- Test: `Tests/CinemaxKitTests/SeerrSessionTests.swift` (ajout)

**Interfaces:**
- Consumes: Task 3 (`requests(filter: .all, take: 20, skip:, requestedBy: mon id)` — l'id de `.connected(user)`), `movie`, `tv`), Task 7.
- Produces: `@MainActor @Observable final class SeerrMyRequestsModel { private(set) var rows: [SeerrRequestRow]; private(set) var canLoadMore: Bool; func loadFirstPage(session:) async; func loadNextPage(session:) async }` ; `struct SeerrRequestRow { request: SeerrRequest; title: String?; posterPath: String? }` — titres chargés ligne par ligne (`movie`/`tv`, en parallèle, au plus 20) car `GET /request` n'en porte pas ; `static func statusKey(_ r: SeerrRequest) -> String` : en attente ⇒ « En attente de validation », approuvée / média 3 ⇒ « Approuvée · en cours de téléchargement », refusée ⇒ « Refusée », média 5 ⇒ « Arrivée dans ta bibliothèque » + « Regarder » (`appState.pendingDeepLinkItemId = media.jellyfinMediaId`) ; série ⇒ « · saisons 4, 5 ». Affiche : `SeerrImages.posterURL` (Task 12).

- [ ] **Step 1: Tests** : `onlyMyRequests` (la requête porte `requestedBy=<mon id>`, même pour un gestionnaire), `statusLines`, `seasonsSuffix`, `pagingStopsAtTotal`, `watchUsesJellyfinId`.
- [ ] **Step 2–4:** échec → implémentation → vert (iOS + tvOS).
- [ ] **Step 5: Commit** — `feat(seerr): Mes demandes`.

### Task 20: À valider

**Files:**
- Modify: `Shared/Seerr/SeerrMyRequests.swift` (`SeerrPendingModel`), `RequestsSettingsScreen.swift` (section « À valider (N) » si `permissions.canManageRequests`)
- Test: `Tests/CinemaxKitTests/SeerrSessionTests.swift` (ajout)

**Interfaces:**
- Produces: `@MainActor @Observable final class SeerrPendingModel { private(set) var count: Int; private(set) var rows: [SeerrRequestRow]; func load(session:) async; func approve(_ id: Int, session:, toasts:, loc:) async; func decline(_ id: Int, session:, toasts:, loc:) async }` — compte = `requests(filter: .pending, take: 1, skip: 0, requestedBy: nil).total` (jamais `/request/count`, global) ; 409 « déjà traitée » ⇒ ligne retirée + toast info ; ligne : qui (`requestedBy.displayName`) et quand (`Date.RelativeFormatStyle` avec `loc.locale`).

- [ ] **Step 1: Tests** : `countFromPendingFilter`, `approveRemovesRow`, `alreadyHandledIsQuiet`, `hiddenWithoutManage`.
- [ ] **Step 2–4:** échec → implémentation → vert.
- [ ] **Step 5: Commit** — `feat(seerr): validation des demandes`.

### Task 21: Message d'arrivée

**Files:**
- Create: `Shared/Seerr/SeerrArrivalWatcher.swift`
- Modify: `Shared/DesignSystem/ToastCenter.swift` (`Toast.action: ToastAction?`, `struct ToastAction { let title: String; let perform: @MainActor () -> Void }`, `==` sur `id` seulement ; `info(_:message:duration:action:)`), `Shared/DesignSystem/Components/ToastOverlay.swift` (bouton d'action iOS dans la pilule ; tvOS : la fenêtre ne prend aucune entrée, l'action n'est pas rendue), `AppNavigation.swift` (vérification au lancement et au retour au premier plan), `SettingsKeys.swift` (`seerr.arrivals.seen.<accountKey>`, tableau `@AppStorage`)
- Test: `Tests/CinemaxKitTests/SeerrSessionTests.swift` (ajout)

**Interfaces:**
- Produces: `@MainActor enum SeerrArrivalWatcher { static func check(session:appState:defaults:toasts:loc:) async }` + pur `static func newArrivals(available: [SeerrRequest], seen: Set<Int>?) -> (toAnnounce: [SeerrRequest], seen: Set<Int>)` (`seen == nil` ⇒ premier passage : on amorce sans annoncer) ; source = `requests(filter: .available, take: 20, skip: 0, requestedBy: mon id)` (jamais les arrivées des autres) ; une arrivée ⇒ « <Titre> est disponible » (titre via `getItem` sur `jellyfinMediaId`, repli `movie`/`tv`) + action « Regarder » (iOS) ; plusieurs ⇒ « 3 demandes sont disponibles » (`loc.counted`) + « Voir » (ouvre Réglages → Demandes via `SettingsNavCoordinator`).

- [ ] **Step 1: Tests** : `managerOnlyHearsOwnArrivals`, `firstCheckSeedsSilently`, `announcesOnlyNew`, `severalBecomeOneToast`, `cappedOrHiddenNoCheck`.
- [ ] **Step 2–4:** échec → implémentation → vert (iOS + tvOS ; `ToastAnnouncementTests` toujours vert).
- [ ] **Step 5: Commit, mettre à jour `Shared/Seerr/CLAUDE.md` et `Shared/DesignSystem/CLAUDE.md` (action de toast iOS seulement), ouvrir la PR « Seerr : suivi »** (ne pas fusionner).
