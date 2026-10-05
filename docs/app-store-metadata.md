# JellyGlass — App Store Connect Metadata

Document non public, sert de copy-paste source pour App Store Connect. Identique pour iOS et tvOS sauf indication.

---

## 1. Identité

| Champ | Valeur |
|---|---|
| **Nom de l'app FR** (30 char) | `JellyGlass pour Jellyfin` *(24)* |
| **Nom de l'app EN** (30 char) | `JellyGlass for Jellyfin` *(23)* |
| **Nom de l'app DE** (30 char) | `JellyGlass für Jellyfin` *(23)* |
| **Ancien nom** | `Cinemax` — abandonné : marque de Warner Bros. Discovery, même catégorie |
| **Bundle ID iOS** | `com.cinemax.ios` |
| **Bundle ID tvOS** | `com.cinemax.tvos` |
| **SKU** | `cinemax-ios-1` / `cinemax-tvos-1` (libre, jamais affiché) |
| **Catégorie principale** | **Photo & Vidéo** (Photo & Video) |
| **Catégorie secondaire** | **Divertissement** (Entertainment) |
| **Copyright** | `2026 Bastien Raillard` |
| **Email de contact** | `bastienraillard@gmail.com` |
| **URL de support** | `https://b-raillard.github.io/Cinemax/support.html` |
| **URL marketing** *(optionnel)* | `https://github.com/b-raillard/Cinemax` |
| **URL politique de confidentialité** | `https://b-raillard.github.io/Cinemax/privacy.html` |

---

## 2. Métadonnées FRANÇAIS (langue principale)

### Sous-titre (30 caractères max)
```
Médiathèque, films et séries
```
*(28 caractères — « Jellyfin » a quitté ce champ : il est déjà dans le nom, qui pèse plus lourd)*

### Texte promotionnel (170 caractères max — modifiable sans review)
```
Le client Jellyfin qui ne fait pas transcoder votre serveur : MKV, Dolby Vision, HDR10+, Atmos lus tels quels sur iPhone, iPad et Apple TV.
```
*(139 caractères)*

### Description (4000 caractères max)
```
JellyGlass est un client moderne pour vos serveurs Jellyfin, conçu spécifiquement pour iPhone, iPad et Apple TV. Profitez de votre médiathèque personnelle avec une interface élégante, fluide et entièrement adaptée à chaque appareil Apple.

— DESIGN PENSÉ POUR APPLE
• Design « Cinema Glass » : interface sombre, transparences subtiles, mises en page éditoriales
• Pas de bordures inutiles, focus sur vos affiches et vos arrière-plans
• Mode clair et sombre, accents de couleur personnalisables
• Police et taille d'affichage ajustables (de 80 % à 130 %)

— LECTURE VIDÉO PROFESSIONNELLE
• Moteur VLC intégré par défaut : lecture native des fichiers MKV, Dolby Vision, HDR10+, HDR10
• Picture-in-Picture sur iPhone et iPad, même pour les conteneurs MKV
• Sélection des pistes audio et sous-titres avec les vrais noms de votre serveur
• Skip Intro et Skip Crédits compatibles avec le plugin Intro Skipper
• Chapitres, miniatures de chapitres, lecture automatique de l'épisode suivant
• Fonction "Lire sur" permettant l'envoi du média sur tout autre device connecté au même compte
• Minuteur d'arrêt avec rappel « Toujours en train de regarder ? »

— RECHERCHE ET NAVIGATION
• Recherche par texte ou par voix
• Filtres par genre, par décennie, contenu non vu
• Tri alphabétique avec barre de navigation rapide
• Rangées de genres à choisir sur l'écran d'accueil

— OPTIMISÉ POUR APPLE TV
• Navigation parfaitement pensée pour la Siri Remote
• Scrubbing variable au glissement sur le pavé tactile
• Strip de chapitres focusable
• Plein écran natif sans bordures

— ADMINISTRATION DU SERVEUR (iPhone / iPad)
• Tableau de bord, gestion des utilisateurs, appareils, sessions
• Suivi de l'activité, des tâches planifiées, des plugins
• Édition des métadonnées, identification, gestion des clés d'API

— RESPECT DE VOTRE VIE PRIVÉE
• Aucune collecte de données
• Aucun service d'analyse ni de publicité
• Toutes les communications se font directement entre votre appareil et votre serveur Jellyfin
• Code source ouvert : https://github.com/b-raillard/Cinemax

JellyGlass requiert un serveur Jellyfin déjà installé (jellyfin.org). JellyGlass diffuse (streaming) exclusivement les vidéos de votre propre serveur : l'application ne contient aucun contenu, ne propose aucune fonction de téléchargement et ne permet d'enregistrer aucun média, quelle qu'en soit la source. JellyGlass n'est ni développé ni soutenu par l'équipe officielle Jellyfin.
```

