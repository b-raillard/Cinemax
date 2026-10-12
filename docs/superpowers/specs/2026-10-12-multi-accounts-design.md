# Multi-comptes sur un serveur : conception

Date : 2026-10-12. Lot 1 du chantier Pro (le lot 2 sera l'achat de JellyGlass Pro).
Maquettes et user stories : https://claude.ai/artifact/TCMdw94pHz52ynawSHdjBL (pages « Multi-comptes » et « User stories », identifiants MC-01 à MC-13).

## 1. Intention

Plusieurs membres d'un foyer partagent un appareil (l'Apple TV du salon d'abord). Aujourd'hui :
- un seul compte est connecté par serveur ;
- changer de compte (`UserSwitchSheet`) redemande le mot de passe ;
- le changement écrase la session précédente dans le registre.

Le but est de **mémoriser** plusieurs comptes d'un même serveur et de basculer d'un geste. Un code facultatif protège chaque compte, et chaque compte garde ses réglages.

## 2. Décisions actées (avec l'utilisateur, 12/10)

| Sujet | Décision |
|---|---|
| Palier | Mémoriser plusieurs comptes = **Pro**. Changer de compte avec mot de passe ou Quick Connect reste **gratuit**. |
| Avant le lancement de Pro | Livré en 2.x derrière la porte « Pro **ou** fondateur ». Tant que le pivot fondateurs n'est pas fixé, tout le monde passe (§6). |
| Protection | Code à 4 chiffres **facultatif par compte**, Face ID en option sur iOS, jamais sur tvOS. |
| Lancement | « Qui regarde ? » à l'ouverture sur **Apple TV seulement**, avec au moins 2 comptes mémorisés. Désactivable, actif par défaut. iOS rouvre le dernier compte. |
| Réglages par compte | Recherches récentes, menu personnalisé, limite d'âge, accent et thème clair/sombre. L'icône de l'app reste commune (iOS affiche une alerte à chaque changement d'icône). |
| Icône profil iPhone | En haut à droite de l'Accueil, à confirmer par l'utilisateur en recette. |
| iPad, Duo ouvert | Popover ancré sur l'avatar. En largeur compacte, `.popover` devient une feuille, ce qui couvre iPhone et Duo fermé. |
| Multi-serveurs fusionnés | Hors de ce lot. |

## 3. Faits serveur vérifiés dans le code de Jellyfin (10.9.11, 10.10.7, 10.11.0, master)

1. **Les jetons coexistent.** `SessionManager.GetAuthorizationToken` ne déconnecte que les jetons du **même utilisateur** sur ce `DeviceId` (filtre `DeviceId` + `UserId`). Plusieurs comptes peuvent partager notre `device_id` global ; il n'en faut pas un par compte.
2. **`DELETE /Devices?id=` est réservé aux administrateurs** (`[Authorize(Policy = RequiresElevation)]` sur tout `DevicesController`) et révoque **tous** les jetons de cet identifiant d'appareil, tous utilisateurs confondus. Deux conséquences :
   - **Défaut existant :** notre `ServerSessionRevoker` l'utilise. La déconnexion d'un compte non administrateur n'a donc jamais rien révoqué sur le serveur (403 ignoré).
   - **Avec plusieurs comptes**, la déconnexion d'un administrateur tuerait tous les comptes mémorisés.
   - **Correctif :** `POST /Sessions/Logout`, authentifié par le jeton à révoquer. Le serveur révoque exactement `User.GetToken()`, pour tout utilisateur.
3. **Révoquer un jeton termine toutes les sessions EN DIRECT de l'appareil** (`Logout(Device)` → `ReportSessionEnded` sur `Sessions.Where(DeviceId == …)`). Les autres jetons restent valides, mais la socket du compte actif est coupée. `JellyfinSocket` se reconnecte seul (back-off borné), ce qu'un test d'acceptation vérifie après « Retirer ce compte ».
4. **Session en direct.** Elle est indexée par `appli + appareil` jusqu'à 10.11 et par `appli + appareil + utilisateur` sur 12.x. Sur 12.x, l'ancien compte peut donc rester visible comme session inactive jusqu'à son expiration côté serveur.

## 4. Modèle de données

**Principe : le triplet actuel de `ServerEntry` (`accessToken`, `userId`, `username`) reste « le compte actif de ce serveur ».** Tous les lecteurs existants continuent de fonctionner sans changement : `hasUsableSession`, `applyActiveServer`, `IntentSessionProvider.resolveContext`, le miroir legacy et les extensions.

