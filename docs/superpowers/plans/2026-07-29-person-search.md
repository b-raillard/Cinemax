# Recherche de personnes — Plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Chercher un nom d'acteur et tomber sur sa fiche, via une rangée de portraits ronds au-dessus de la grille de résultats.

**Architecture:** Un appel `GET /Persons` en parallèle du fan-out de titres existant. Le résultat étant un `BaseItemDto` comme tout le reste, le ranker, l'`ImageURLBuilder` et `PersonDetailScreen` s'appliquent sans conversion. La rangée est purement additive : elle n'existe que si elle a du contenu.

**Tech Stack:** Swift 6 strict concurrency, SwiftUI, CinemaxKit, jellyfin-sdk-swift v0.6.0, swift-testing.

**Spec:** [`docs/superpowers/specs/2026-07-29-person-search-design.md`](../specs/2026-07-29-person-search-design.md)

## Global Constraints

- La rangée n'apparaît **qu'en portée `.all`** et **uniquement si `personResults` est non vide** — pas de titre orphelin, pas d'espace réservé.
- Un échec de `searchPersons` ne doit **jamais** toucher `results` ni `searchFailed` : la rangée absente *est* le mode dégradé.
- Plafond : **10** portraits.
- Toute chaîne visible passe par `loc.localized(...)` et existe dans **fr et en** (`Resources/{fr,en}.lproj/Localizable.strings`). Nouvelle clé : `search.people`.
- Le matching reste dans `LibrarySearchRanker` — SSOT partagé avec les App Intents.
- tvOS : `.scrollClipDisabled()` sur la rangée (les cartes grossissent à 1.06 en focus), `CinemaTVCardButtonStyle` sur le lien, `.plain` sur iOS.
- Ne **pas** utiliser `git add -A` (le `.gitignore` de `.superpowers/` n'est pas encore sur `main`, et Xcode repollue `project.pbxproj` à chaque build). Toujours des chemins explicites.
- Tests : suite complète via `xcodebuild test -scheme Cinemax`. `-only-testing` exécute silencieusement 0 test swift-testing.

---

### Task 1 : `searchPersons` sur `LibraryAPI`

**Files:**
- Modify: `Packages/CinemaxKit/Sources/CinemaxKit/Networking/APIClientProtocol.swift` (protocole `LibraryAPI`)
- Modify: `Packages/CinemaxKit/Sources/CinemaxKit/Networking/JellyfinAPIClient+Library.swift` (à côté de `getPersonItems`)
- Modify: `Tests/CinemaxKitTests/MockAPIClient.swift`

**Interfaces:**
- Consumes: rien.
- Produces: `LibraryAPI.searchPersons(userId:searchTerm:limit:) async throws -> [BaseItemDto]` ; sur le mock, `searchPersonsHandler: (@Sendable (String) async throws -> [BaseItemDto])?` et `stubbedPersonResults: [BaseItemDto]`.

**Note :** deux types conforment à `LibraryAPI` — `JellyfinAPIClient` et `MockAPIClient`. Les deux doivent implémenter la méthode ; pas d'implémentation par défaut vide, le mock est activement piloté par les tests des tâches suivantes.

- [ ] **Step 1: Déclarer la méthode sur le protocole**

Dans `APIClientProtocol.swift`, dans `LibraryAPI`, à côté de `getPersonItems` :

```swift
    /// Personnes dont le nom correspond à `searchTerm`. Renvoie des `BaseItemDto`
    /// (les personnes SONT des items Jellyfin), donc le même modèle que les
    /// titres — le classement et la construction d'URL d'image s'y appliquent
    /// sans conversion.
    func searchPersons(userId: String, searchTerm: String, limit: Int) async throws -> [BaseItemDto]
```

- [ ] **Step 2: Implémenter côté client**

Dans `JellyfinAPIClient+Library.swift`, sous la marque `// MARK: - Persons` :

```swift
    public func searchPersons(userId: String, searchTerm: String, limit: Int) async throws -> [BaseItemDto] {
        guard let client = getClient() else { throw JellyfinError.notAuthenticated }
        var params = Paths.GetPersonsParameters()
        params.userID = userId
        params.searchTerm = searchTerm
        params.limit = limit
        params.enableImages = true
        let response = try await client.send(Paths.getPersons(parameters: params))
        return response.value.items ?? []
    }
```

Lire les méthodes voisines avant d'écrire : reprendre leur façon d'obtenir le client et de lever en cas d'absence de session, plutôt que de supposer `JellyfinError.notAuthenticated`.

- [ ] **Step 3: Étendre le mock**

Dans `MockAPIClient.swift`, sur le patron exact de `searchItems` :

```swift
    var searchPersonsHandler: (@Sendable (String) async throws -> [BaseItemDto])?
    var stubbedPersonResults: [BaseItemDto] = []

    func searchPersons(userId: String, searchTerm: String, limit: Int) async throws -> [BaseItemDto] {
        if let handler = searchPersonsHandler {
            return try await handler(searchTerm)
        }
        if shouldThrow { throw stubbedError }
        return stubbedPersonResults
    }
```

Adapter la déclaration des propriétés au style de concurrence du fichier (les autres stubs y sont déjà conformes — reprendre leur forme, notamment si elles sont `nonisolated(unsafe)` ou protégées par `recordLock`).

- [ ] **Step 4: Vérifier que tout compile**

```bash
set -o pipefail; xcodebuild test -project Cinemax.xcodeproj -scheme Cinemax -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | grep -E "error:|Test run with|TEST (SUCCEEDED|FAILED)" | head -8
```

Attendu : `** TEST SUCCEEDED **`, aucune régression (rien n'appelle encore la nouvelle méthode).

- [ ] **Step 5: Commit**

```bash
git add Packages/CinemaxKit/Sources/CinemaxKit/Networking/APIClientProtocol.swift Packages/CinemaxKit/Sources/CinemaxKit/Networking/JellyfinAPIClient+Library.swift Tests/CinemaxKitTests/MockAPIClient.swift
git commit -m "feat(search): exposer GET /Persons sur LibraryAPI"
```

---

### Task 2 : `LibrarySearchRanker.rankPersons`

**Files:**
- Modify: `Shared/ViewModels/LibrarySearchRanker.swift`
- Test: `Tests/CinemaxKitTests/LibrarySearchRankerTests.swift` (créer si absent — vérifier d'abord)

**Interfaces:**
- Consumes: `LibraryAPI.searchPersons` (Task 1).
- Produces: `LibrarySearchRanker.rankPersons(query:userId:api:) async -> [BaseItemDto]`.

- [ ] **Step 1: Écrire les tests qui échouent**

Vérifier d'abord si `LibrarySearchRankerTests.swift` existe (`ls Tests/CinemaxKitTests/`) et, le cas échéant, ajouter les tests à la suite existante plutôt que d'en créer une seconde.

```swift
    @Test("rankPersons returns matches ordered by score")
    func personsRankedByScore() async throws {
        let mock = MockAPIClient()
        mock.stubbedPersonResults = [
            .personStub(id: "p1", name: "Cillian Murphy Jr."),
            .personStub(id: "p2", name: "Cillian Murphy"),
        ]

        let result = await LibrarySearchRanker.rankPersons(
            query: "cillian murphy", userId: "u1", api: mock
        )
        // Exact match outranks the longer near-match.
        #expect(result.map(\.id) == ["p2", "p1"])
    }

    @Test("rankPersons drops zero-score noise the server returned")
    func personsDropNonMatches() async throws {
        let mock = MockAPIClient()
        mock.stubbedPersonResults = [
            .personStub(id: "p1", name: "Cillian Murphy"),
            .personStub(id: "p2", name: "Zendaya"),
        ]

        let result = await LibrarySearchRanker.rankPersons(
            query: "murphy", userId: "u1", api: mock
        )
        #expect(result.map(\.id) == ["p1"])
    }

    @Test("rankPersons caps at 10")
    func personsCapped() async throws {
        let mock = MockAPIClient()
        mock.stubbedPersonResults = (0..<25).map {
            .personStub(id: "p\($0)", name: "Murphy \($0)")
        }

        let result = await LibrarySearchRanker.rankPersons(
            query: "murphy", userId: "u1", api: mock
        )
        #expect(result.count == 10)
    }

    @Test("rankPersons swallows a failure and returns empty")
    func personsFailureIsSilent() async throws {
        let mock = MockAPIClient()
        mock.shouldThrow = true

        let result = await LibrarySearchRanker.rankPersons(
            query: "murphy", userId: "u1", api: mock
        )
        #expect(result.isEmpty)
    }
```

Ajouter le constructeur de fixture en bas du fichier de tests :

```swift
private extension BaseItemDto {
    static func personStub(id: String, name: String) -> BaseItemDto {
        var dto = BaseItemDto()
        dto.id = id
        dto.name = name
        dto.type = .person
        return dto
    }
}
```

- [ ] **Step 2: Lancer les tests pour vérifier l'échec**

```bash
set -o pipefail; xcodebuild test -project Cinemax.xcodeproj -scheme Cinemax -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | grep -E "error:|✘|TEST (SUCCEEDED|FAILED)" | head -10
```

Attendu : **échec de compilation** — `rankPersons` n'existe pas.

- [ ] **Step 3: Implémenter**

Dans `LibrarySearchRanker.swift`, après `rank` :

```swift
    /// Personnes correspondant à la requête, classées pour l'affichage.
    ///
    /// Contrairement à `rank`, un seul appel serveur : le `searchTerm` de
    /// Jellyfin est contigu et sensible à la ponctuation, ce qui casse les
    /// titres (« Mission Impossible » rate « Mission : Impossible ») mais pas
    /// les noms de personnes, où un `contains` suffit — « murphy » trouve
    /// « Cillian Murphy ». Le classement local ne sert donc qu'à l'ordre
    /// d'affichage.
    ///
    /// Un échec est avalé : la rangée absente EST le mode dégradé, et le
    /// résultat principal (les titres) n'a pas à en souffrir.
    static func rankPersons(
        query: String,
        userId: String,
        api: any LibraryAPI
    ) async -> [BaseItemDto] {
        let normalizedQuery = normalize(query)
        let words = significantWords(in: normalizedQuery)
        guard !normalizedQuery.isEmpty else { return [] }

        guard let people = try? await api.searchPersons(
            userId: userId, searchTerm: query, limit: personFetchLimit
        ) else { return [] }

        let scored = people.compactMap { person -> (item: BaseItemDto, score: Double)? in
            let value = Self.score(title: person.name ?? "", fullQuery: normalizedQuery, queryWords: words)
            return value > 0 ? (person, value) : nil
        }
        return scored.sorted { $0.score > $1.score }.prefix(personRowLimit).map(\.item)
    }
```

et les constantes à côté de `maxQueryLength` (les rendre `nonisolated` si `maxQueryLength` l'est — escape hatch #3 documenté) :

```swift
    /// On demande large au serveur puis on filtre localement, mais la rangée
    /// n'en montre que les meilleurs : c'est une affordance secondaire, pas la
    /// réponse principale.
    static let personFetchLimit = 30
    static let personRowLimit = 10
```

- [ ] **Step 4: Lancer les tests pour vérifier le succès**

```bash
set -o pipefail; xcodebuild test -project Cinemax.xcodeproj -scheme Cinemax -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | grep -E "error:|✘|Test run with|TEST (SUCCEEDED|FAILED)" | head -10
```

Attendu : les quatre tests passent.

- [ ] **Step 5: Commit**

```bash
git add Shared/ViewModels/LibrarySearchRanker.swift Tests/CinemaxKitTests/
git commit -m "feat(search): classer les personnes dans LibrarySearchRanker"
```

---

### Task 3 : Câblage dans `SearchViewModel`

**Files:**
- Modify: `Shared/ViewModels/SearchViewModel.swift`
- Test: le fichier de tests de la Task 2

**Interfaces:**
- Consumes: `LibrarySearchRanker.rankPersons` (Task 2).
- Produces: `SearchViewModel.personResults: [BaseItemDto]`.

- [ ] **Step 1: Écrire les tests qui échouent**

```swift
    @Test("a person search failure leaves title results untouched")
    func personFailureDoesNotBreakTitles() async throws {
        let mock = MockAPIClient()
        mock.stubbedSearchResults = [.personStub(id: "m1", name: "Oppenheimer")]
        mock.searchPersonsHandler = { _ in throw MockAPIClient.StubError.failed }

        let ranked = await LibrarySearchRanker.rank(
            query: "oppenheimer", userId: "u1",
            includeItemTypes: [.movie], api: mock
        )
        let people = await LibrarySearchRanker.rankPersons(
            query: "oppenheimer", userId: "u1", api: mock
        )
        #expect(ranked.items.count == 1)
        #expect(ranked.failed == false)
        #expect(people.isEmpty)
    }
```

Adapter `MockAPIClient.StubError.failed` au type d'erreur réellement exposé par le mock (lire `stubbedError` avant d'écrire).

- [ ] **Step 2: Lancer les tests pour vérifier l'échec**

```bash
set -o pipefail; xcodebuild test -project Cinemax.xcodeproj -scheme Cinemax -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | grep -E "error:|✘|TEST (SUCCEEDED|FAILED)" | head -10
```

- [ ] **Step 3: Ajouter l'état**

Dans `SearchViewModel`, à côté de `results` :

```swift
    /// Personnes correspondant à la requête. Alimenté uniquement en portée
    /// `.all` ; la rangée n'est dessinée que si ce tableau est non vide, donc un
    /// échec de la recherche de personnes se traduit par une absence de rangée
    /// et non par un état d'erreur.
    var personResults: [BaseItemDto] = []
```

- [ ] **Step 4: Vider aux mêmes endroits que `results`**

Dans `search(using:)`, dans la garde de requête vide :

```swift
        guard !query.isEmpty else {
            results = []
            personResults = []
            hasSearched = false
            searchFailed = false
            return
        }
```

- [ ] **Step 5: Lancer les deux recherches en parallèle**

Toujours dans `search(using:)`, remplacer l'appel unique à `rank` par un `async let` :

```swift
            // Les deux fetchs sont indépendants : une recherche de personnes en
            // échec ne doit jamais dégrader le résultat principal. `searchFailed`
            // reste donc piloté par les titres seuls.
            async let titles = LibrarySearchRanker.rank(
                query: query, userId: userId,
                includeItemTypes: includeItemTypes, api: api
            )
            async let people: [BaseItemDto] = includeItemTypes == SearchScope.all.includeItemTypes
                ? LibrarySearchRanker.rankPersons(query: query, userId: userId, api: api)
                : []

            let outcome = await titles
            let persons = await people
            guard !Task.isCancelled else { return }
            self?.results = outcome.items
            self?.personResults = persons
```

Si la comparaison de portée par tableau se révèle fragile à l'écriture, capturer `let isAllScope = scope == .all` avant le `Task` et tester ce booléen — c'est l'intention réelle.

Le reste du corps (`searchFailed`, `hasSearched`, `recordRecentSearch`) est inchangé : il continue de ne regarder que `outcome`.

- [ ] **Step 6: Lancer les tests pour vérifier le succès**

```bash
set -o pipefail; xcodebuild test -project Cinemax.xcodeproj -scheme Cinemax -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | grep -E "error:|✘|Test run with|TEST (SUCCEEDED|FAILED)" | head -10
```

- [ ] **Step 7: Commit**

```bash
git add Shared/ViewModels/SearchViewModel.swift Tests/CinemaxKitTests/
git commit -m "feat(search): peupler les résultats personnes en portée Tout"
```

---

### Task 4 : La rangée dans `SearchScreen`

**Files:**
- Modify: `Shared/Screens/SearchScreen.swift`
- Modify: `Resources/fr.lproj/Localizable.strings`
- Modify: `Resources/en.lproj/Localizable.strings`

**Interfaces:**
- Consumes: `SearchViewModel.personResults` (Task 3).
- Produces: rien (feuille).

**Note :** pas de test unitaire — c'est de la vue SwiftUI. Vérification par build sur les deux plateformes + contrôle visuel.

- [ ] **Step 1: Ajouter la clé de localisation dans les deux langues**

`Resources/fr.lproj/Localizable.strings`, près de `search.topMatches` (ligne ~148) :

```
"search.people" = "Personnes";
```

`Resources/en.lproj/Localizable.strings`, même endroit :

```
"search.people" = "People";
```

- [ ] **Step 2: Écrire la rangée**

Dans `SearchScreen.swift`, à côté de `SearchResultsGrid` (fichier-privé, même niveau) :

```swift
/// Horizontal row of person matches, shown above the poster grid. Rendered only
/// when there are matches — an empty "People" heading over nothing is a visual
/// bug, and the majority of searches target a title, not a person.
private struct SearchPersonRow: View {
    let people: [BaseItemDto]
    let imageBuilder: ImageURLBuilder
    let title: String
    let horizontalPadding: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing3) {
            Text(title)
                .font(CinemaFont.label(.large))
                .foregroundStyle(CinemaColor.onSurfaceVariant)
                .padding(.horizontal, horizontalPadding)
                .accessibilityAddTraits(.isHeader)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: CinemaSpacing.spacing4) {
                    ForEach(people, id: \.id) { person in
                        personLink(person)
                    }
                }
                .padding(.horizontal, horizontalPadding)
            }
            // The focused card grows to 1.06 on tvOS — without this the edge
            // portrait gets clipped by the scroll view's bounds.
            .scrollClipDisabled()
        }
    }

    @ViewBuilder
    private func personLink(_ person: BaseItemDto) -> some View {
        if let id = person.id {
            NavigationLink {
                PersonDetailScreen(personId: id, personName: person.name ?? "")
            } label: {
                CastCircle(
                    name: person.name ?? "",
                    imageURL: imageBuilder.imageURL(
                        itemId: id, imageType: .primary, maxWidth: 300,
                        tag: person.primaryImageTagValue
                    )
                )
            }
            #if os(tvOS)
            .buttonStyle(CinemaTVCardButtonStyle())
            #else
            .buttonStyle(.plain)
            #endif
            .accessibilityLabel(person.name ?? "")
        }
    }
}
```

Vérifier avant d'écrire la signature exacte de `CastCircle` et de `imageURL(itemId:imageType:maxWidth:tag:)` — les reprendre depuis `MediaDetailCastSection.swift`, qui fait exactement ce rendu.

- [ ] **Step 3: Insérer la rangée au-dessus de la grille**

Dans `resultContent`, la branche finale (celle qui rend `SearchResultsGrid`) devient un `VStack` portant la rangée puis la grille. La rangée est conditionnée par **deux** critères : portée `.all` et tableau non vide.

`SearchResultsGrid` possède son propre `ScrollView` ; la rangée doit donc être placée **à l'intérieur** de son `LazyVStack`, pas au-dessus du `ScrollView` (sinon elle reste figée pendant que la grille défile). Le plus simple : passer la rangée à `SearchResultsGrid` via un nouveau paramètre `header: AnyView?` ou un `@ViewBuilder`, rendu en tête de son `LazyVStack` avant le titre « Meilleurs résultats ». Lire `SearchResultsGrid` et choisir la forme la moins invasive.

- [ ] **Step 4: Vérifier les deux builds, sérialisés**

```bash
set -o pipefail; xcodebuild build -project Cinemax.xcodeproj -scheme Cinemax -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | head -6
```

```bash
set -o pipefail; xcodebuild build -project Cinemax.xcodeproj -scheme CinemaxTV -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | head -6
```

- [ ] **Step 5: Vérifier la parité des chaînes**

Lancer le skill `localize-check` du projet, ou à défaut comparer les clés :

```bash
diff <(grep -o '^"[^"]*"' Resources/fr.lproj/Localizable.strings | sort) <(grep -o '^"[^"]*"' Resources/en.lproj/Localizable.strings | sort) && echo "parité OK"
```

- [ ] **Step 6: Commit**

```bash
git add Shared/Screens/SearchScreen.swift Resources/fr.lproj/Localizable.strings Resources/en.lproj/Localizable.strings
git commit -m "feat(search): rangée de personnes au-dessus des résultats"
```

---

### Task 5 : Documenter dans CLAUDE.md

**Files:**
- Modify: `CLAUDE.md` (section « SearchScreen »)

- [ ] **Step 1: Ajouter la puce**

Dans la section `## SearchScreen`, après la puce des chips de filtre :

```markdown
- **Rangée « Personnes »** (`SearchPersonRow`, file-private dans `SearchScreen.swift`) : portraits ronds (`CastCircle`) au-dessus de la grille, poussant vers `PersonDetailScreen`. Alimentée par `LibrarySearchRanker.rankPersons` → `LibraryAPI.searchPersons` → `GET /Persons`. **RULE — `/Persons` et non `/Search/Hints`** : le premier renvoie un `BaseItemDtoQueryResult`, donc des `BaseItemDto` comme le reste du pipeline (le score, l'`ImageURLBuilder` et `PersonDetailScreen` s'y appliquent sans conversion) ; `/Search/Hints` renverrait un modèle `SearchHint` distinct et forkerait le pipeline de recherche en deux formes de résultat. **Un seul appel serveur**, pas le fan-out par mot de `rank` : le `searchTerm` contigu de Jellyfin casse les titres à ponctuation (« Mission : Impossible ») mais pas les noms de personnes, où un `contains` suffit. **RULE — la rangée n'existe qu'en portée `.all` ET avec des résultats** : un filtre de type qui montre autre chose que le type demandé n'est plus un filtre, et un intitulé « Personnes » au-dessus du vide est un bug visuel (cas le plus fréquent — la plupart des recherches visent un titre). **RULE — un échec de `searchPersons` ne touche ni `results` ni `searchFailed`** : la rangée absente EST le mode dégradé ; l'écran d'erreur avec Réessayer reste piloté par la seule recherche de titres. Plafond 10 portraits (`personRowLimit`), fetch serveur à 30. Les personnes ne portant pas de classification, la rangée peut montrer un acteur dont tous les films sont masqués par `privacy.maxContentAge` — sans rien révéler, `PersonDetailScreen` passant par `getPersonItems`, déjà plafonné.
```

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs(claude): consigner la rangée de recherche de personnes"
```

---

## Self-Review

**Couverture du spec :**

| Exigence | Tâche |
|---|---|
| `GET /Persons` sur `LibraryAPI`, deux conformeurs | 1 |
| `rankPersons` : un appel, score local, plafond 10 | 2 |
| Échec avalé → tableau vide | 2 |
| `personResults` sur le view model, vidé avec `results` | 3 |
| Portée `.all` uniquement, aucun appel sinon | 3 |
| Isolation de l'échec (`results` / `searchFailed` intacts) | 3 |
| Rangée absente si vide | 4 (Step 3) |
| `CastCircle` + `ContentRow`, `.scrollClipDisabled()`, styles par plateforme | 4 |
| Clé `search.people` en fr et en | 4 |
| Note contrôle parental | 5 |

**Cohérence des types :** `searchPersons(userId:searchTerm:limit:)` et `rankPersons(query:userId:api:)` sont employés à l'identique dans les tâches 1→3. `personFetchLimit` (30, serveur) et `personRowLimit` (10, affichage) sont deux constantes distinctes et nommées comme telles partout.

**Zone d'incertitude assumée :** le Step 3 de la Task 4 ne fige pas la forme exacte de l'insertion dans `SearchResultsGrid` (paramètre `header` contre `@ViewBuilder`). C'est délibéré — le choix dépend de la structure réelle du `LazyVStack`, et la contrainte qui compte (la rangée défile avec la grille, elle n'est pas au-dessus du `ScrollView`) est, elle, explicite.