### Mots-clés (100 caractères max, séparés par virgules, sans espace)
```
mediatheque,serveur,nas,mkv,4k,dolby,hdr,atmos,plex,emby,streaming,videotheque,cinema,films,series
```
*(98 caractères)*

### Notes de version / What's New (4000 caractères max)

> Rangées par version dans [`docs/release-notes/`](release-notes/README.md) : un dossier par version, un fichier `ios.md` et un fichier `tvos.md`, chacun en français, anglais et allemand.

---

## 3. Métadonnées ENGLISH

### Subtitle (30 chars max)
```
Media library, movies and TV
```
*(28 chars — “Jellyfin” left this field: it is already in the name, which ranks heavier)*

### Promotional Text (170 chars max)
```
The Jellyfin client that never makes your server transcode: MKV, Dolby Vision, HDR10+, Atmos played as-is on iPhone, iPad and Apple TV.
```
*(135 chars)*

### Description (4000 chars max)
```
JellyGlass is a modern client for your Jellyfin media servers, designed specifically for iPhone, iPad and Apple TV. Enjoy your personal library with an elegant, fluid interface tailored to every Apple device.

— DESIGN BUILT FOR APPLE
• "Cinema Glass" design: dark interface, subtle transparencies, editorial layouts
• No unnecessary borders, all the focus on your posters and backdrops
• Light and dark mode, customizable accent colors
• Adjustable font and display size (80% to 130%)

— PROFESSIONAL VIDEO PLAYBACK
• Built-in VLC engine by default: native playback of MKV, Dolby Vision, HDR10+, HDR10
• Picture-in-Picture on iPhone and iPad, even for MKV containers
• Audio and subtitle track selection with your server's real track names
• Skip Intro and Skip Credits compatible with the Intro Skipper plugin
• Chapters, chapter thumbnails, autoplay next episode
• Send your content on any other connected device with same account
• Sleep timer with "Still watching?" prompt

— SEARCH AND BROWSING
• Text or voice search
• Filter by genre, by decade, unwatched only
• Alphabetical sort with quick-jump bar
• Pick which genre rows appear on the home screen

— OPTIMIZED FOR APPLE TV
• Navigation purpose-built for the Siri Remote
• Variable touchpad scrubbing
• Focusable chapter strip
• Native full-screen, no borders

— SERVER ADMINISTRATION (iPhone / iPad)
• Dashboard, user management, devices, sessions
• Activity log, scheduled tasks, plugins
• Metadata editing, identification, API key management

— RESPECTS YOUR PRIVACY
• No data collection
• No analytics, no advertising
• All communications happen directly between your device and your Jellyfin server
• Open source: https://github.com/b-raillard/Cinemax

JellyGlass requires a Jellyfin server already running (jellyfin.org). JellyGlass only streams the videos from your own server: the app contains no content of its own, has no download feature, and does not save or download media of any kind, from any source. JellyGlass is neither developed nor endorsed by the official Jellyfin team.
```

### Keywords (100 chars max, comma-separated, no spaces)
```
media,server,nas,mkv,4k,dolby,hdr,atmos,plex,emby,streaming,library,cinema,movies,shows,homelab
```
*(95 chars)*

### What's New (4000 chars max)

> See [`docs/release-notes/`](release-notes/README.md): one folder per version, `ios.md` and `tvos.md`, each in French, English and German.

---

## 3 bis. Métadonnées DEUTSCH (depuis la 2.3.1)

> Localisation « Allemand » à ajouter dans App Store Connect (iOS et tvOS). Les captures retombent sur celles de la langue principale (français) tant qu'aucune série allemande n'est fournie. Tutoiement (« du »), comme dans l'app.

### Untertitel (30 Zeichen max.)
```
Mediathek, Filme und Serien
```
*(27 caractères)*

### Werbetext (170 Zeichen max.)
```
Der Jellyfin-Client, der deinen Server nie transkodieren lässt: MKV, Dolby Vision, HDR10+ und Atmos laufen unverändert auf iPhone, iPad und Apple TV.
```
*(149 caractères)*