```swift
public struct SavedAccount: Codable, Sendable, Equatable, Identifiable {
    public var id: String { userId }
    public var userId: String
    public var username: String
    public var accessToken: String
    public var lastUsedAt: Date
}

// ServerEntry — champ OPTIONNEL (règle de l'en-tête : sinon tout [ServerEntry] échoue au décodage)
public var savedAccounts: [SavedAccount]?
```

**Pur, dans `ServerRegistry` (testé) :**
- `remembering(session, in entry)` : insère ou met à jour par `userId`.
- `activating(userId, in entry)` : recopie le compte mémorisé dans le triplet.
- `forgetting(userId, in entry)`.
- `upsert` conserve `savedAccounts` comme il conserve déjà `displayNameOverride` et `sortIndex`. Il met en plus à jour le jeton mémorisé de l'utilisateur qui vient de se connecter.
- `nextCandidate` essaie d'abord un autre compte du **même serveur**, avant de changer de serveur.

**Pas de migration de stockage.** Une entrée sans `savedAccounts` est un serveur à un compte. Le compte actif est inséré dans `savedAccounts` à la première écriture.

## 5. Orchestration (`AppState`)

Un seul point d'entrée pour basculer et pour ajouter un compte : **`switchAccount(to:)` et `addAccount(session:)` passent tous deux par la fin de `applyActiveServer`**, qui fait dans l'ordre :
1. écriture du triplet hérité ;
2. `upsert` ;
3. `reconnect` ;
4. limite d'âge du compte (§7) **avant** l'annonce ;
5. `refreshCurrentUser` (republie la session des extensions) ;
6. annonce de niveau 1 (rechargement complet) ;
7. garde de génération.

- Le jeton cible est validé **hors du client partagé** (`sessionValidator`), comme pour `switchTo` :
  - valide → bascule ;
  - invalide → le compte est marqué « session expirée » et on passe à sa reconnexion ;
  - indéterminé → refus, sans rien détruire.
- `UserSwitchSheet.performAuth` cesse d'écrire `appState.accessToken` lui-même et passe par `addAccount`. Cela corrige aussi deux défauts : l'Accueil n'était jamais rechargé, et le client restait sur le nouveau jeton si l'enregistrement dans le trousseau échouait.
- **Gratuit** : `addAccount` remplace le compte actif. L'ancien est oublié et son jeton révoqué.
- **Pro ou fondateur** : `addAccount` mémorise sans rien retirer.
- **Retirer un compte** : `ServerSessionRevoker.revoke` (désormais `POST /Sessions/Logout`) puis `forgetting`. Retirer le compte actif bascule vers un autre compte du même serveur, sinon c'est la déconnexion actuelle.
- **Une bascule ne révoque jamais rien.**
- **Identité de compte** : `activeAccountKey = "\(serverId)|\(userId)"`. C'est la clé des réglages par compte.

## 6. Porte Pro

Politique pure `ProFeatureGate.isUnlocked(proLaunched:isPro:isEarlyAdopter:)`, où `proLaunched` vaut `EarlyAdopterConfiguration.production` a un pivot. Tant que Pro n'est pas lancé, tout est ouvert. Ensuite, seuls Pro **ou** fondateur passent.

Raison : `EarlyAdopterService` ne reconnaît un fondateur que sur une transaction App Store de **production**. Le bac à sable, TestFlight et Xcode répondent « non-production », et le Debug n'évalue rien. Une porte `isPro || isEarlyAdopter` fermerait donc la fonction partout où l'on peut la tester.

## 7. Réglages par compte

**Même astuce du miroir :** les clés globales actuelles restent la valeur **courante**. Elles sont lues brutes par `PlaylistCard`, les widgets, les intents et `VLCStreamPresenter`. Chaque compte garde un instantané, et la bascule les échange.

| Réglage | Clé courante | Stockage par compte | Appliqué où |
|---|---|---|---|
| Limite d'âge | `privacy.maxContentAge` | `account.settings` (dictionnaire par clé de compte) | dans `AppState`, avant l'annonce de niveau 1 |
| Accent | `accentColor` | idem | setters de `ThemeManager` (incrément de révision) |
| Clair / sombre | `darkMode` | idem | setters de `ThemeManager` |
| Menu | `menu.profiles` (par serveur) | profil indexé par clé de compte | `MenuConfigStore.activate(profileId:)` |
| Recherches | `search.recentQueries.<serverId>` | `search.recentQueries.<serverId>.<userId>` | `SearchHistoryStore` |

