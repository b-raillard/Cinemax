# JellyGlass 2.1.0 — iOS

> « Notes de version / What's New » d'App Store Connect (4000 caractères max par langue). Copier le contenu de chaque bloc tel quel.

## Français

```
JellyGlass 2.1 : une lecture plus fiable, et beaucoup de petites attentions.

— LECTURE PLUS FIABLE
• « Lecture impossible » ne s'installe plus sur tous les titres jusqu'au redémarrage de l'app
• Une image figée en cours de film, pendant que le son et le compteur continuent, est détectée et la lecture repart d'elle-même
• Un fichier que le serveur doit convertir ne reste plus bloqué à 0:00 quand la connexion saute à l'ouverture
• Choisir à la main une piste TrueHD, muette sur Apple, affiche un avertissement et indique la piste audible

— NOUVEAU
• Saut automatique de l'intro et du générique, à activer dans Réglages → Lecture
• Une rangée « Parce que vous avez vu… » sur l'accueil
• Un code, ou Face ID, protège les réglages de contrôle parental
• Un contrôle « Reprendre la lecture » pour le Centre de contrôle et le bouton Action, et le widget « Reprendre la lecture » sur l'écran verrouillé
• Renommez et réordonnez vos serveurs ; l'historique de recherche est propre à chaque serveur
• Un serveur au certificat auto-signé s'approuve explicitement, sans repasser en http
• JellyGlass obéit à la pause, aux sauts et à l'arrêt envoyés depuis un autre appareil Jellyfin
• Fermer le lecteur pendant une séance « Regarder ensemble » demande confirmation
• Une affiche s'ouvre sur sa page par un zoom, et le logo du titre s'affiche quand l'écran est assez large
• Une présentation au premier lancement, les nouveautés après chaque mise à jour, et un rappel quand une nouvelle version est disponible
• Exportez les diagnostics depuis Réglages → Lecture, pour les joindre à un rapport de bug

— ACCESSIBILITÉ
• Le réglage « Réduire les animations » de l'iPhone est respecté
• Les commandes du lecteur sont annoncées par VoiceOver, et le texte suit les plus grandes tailles de caractères

— PERFORMANCES
• Moins de requêtes au serveur : les rangées désactivées ne sont plus chargées, et la navigation entre épisodes est bien plus légère

— BUGS CORRIGÉS
• « Reprendre » n'affiche plus la saison et la série d'un épisode sur Jellyfin 12
• Toucher un widget ouvre le bon titre, même quand une page est déjà ouverte
• Le contrôle parental s'applique aussi aux widgets
• Administration : un titre contenant une apostrophe peut de nouveau être supprimé

— RETIRÉ
• Le réglage de taille des sous-titres, sans effet sur les sous-titres au format ASS
• L'activité en direct : l'écran verrouillé affiche déjà le titre, l'affiche et la progression de la lecture

Merci d'utiliser JellyGlass. Rapports de bugs et suggestions : https://github.com/b-raillard/Cinemax/issues
```

## English

```
JellyGlass 2.1: more dependable playback, and plenty of small touches.

— MORE DEPENDABLE PLAYBACK
• "Couldn't play this video" no longer sticks to every title until the app is relaunched
• A picture that freezes mid-film while the sound and the counter carry on is now detected, and playback recovers on its own
• A file your server has to convert no longer stays stuck at 0:00 when the connection drops as it opens
• Picking a TrueHD track by hand, silent on Apple devices, shows a warning and points to the audible track

— NEW
• Automatic intro and credits skipping, to turn on in Settings → Playback
• A "Because you watched…" row on the home screen
• A passcode, or Face ID, protects the parental control settings
• A "Continue watching" control for Control Center and the Action button, and the "Continue Watching" widget on the Lock Screen
• Rename and reorder your servers; search history is kept per server
• A server with a self-signed certificate can be explicitly approved, without falling back to http
• JellyGlass follows pause, seek and stop commands sent from another Jellyfin device
• Closing the player during a Watch Together session asks for confirmation first
• A poster zooms into its title's page, and the title's logo shows when the screen is wide enough
• A tour on first launch, what's new after each update, and a reminder when a new version is available
• Export diagnostics from Settings → Playback to attach them to a bug report

— ACCESSIBILITY
• The iPhone's Reduce Motion setting is respected
• Player controls are announced by VoiceOver, and text follows the largest text sizes

— PERFORMANCE
• Fewer requests to your server: disabled home rows are no longer loaded, and episode navigation is much lighter

— BUGS FIXED
• "Continue Watching" no longer shows an episode's season and series on Jellyfin 12
• Tapping a widget opens the right title, even when a page is already open
• Parental controls now apply to the widgets too
• Administration: a title containing an apostrophe can be deleted again

— REMOVED
• The subtitle size setting, which had no effect on ASS subtitles
• The Live Activity: the Lock Screen already shows the title, artwork and playback progress

Thanks for using JellyGlass. Bug reports and suggestions: https://github.com/b-raillard/Cinemax/issues
```