### Beschreibung (4000 Zeichen max.)
```
JellyGlass ist ein moderner Client für deine Jellyfin-Medienserver, gemacht für iPhone, iPad und Apple TV. Genieße deine persönliche Mediathek mit einer eleganten, flüssigen Oberfläche, abgestimmt auf jedes Apple-Gerät.

— DESIGN FÜR APPLE
• „Cinema Glass“-Design: dunkle Oberfläche, feine Transparenzen, redaktionelle Layouts
• Keine überflüssigen Rahmen – alles dreht sich um deine Poster und Hintergrundbilder
• Heller und dunkler Modus, anpassbare Akzentfarben
• Einstellbare Schrift- und Anzeigegröße (80 % bis 130 %)

— PROFESSIONELLE VIDEOWIEDERGABE
• Integrierte VLC-Engine als Standard: native Wiedergabe von MKV, Dolby Vision, HDR10+, HDR10
• Bild-in-Bild auf iPhone und iPad, auch für MKV
• Auswahl von Tonspur und Untertiteln mit den echten Spurnamen deines Servers
• „Intro überspringen“ und „Abspann überspringen“, kompatibel mit dem Intro-Skipper-Plugin
• Kapitel mit Vorschaubildern, automatische Wiedergabe der nächsten Folge
• „Abspielen auf …“: sende deine Inhalte an jedes andere Gerät, das mit demselben Konto verbunden ist
• Schlaftimer mit „Schaust du noch?“-Abfrage

— SUCHEN UND STÖBERN
• Suche per Text oder Sprache
• Filter nach Genre und Jahrzehnt, Option „Nur ungesehene“
• Alphabetische Sortierung mit Schnellnavigation
• Wähle, welche Genre-Reihen auf der Startseite erscheinen

— OPTIMIERT FÜR APPLE TV
• Navigation, gemacht für die Siri Remote
• Variables Spulen über das Touchpad
• Fokussierbare Kapitelleiste
• Natives Vollbild, ohne Rahmen

— SERVERVERWALTUNG (iPhone / iPad)
• Dashboard, Benutzerverwaltung, Geräte, Sitzungen
• Aktivitätsprotokoll, geplante Aufgaben, Plugins
• Metadaten bearbeiten, Titel identifizieren, API-Schlüssel verwalten

— RESPEKTIERT DEINE PRIVATSPHÄRE
• Keine Datenerhebung
• Keine Analysedienste, keine Werbung
• Die gesamte Kommunikation läuft direkt zwischen deinem Gerät und deinem Jellyfin-Server
• Open Source: https://github.com/b-raillard/Cinemax

JellyGlass benötigt einen bereits laufenden Jellyfin-Server (jellyfin.org). JellyGlass streamt ausschließlich die Videos deines eigenen Servers: Die App enthält keine eigenen Inhalte, hat keine Download-Funktion und speichert keinerlei Medien, gleich aus welcher Quelle. JellyGlass wird weder vom offiziellen Jellyfin-Team entwickelt noch unterstützt.
```

### Schlüsselwörter (100 Zeichen max., durch Kommas getrennt, ohne Leerzeichen)
```
mediathek,server,nas,mkv,4k,dolby,hdr,atmos,plex,emby,streaming,filme,serien,heimkino,homelab,kino
```
*(98 caractères)*

### Neuerungen (4000 Zeichen max.)

> Siehe [`docs/release-notes/`](release-notes/README.md): ein Ordner pro Version, `ios.md` und `tvos.md`, jeweils auf Französisch, Englisch und Deutsch.

---

## 4. App Review — Informations à fournir

### Sign-In Required ?
**OUI** — l'app nécessite l'accès à un serveur Jellyfin.

### Compte démo à fournir au reviewer

Tu dois fournir un **serveur Jellyfin de test public** accessible depuis Internet pour qu'Apple puisse tester. Options :
- Héberge un mini-Jellyfin avec quelques médias libres de droits (Big Buck Bunny, Tears of Steel, contenus du domaine public) — ngrok ou Cloudflare Tunnel suffisent
- OU utilise le démo public Jellyfin si encore en ligne : `https://demo.jellyfin.org/stable`
  - User: `demo` / Password: *(à vérifier)*

À renseigner dans ASC → App Review Information :
- **URL du serveur** : `https://...`
- **Username** : `demo`
- **Password** : `...`

### Notes pour le reviewer
```
JellyGlass is a third-party client for Jellyfin media servers (jellyfin.org).
It is not affiliated with the official Jellyfin project.

A Jellyfin server is required to use the app. To test:
1. Launch the app
2. The first screen asks for a Jellyfin server URL
3. Enter the demo server URL provided in the credentials below
4. Sign in with the provided demo username and password

All media displayed in the app is streamed from the user's own Jellyfin server.
The app itself contains no media content, and provides no downloading or offline
saving of any kind — it is exclusively a streaming client.

For tvOS: same flow, server URL is entered via the on-screen keyboard.

VLC playback engine is used by default. To test the native AVPlayer fallback:
Settings → Playback → enable "Use Native Player".
```

---

## 5. Disponibilité

