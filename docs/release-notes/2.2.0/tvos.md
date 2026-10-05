# JellyGlass 2.2.0 — tvOS (Apple TV)

> « Notes de version / What's New » d'App Store Connect (4000 caractères max par langue). Copier le contenu de chaque bloc tel quel.

## Français

```
JellyGlass 2.2 : Cinemax change de nom, et gagne en fiabilité, en accessibilité et en contrôle parental.

— NOUVEAU NOM
• Cinemax devient JellyGlass. Même application : vos serveurs et vos réglages restent en place, rien à refaire

— CONTRÔLE PARENTAL RENFORCÉ
• La limite d'âge s'applique à toute lecture, y compris depuis les rangées « Reprendre » et « À suivre », et à l'épisode suivant
• Un épisode sans classification est jugé sur celle de sa série
• Un titre au-delà de la limite, ouvert depuis le Top Shelf, affiche « Contenu restreint »
• Un nouveau code compte de 6 à 8 chiffres ; votre code actuel reste valable

— LECTURE PLUS FIABLE
• Fermer le lecteur avant la reprise n'efface plus votre point de reprise
• Aller jusqu'à la fin d'un épisode avec la barre le termine, au lieu de rejouer ses dernières secondes en boucle
• Au réveil de l'Apple TV, une reprise qui échoue affiche une alerte au lieu d'un chargement sans fin
• Quand le lecteur se relance de lui-même, il garde la version et les pistes audio et sous-titres que vous aviez choisies
• Un déplacement dans la barre qui ne reprend jamais relance la lecture à l'endroit visé, au lieu d'une image figée
• Un épisode suivant qui ne s'ouvre pas affiche une erreur au lieu d'un chargement sans fin
• Le « Reprendre » de l'affiche d'accueil repart au bon endroit après une lecture

— APPLE TV
• L'accueil au repos sollicite beaucoup moins l'Apple TV : l'animation de l'affiche est confiée au système
• Les textes parlent de la télécommande (« Retour ») et non plus de gestes tactiles
• Le bouton Retour dans le salon « Regarder ensemble » demande « Quitter la séance ? »
• Le choix des langues du profil s'ouvre en liste plein écran, avec l'option actuelle marquée

— ACCESSIBILITÉ
• VoiceOver annonce si un titre est vu ou en cours, et nomme la série, la saison et l'épisode des cartes « Reprendre » et « À suivre »
• Les messages de confirmation et d'erreur sont lus par VoiceOver
• Les boutons aux accents jaune, cyan et orange sont lisibles, et chaque couleur du sélecteur est nommée
• Les sous-titres des cartes sont plus lisibles, et les panneaux translucides suivent Réduire la transparence et Augmenter le contraste

— LANGUE
• Les dates et les notes suivent la langue de l'app (« 7,5 »), le type d'un titre est traduit (« Film », « Série ») et les pluriels sont justes (« 1 film »)

— AUSSI
• Les favoris sont accessibles depuis Réglages → Compte
• Un serveur injoignable le dit, avec un bouton Réessayer, au lieu d'annoncer une bibliothèque vide
• Le Top Shelf fonctionne avec un serveur au certificat auto-signé que vous avez approuvé

— BUGS CORRIGÉS
• « Lire sur… » trouve de nouveau vos appareils, au lieu d'afficher « Aucun appareil disponible »
• Juste après une connexion, l'Apple TV reçoit tout de suite les lectures envoyées depuis un autre appareil
• « Marquer comme vu » sur la page d'un titre retire aussi sa reprise
• Un changement de serveur qui échoue ne fait plus disparaître « Passer l'intro » ni la rangée Collections
• La liste d'épisodes correspond toujours à la saison sélectionnée
• Page d'un titre : la ligne Version n'affiche plus « 4K · 4K »

Merci d'utiliser JellyGlass. Rapports de bugs et suggestions : https://github.com/b-raillard/Cinemax/issues
```

## English

```
JellyGlass 2.2: Cinemax gets a new name, and becomes more dependable, more accessible and safer for families.

— A NEW NAME
• Cinemax is now JellyGlass. Same app: your servers and settings stay right where they were, nothing to set up again

— STRONGER PARENTAL CONTROLS
• The age limit now applies to everything you play, including from the "Continue Watching" and "Next Up" rows, and to the next episode
• An unrated episode is judged on its series' rating
• A title above the limit, opened from the Top Shelf, shows "Restricted content"
• A new PIN is 6 to 8 digits; your current PIN still works

— MORE DEPENDABLE PLAYBACK
• Closing the player before it has resumed no longer erases your resume point
• Scrubbing to the very end of an episode ends it, instead of replaying its last seconds in a loop
• When the Apple TV wakes up, a resume that fails shows an alert instead of an endless spinner
• When the player restarts itself, it keeps the version and the audio and subtitle tracks you had chosen
• A seek that never lands restarts playback at the position you picked, instead of leaving a frozen picture
• A next episode that fails to open shows an error instead of an endless spinner
• The home screen's featured "Resume" picks up at the right place after you watch something

— APPLE TV
• The home screen at rest works the Apple TV far less: the featured artwork's motion is handed to the system
• Hints talk about the remote ("Back") rather than touch gestures
• The Back button in the Watch Together lobby asks "Leave the session?"
• Profile language choices open as a full-screen list, with the current one marked

— ACCESSIBILITY
• VoiceOver tells you whether a title is watched or in progress, and names the series, season and episode on "Continue Watching" and "Next Up" cards
• Confirmation and error messages are read by VoiceOver
• Buttons in the yellow, cyan and orange accents are readable, and every colour in the picker has a name
• Card subtitles are easier to read, and translucent panels follow Reduce Transparency and Increase Contrast

— LANGUAGE
• Dates and ratings follow the app's language, a title's type is translated, and plurals are right ("1 film" in French)

— ALSO
• Favorites can be reached from Settings → Account
• An unreachable server says so, with a Retry button, instead of announcing an empty library
• The Top Shelf works with a server whose self-signed certificate you approved

— BUGS FIXED
• "Play on…" finds your devices again, instead of showing "No device available"
• Right after you sign in, the Apple TV receives playback sent from another device straight away
• "Mark as watched" on a title's page also clears its resume point
• A failed server switch no longer makes "Skip Intro" and the Collections row disappear
• The episode list always matches the selected season
• Title page: the Version line no longer reads "4K · 4K"

Thanks for using JellyGlass. Bug reports and suggestions: https://github.com/b-raillard/Cinemax/issues
```
