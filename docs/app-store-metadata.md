# Cinemax — App Store Connect Metadata

Document non public, sert de copy-paste source pour App Store Connect. Identique pour iOS et tvOS sauf indication.

---

## 1. Identité

| Champ | Valeur |
|---|---|
| **Nom de l'app** (30 char) | `Cinemax` |
| **Bundle ID iOS** | `com.cinemax.Cinemax` *(à vérifier dans ASC — déjà set par TestFlight)* |
| **Bundle ID tvOS** | `com.cinemax.CinemaxTV` *(à vérifier dans ASC — déjà set par TestFlight)* |
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
Lecteur Jellyfin pour Apple
```
*(27 caractères)*

### Texte promotionnel (170 caractères max — modifiable sans review)
```
Nouvelle version : lecteur VLC intégré pour la prise en charge native du MKV, du Dolby Vision et du HDR.
```
*(104 caractères)*

### Description (4000 caractères max)
```
Cinemax est un client moderne pour vos serveurs Jellyfin, conçu spécifiquement pour iPhone, iPad et Apple TV. Profitez de votre médiathèque personnelle avec une interface élégante, fluide et entièrement adaptée à chaque appareil Apple.

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
• AirPlay vers Apple TV et HomePod
• Minuteur d'arrêt avec rappel « Toujours en train de regarder ? »

— RECHERCHE ET NAVIGATION
• Recherche par texte ou par voix
• Filtres par genre, par décennie, contenu non vu
• Tri alphabétique avec barre de navigation rapide
• Genres aléatoires sur l'écran d'accueil pour redécouvrir votre bibliothèque

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

Cinemax requiert un serveur Jellyfin déjà installé (jellyfin.org). Cinemax diffuse (streaming) exclusivement les vidéos de votre propre serveur : l'application ne contient aucun contenu, ne propose aucune fonction de téléchargement et ne permet d'enregistrer aucun média, quelle qu'en soit la source. Cinemax n'est ni développé ni soutenu par l'équipe officielle Jellyfin.
```

### Mots-clés (100 caractères max, séparés par virgules, sans espace)
```
jellyfin,mediatheque,streaming,film,serie,plex,emby,videotheque,musique,domotique
```
*(91 caractères)*

### Notes de version / What's New (4000 caractères max)
```
Première version publique de Cinemax !

• Lecteur VLC intégré par défaut, prise en charge native du MKV, Dolby Vision et HDR
• Picture-in-Picture sur iPhone et iPad
• Interface optimisée pour la Siri Remote sur Apple TV
• Tableau de bord d'administration complet sur iPhone et iPad
• Skip Intro / Skip Crédits, chapitres, lecture automatique de l'épisode suivant
• Recherche vocale, filtres avancés, accents personnalisables

Merci d'utiliser Cinemax. Rapports de bugs et suggestions : https://github.com/b-raillard/Cinemax/issues
```

---

## 3. Métadonnées ENGLISH

### Subtitle (30 chars max)
```
Jellyfin player for Apple
```
*(25 chars)*

### Promotional Text (170 chars max)
```
New release: built-in VLC engine for native MKV, Dolby Vision and HDR playback.
```
*(79 chars)*

### Description (4000 chars max)
```
Cinemax is a modern client for your Jellyfin media servers, designed specifically for iPhone, iPad and Apple TV. Enjoy your personal library with an elegant, fluid interface tailored to every Apple device.

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
• AirPlay to Apple TV and HomePod
• Sleep timer with "Still watching?" prompt

— SEARCH AND BROWSING
• Text or voice search
• Filter by genre, by decade, unwatched only
• Alphabetical sort with quick-jump bar
• Random genre rows on the home screen to rediscover your library

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

Cinemax requires a Jellyfin server already running (jellyfin.org). Cinemax only streams the videos from your own server: the app contains no content of its own, has no download feature, and does not save or download media of any kind, from any source. Cinemax is neither developed nor endorsed by the official Jellyfin team.
```

### Keywords (100 chars max, comma-separated, no spaces)
```
jellyfin,media,server,streaming,movies,tv,shows,plex,emby,library,hdr,dolby,vlc
```
*(79 chars)*

### What's New (4000 chars max)
```
First public release of Cinemax!

• Built-in VLC engine by default, native MKV, Dolby Vision and HDR support
• Picture-in-Picture on iPhone and iPad
• Siri Remote-optimized interface on Apple TV
• Full administration dashboard on iPhone and iPad
• Skip Intro / Skip Credits, chapters, autoplay next episode
• Voice search, advanced filters, customizable accents

Thanks for using Cinemax. Bug reports and suggestions: https://github.com/b-raillard/Cinemax/issues
```

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
Cinemax is a third-party client for Jellyfin media servers (jellyfin.org).
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
Settings → Interface → enable "Use Native Player".
```

---

## 5. Disponibilité

**Pays sélectionnés** : France, Belgique, Suisse, Luxembourg, Canada.

ASC → Pricing and Availability → Edit Countries or Regions → cocher uniquement ces 5 pays.

**Prix** : Gratuit (Tier 0).

---

## 6. Build à sélectionner

iOS : dernière build TestFlight (1.0 build N)
tvOS : dernière build TestFlight (1.0 build N)

ASC → Distribution → iOS App / tvOS App → Build → Select Build → choisir le build le plus récent processé.