**Pays sélectionnés** : **tous** (175 pays ou régions), iOS et tvOS, depuis le 2026-09-30 — avant cette date l'app n'était vendue que dans 4 pays (France, Belgique, Suisse, Luxembourg ; le Canada prévu n'avait jamais été coché), ce qui la rendait invisible à toute la communauté Jellyfin anglophone et germanophone.

ASC → Tarifs et disponibilité → Disponibilité de l'app → Gérer la disponibilité → « Tous » → Suivant → Confirmer. La prise d'effet est annoncée sous 24 h. « Disponible sur les Mac à puce Apple » est coché (macOS automatique) ; Apple Vision Pro ne l'est pas.

**Prix** : Gratuit (Tier 0).

---

## 6. Build à sélectionner

**2.3.5** build **2.3.5** (iOS + tvOS) : PR #289, #290, #291, #293 ; notes dans `docs/release-notes/2.3.5/`. Préparée le 2026-10-05, pas encore envoyée.

iOS : **2.3.1** build **2.3.2** (allemand, langue au choix sur l'écran serveur, offre de langue dans « Quoi de neuf », rangée de boutons du lecteur sur écrans étroits — PR #280 et #281), envoyé sur TestFlight le 2026-10-01
tvOS : **2.3.1** build **2.3.2** (idem, sans le lecteur iOS), envoyé le même jour

**État App Store Connect au 2026-10-01** : versions iOS et tvOS **2.3.1** créées. Notes 2.3.1 en français, anglais et **allemand** (section 3 bis). Localisation **Allemand** ajoutée aux deux apps : description, mots-clés, texte promotionnel ; captures = celles du français. Dans « Informations sur l'app » : iOS `JellyGlass für Jellyfin` / `Mediathek, Filme und Serien`, tvOS `JellyGlass TV für Jellyfin` / `Filme und Serien in 4K HDR` (le nom tvOS porte « TV » dans toutes les langues). Le texte promotionnel FR + EN de la version tvOS 2.3.1 était vide à la création et a été rempli. Builds 2.3.2 attachés aux deux versions le même jour ; reste à soumettre (utilisateur).

**Captures anglaises (2026-10-01)** : téléversées dans la localisation **Anglais (États-Unis)** des deux versions 2.3.1 — iPhone 6,5″ (6), iPad 13″ (3), Apple TV (4) ; sources dans `~/Desktop/JellyGlass App Store/EN/`. L'allemand garde celles du français.

**Langue principale → anglais : REFUSÉE par App Store Connect tant que la 2.3.0 en ligne existe** — « Impossible d'enregistrer la langue principale car vous devez d'abord fournir toutes les captures d'écran requises pour chaque version dans cette langue ». La 2.3.0 publiée n'a pas de captures anglaises propres et n'est plus modifiable. **À refaire dès que la 2.3.1 est en ligne** (« Informations sur l'app » → Langue principale → Anglais (États-Unis) → Enregistrer, sur les deux apps).

**2.3.4** build **2.3.4** (iOS + tvOS) : la langue suit le système — langue propre à l'app dans les Réglages iOS, changement de langue de l'appareil — et la langue de l'app est reflétée dans les Réglages iOS ; « Noter JellyGlass » (PR #284) ; les 8 correctifs de la recette du 2026-10-02 (PR #287). Remplace la 2.3.2 (build 2.3.3), préparée le 2026-10-02 et jamais envoyée ; numéro de version aligné sur le build. À envoyer après validation de la 2.3.1.

Versions précédentes : 2.3.0 build 2.3.1 (iOS + tvOS), en ligne depuis le 2026-10-01 00 h 11 UTC.

**État App Store Connect au 2026-09-30** : la version iOS **2.3.0** est créée (« À finaliser avant soumission ») avec les notes FR 2.3.0, la localisation **Anglais (États-Unis)** ajoutée et remplie depuis la section 3 (sous-titre, texte promo, description, mots-clés, notes 2.3.0 ; captures = celles du français par défaut, jusqu'à la série EN), et les champs FR alignés sur ce document (la fiche 2.2.0 en ligne disait encore « Cinemax » dans sa description, portait d'anciens mots-clés et le sous-titre « Lecteur de serveur multimédia »). Dans « Informations sur l'app » : nom EN `JellyGlass for Jellyfin`, sous-titre EN `Media library, movies and TV`, sous-titre FR `Médiathèque, films et séries` (prise d'effet avec la 2.3.0). La version tvOS **2.3.0** est créée elle aussi (notes FR + EN 2.3.0, texte promo et mots-clés alignés sur ce document dans les deux langues). **La langue principale ne peut passer à l'anglais qu'une fois l'anglais approuvé par App Review sur une version, avec des captures EN** (aide ASC « Localize App Store information »).

`MARKETING_VERSION` et `CURRENT_PROJECT_VERSION` sont source unique dans `project.yml` (settings.base) : bumper `MARKETING_VERSION` à chaque version publique, `CURRENT_PROJECT_VERSION` à chaque archive envoyée.

ASC → Distribution → iOS App / tvOS App → Build → Select Build → choisir le build le plus récent processé.
