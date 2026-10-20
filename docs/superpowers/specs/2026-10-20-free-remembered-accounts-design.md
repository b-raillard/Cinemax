# Comptes mémorisés en gratuit — design

Date : 2026-10-20. Complète `2026-10-12-multi-accounts-design.md` (multi-comptes, PR #313) et `2026-10-12-pro-purchase-design.md` (Pro, PR #314). Ce document remplace leur règle « mémoriser plusieurs comptes = Pro » par la répartition ci-dessous.

## Intention

Dans un foyer gratuit, plusieurs personnes utilisent le même iPhone ou la même Apple TV. Aujourd'hui, changer de compte en gratuit fait **oublier** l'ancien compte (sa session est révoquée et il disparaît de l'appareil) : pour revenir, il faut retaper le nom d'utilisateur ET le mot de passe. Le produit veut que la liste des comptes reste en gratuit, et que le Pro vende le **confort** : garder les sessions ouvertes pour basculer d'un geste.

Répartition décidée par le product owner le 2026-10-20 :

| | Gratuit | Pro / fondateur |
|---|---|---|
| Comptes déjà connectés sur l'appareil | listés | listés |
| Basculer vers un autre compte | mot de passe (ou Quick Connect) à CHAQUE fois | d'un geste, session gardée |
| Revenir au compte précédent | mot de passe à nouveau | d'un geste |
| Code à 4 chiffres par compte, Face ID | non | oui |
| « Qui regarde ? » au lancement (Apple TV) | non | oui (inchangé) |

## Comportement gratuit, tel que validé

1. **Lancement inchangé** : l'app ouvre le dernier compte utilisé, sans écran de choix.
2. **L'icône de profil est ouverte à tous** : l'avatar en haut à gauche sur iPhone / iPad, l'avatar à gauche de la barre d'onglets sur Apple TV (`TVAccountAvatarButton`, aujourd'hui réservé au Pro). Elle ouvre la liste des comptes déjà connectés au moins une fois sur cet appareil et ce serveur.
3. **Choisir un autre compte** demande son mot de passe, nom d'utilisateur déjà rempli. Quick Connect est proposé à côté, comme pour « Ajouter » (plus pratique sur Apple TV). Si l'authentification réussit, l'app bascule sur ce compte.
4. **Le compte quitté** : sa session est fermée (jeton révoqué côté serveur et oublié sur l'appareil), mais il reste dans la liste, avec son nom et son avatar. Il n'y a jamais qu'une session ouverte à la fois en gratuit.
5. **Revenir au compte précédent** : même chose, mot de passe à nouveau.
6. **« Ajouter »** un compte reste ouvert en gratuit (mot de passe ou Quick Connect), et le compte ajouté rejoint la liste selon la même règle.
7. **Retirer un compte** de la liste reste possible.
7 bis. **« Se déconnecter » volontairement** retire le compte de la liste (comportement actuel, décidé le 2026-10-20) et l'app suit le comportement natif de Jellyfin : l'écran de connexion n'affiche que les profils que le serveur rend publics ; un profil caché par la configuration du serveur n'a pas de raison d'être listé. Seule une BASCULE garde le compte quitté dans la liste.
8. **Mise en avant du Pro** : sur l'étape de connexion d'un compte mémorisé, une ligne du type « Avec Pro, plus besoin de mot de passe pour changer de compte » ouvre la feuille Pro. Elle remplace la ligne actuelle « Comptes mémorisés · PRO » (`ProLockedFeatureRow` dans `UserSwitchSheet`). Pas de relance automatique (règle R9 de la spec Pro).

Le Pro ne change pas : sessions gardées, bascule d'un geste, code facultatif, Face ID, « Qui regarde ? » au lancement.

## Buts, non-buts, anti-buts

- **Buts** : un compte connecté une fois reste listé en gratuit ; la bascule gratuite coûte un mot de passe, jamais un nom d'utilisateur ; le Pro garde son avantage clair (aucune ressaisie).
- **Non-buts** : rien sur le lancement ; rien sur les multi-serveurs fusionnés ; pas de refonte de l'écran de connexion ; le reste de la liste Pro n'est pas touché (l'utilisateur la revoit à part).
- **Anti-buts** (échec même si ça marche) :
  - une session d'un autre compte qui reste ouverte en gratuit (le Pro serait donné) ;
  - un compte qui disparaît de la liste juste parce qu'on en a changé ;
  - un jeton gardé localement alors que le compte est censé être déconnecté ;
  - une bascule gratuite qui contourne la limite d'âge du contrôle parental.

## Contraintes connues (état du code au 2026-10-20)

- `SavedAccount` (`Packages/CinemaxKit/.../Models/SavedAccount.swift`) porte un `accessToken: String` non optionnel, et aucune étiquette d'avatar. Tout le registre, jetons compris, est un seul blob JSON dans l'élément Keychain `servers`.
- `ServerRegistry.accounts(of:)` n'inclut le compte actif que si son jeton est non vide ; `forgetting` supprime l'entrée entière ; il n'existe aucune opération « fermer la session mais garder le compte ».
- En gratuit, `AppState.addAccount` révoque puis **oublie** tous les autres comptes, et efface leurs données (`forgetAccountData` : réglages du compte, historique de recherche, code). C'est le comportement à remplacer.
- `AppState.switchAccount` valide le jeton de la cible ; un jeton invalide donne `.needsLogin`, qui ouvre déjà `UserSwitchSheet(prefilledUsername:)` : le chemin « reconnexion » existe et sert de modèle.
- La porte est `ProFeatureGate` / `ProTier.unlocksProFeatures` ; avant le pivot du lancement Pro, tout le monde est fondateur. Le comportement gratuit ne se voit donc qu'avec le « Palier simulé » Debug ou après le lancement.
- Le `UserSwitchSheet` simple n'a pas Quick Connect ; Quick Connect n'existe que sur le chemin « Ajouter » (`LoginViewModel.addsAccount`).
- Le contrôle parental : `requiresCode` exige le code parental pour basculer vers un compte moins restreint ; une connexion par mot de passe passe par `clampSignInAgeCap` dans `addAccount`.

## Décisions de l'auteur (à vérifier en lisant)

Ces points n'ont pas été tranchés par le product owner ; ce sont mes choix, cohérents avec ce qu'il a validé.

- **Données d'un compte quitté en gratuit** : on les GARDE (accent, clair/sombre, limite d'âge, menu, historique de recherche), puisque le compte reste listé. Revenir sur le compte retrouve ses réglages. Seul son jeton disparaît. POSER un code à 4 chiffres est une fonction Pro ; un code déjà posé (pendant une période Pro) continue de protéger le compte en gratuit — demandé avant la connexion, car un compte Jellyfin peut n'avoir aucun mot de passe — et peut y être retiré (revue de sécurité du 20/10).
- **Contrôle parental en gratuit** : comme en Pro, la bascule vers un compte MOINS restreint demande d'abord le code parental (`requiresCode` → `.locked` → `AccountSwitchFlow`), PUIS le mot de passe. Chaque compte garde sa propre limite d'âge : on n'applique PAS `clampSignInAgeCap` à la reconnexion d'un compte mémorisé (sinon un aller-retour parent → enfant → parent écrirait la limite de l'enfant sur le parent). La limite d'un compte se règle depuis ce compte, dans Confidentialité, ou dans « Gérer les comptes », qui est ouvert en gratuit (c'est là qu'on retire un compte) mais sans les réglages de code et de Face ID, fonctions Pro.
- **Pas de détection du passage Pro → gratuit** (remboursement, partage familial retiré, lecture « gratuit » transitoire après une réinstallation) : une fermeture automatique serait irréversible sur une lecture parfois fausse. La règle est paresseuse : en gratuit, TOUTE bascule passe par une connexion (même vers un compte qui aurait encore un jeton, reste d'une période Pro), et chaque bascule gratuite réussie révoque et oublie les jetons de tous les autres comptes du serveur. La connexion exige d'être en ligne, donc la révocation part réellement.
- **Passage gratuit → Pro** : rien à faire ; les comptes déconnectés demandent leur mot de passe une dernière fois, puis restent ouverts.
- **« Une seule session ouverte » s'entend PAR SERVEUR** : chaque serveur garde son compte actif, le multi-serveurs reste gratuit et la fusion des serveurs est une fonction à part. Accepté : enregistrer deux fois le même serveur (IP et nom d'hôte) permettrait de garder deux sessions.
- **Expiration confirmée par le serveur** : inchangée (le compte expiré est traité comme aujourd'hui).
- **Avatar dans la liste** : un compte déconnecté s'affiche comme les autres (même tuile), avec une indication discrète qu'il faudra se reconnecter (le même traitement visuel que les comptes « expirés » d'aujourd'hui). Pas de cadenas Pro sur la tuile.
- **Un seul écran de comptes** pour les deux paliers : `AccountSwitcherView` (iOS) et `WhoIsWatchingScreen` (Apple TV) servent aussi le gratuit ; le chemin « `UserSwitchSheet` simple + ligne Pro » des Réglages disparaît au profit du même écran.

## Laissé au constructeur

- La représentation d'un compte déconnecté dans `SavedAccount` (jeton optionnel ou vide) et l'adaptation des opérations pures de `ServerRegistry`, avec leurs tests.
- Le libellé exact (fr / en / de) de la ligne Pro et de l'indication « à reconnecter », dans le ton des chaînes existantes.
- Le texte de la fonction « Comptes mémorisés » dans `ProFeatureCatalogue` (sa description doit dire « sessions gardées, bascule sans mot de passe »).
- La mise à jour de `docs/rules/server-setup-and-multi-server.md`, `Shared/Entitlements/CLAUDE.md` et des deux specs citées.

## Vérification attendue

- Tests unitaires : registre (compte déconnecté gardé, jeton absent, ordre), `addAccount` / bascule en gratuit (révocation de l'ancien jeton, compte gardé, données gardées), Pro inchangé, passage Pro → gratuit.
- Au simulateur, en « Palier simulé » Gratuit, iPhone et Apple TV : deux comptes, aller-retour par mot de passe et par Quick Connect, l'ancien compte reste listé, aucune session ouverte côté serveur pour le compte quitté (liste des appareils / sessions du serveur).
- En Pro : aucune régression (bascule d'un geste, code, « Qui regarde ? » au lancement).