- **Un compte qui n'a pas encore d'instantané hérite des valeurs courantes.** C'est sûr : un compte ajouté depuis un appareil bridé reste bridé.
- **Migration** : à la première activation d'un compte, son profil de menu et son historique sont semés depuis ceux du serveur, une fois. Un **marqueur** l'indique, jamais le fait que la liste soit vide (règle de l'historique de recherche).
- Le premier observateur d'`AppNavigation` (`activeServerId`) suit désormais `activeAccountKey` : une bascule sur le même serveur ne change pas `activeServerId`. L'ordre des observateurs reste le même : le profil est activé avant que `currentUserId` rafraîchisse les vues.
- La limite par compte se règle dans « Gérer les comptes », derrière le code parental existant.

## 8. Code par compte

- On réutilise `ParentalLockPolicy` (sel, hachage itéré, back-off sur horloge monotone, ensemble biométrique) et `ParentalLockCredential`.
- **Paramétrage, sans assouplir le contrôle parental :**
  - `makeCredential` accepte une longueur minimale ;
  - `ParentalPINPad` reçoit sa longueur maximale ;
  - les points du code deviennent réutilisables.
- Un identifiant par compte dans le trousseau **privé** : `account_lock.<serverId>.<userId>`.
- `AccountLockStore` (`@MainActor @Observable`) : enrôler, vérifier, retirer, Face ID armé sur l'ensemble biométrique, sans recours au code de l'appareil.

## 9. Interface

- **iOS** : avatar dans la barre de l'Accueil (`ToolbarItem(.topBarTrailing)`, sans `.buttonStyle(.glass)`) → `AccountSwitcher` présenté en `.popover`.
  - Il affiche une grille des comptes mémorisés (anneau d'accent sur le compte courant, cadenas, « Session expirée »), puis « Ajouter », « Gérer les comptes » et « Mes serveurs ».
  - « Ajouter » réutilise `UserSwitchSheet` (liste, saisie manuelle, Quick Connect).
  - En gratuit après le lancement : `UserSwitchSheet` directement, comme aujourd'hui.
- **tvOS** :
  - **Au lancement**, `WhoIsWatchingScreen` en `fullScreenCover` racine (quand authentifié, au moins 2 comptes, réglage actif), présenté **avant** « Quoi de neuf ». Menu y passe `nil` : l'app passe en arrière-plan.
  - **Dans l'app**, un onglet de tête **« Profil »** (le nom du compte, icône personne) affiche le même écran dans la barre. Choisir un profil bascule puis sélectionne l'onglet d'accueil. L'onglet n'existe qu'avec la porte Pro ouverte. Il est exclu du repli « accueil » de `TVBackPolicy` (`displayedTabs.first`) et de `tvTabRoot`. Menu y suit la règle de la barre d'onglets.
  - La section profil de Réglages (`SettingsTVProfileSection`) ouvre aussi cet écran.
- **Gérer les comptes** (deux plateformes) : liste, puis détail avec :
  - le code (et Face ID) ;
  - la limite d'âge, derrière le code parental ;
  - « Retirer ce compte » ;
  - sur tvOS, le réglage « Demander à l'ouverture ».
- Chaînes en fr, en et de. « N comptes » passe par `loc.counted`.

## 10. Hors de ce lot

- La feuille contextuelle Pro et la page d'achat (lot 2).
- La fusion multi-serveurs.
- L'avatar à la place de l'onglet Réglages (variante de placement, tranchée en recette).

## 11. Tests

- **`ServerRegistry`** : mémoriser, activer, oublier ; `upsert` qui conserve et met à jour ; candidat suivant sur le même serveur ; décodage d'un registre sans `savedAccounts`.
- **`AppState`** :
  - bascule valide, invalide ou indéterminée ;
  - ajout en gratuit (remplace et révoque) et en Pro (mémorise) ;
  - retrait du compte actif ou d'un autre ;
  - limite d'âge appliquée avant l'annonce.
- **`ServerSessionRevoker`** : `POST /Sessions/Logout` avec le jeton révoqué dans l'en-tête.
- **`ProFeatureGate`** : avant et après le lancement.
- **Réglages par compte** : échange, héritage, migrations à marqueur.
- **`AccountLock`** : 4 chiffres acceptés, back-off identique au code parental.
- Suites complètes iOS et tvOS (jamais `-only-testing`), `UserDefaults.isolatedForTesting()`, aucune attente fixe.
