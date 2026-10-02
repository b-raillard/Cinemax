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
| Minuteur de mise en veille | Accents, icônes |
| Le thème saisonnier **pendant** sa saison | Les thèmes saisonniers **après** leur date de fin (ajout 2026-10-02) |
| Reprendre ailleurs par la rangée « Reprendre » (existe déjà) | Continuité entre appareils : badge « SUR APPLE TV », « Reprendre ici » qui arrête l'autre appareil, « Continuer sur… » depuis le lecteur (ajout 2026-10-02, §7) |
| | Demander un titre via Seerr, possiblement (ajout 2026-10-02, #173) |
| | Téléchargement hors ligne — **3.1, pas 3.0**, avec le plan du §8 (ajout 2026-10-02) |
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

## 7. Continuité entre appareils (ajout 2026-10-02, #166)

Le Handoff d'Apple (`NSUserActivity`) **n'existe pas sur Apple TV** : les symboles compilent sur tvOS, le service n'y tourne pas (forums Apple, thread 16962 ; support Apple HT204689 / HT209455). La continuité passe donc par le **serveur** : `GET /Sessions?controllableByUserId` donne l'item et la position lus sur les autres appareils du même utilisateur.

Design retenu (variante B des maquettes) : un badge « SUR APPLE TV » sur la carte de la rangée « Reprendre » et sur le héros quand c'est le même titre ; le bouton devient « Reprendre ici ». Le geste envoie `DisplayMessage` (« Lecture reprise sur … ») puis `Playstate Stop` à la source, et lance la lecture locale à la position du serveur par la paire `pendingIntentPlaybackItemId` + position. Phase 2 : « Continuer sur… » dans le HUD du lecteur iOS (réutilise la feuille de « Lire sur… »). À ne pas construire : `NSUserActivity`, contrôles persistants côté émetteur, carte « moi » dans « En direct ».

Ce qui reste gratuit : reprendre sur un autre appareil par la rangée « Reprendre », qui porte déjà la position — la RULE « la lecture n'est jamais payante » tient.

## 8. Téléchargement hors ligne : le plan pour la revue (ajout 2026-10-02)

Historique : retiré en 1.0.5 après **deux refus 5.2.3** (juillet 2026) — la réponse « le contenu vient du serveur de l'utilisateur » n'a pas suffi ; ni appel à l'App Review Board, ni preuve de droits n'avaient été tentés. D'autres clients Jellyfin le proposent sur l'App Store (Streamyfin, LiquidFin — ce dernier avec un Pro payant) ; pourquoi ils passent n'est pas public. Swiftfin, lui, ne l'a pas.

1. **Version séparée (3.1), jamais avec le lancement du Pro (3.0)** : un refus ne doit pas bloquer le Pro.
2. **Dossier de revue** : compte de démo dont la bibliothèque ne contient que des films Blender sous Creative Commons, licences citées dans les notes ; « contenu du serveur de l'utilisateur uniquement, aucune source tierce » dans la fiche et les notes ; en cas de refus, **appel à l'App Review Board** plutôt que retrait immédiat.
3. **Interrupteur** (constante ou réglage distant) pour éteindre la fonction sans réécrire l'app si Apple refuse malgré tout.
4. Le **lecteur ne lit jamais** `EntitlementStore` : seul l'acte de télécharger est Pro ; un fichier déjà téléchargé reste lisible.
5. `AppNavigation.purgeLegacyDownloads()` (nettoyage des fichiers de la 1.0.4) devra être revu pour ne pas effacer les nouveaux téléchargements — autre dossier, ou retrait du nettoyage.
