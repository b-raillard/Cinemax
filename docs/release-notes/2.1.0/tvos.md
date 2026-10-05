# JellyGlass 2.1.0 — tvOS (Apple TV)

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
• Un code protège les réglages de contrôle parental
• Renommez et réordonnez vos serveurs ; l'historique de recherche est propre à chaque serveur
• Un serveur au certificat auto-signé s'approuve explicitement, sans repasser en http
• L'Apple TV obéit à la pause, aux sauts et à l'arrêt envoyés depuis un autre appareil Jellyfin
• Fermer le lecteur pendant une séance « Regarder ensemble » demande confirmation
• Une présentation au premier lancement, les nouveautés après chaque mise à jour, et un rappel quand une nouvelle version est disponible

— ACCESSIBILITÉ
• Le réglage « Réduire les animations » de l'Apple TV est respecté

— PERFORMANCES
• Moins de requêtes au serveur : les rangées désactivées ne sont plus chargées, et la navigation entre épisodes est bien plus légère

— BUGS CORRIGÉS
• « Reprendre » n'affiche plus la saison et la série d'un épisode sur Jellyfin 12
• Le Top Shelf ouvre le bon titre, même quand une page est déjà ouverte
• Le contrôle parental s'applique aussi au Top Shelf

— RETIRÉ
• Le réglage de taille des sous-titres, sans effet sur les sous-titres au format ASS

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
• A passcode protects the parental control settings
• Rename and reorder your servers; search history is kept per server
• A server with a self-signed certificate can be explicitly approved, without falling back to http
• Your Apple TV follows pause, seek and stop commands sent from another Jellyfin device
• Closing the player during a Watch Together session asks for confirmation first
• A tour on first launch, what's new after each update, and a reminder when a new version is available

— ACCESSIBILITY
• The Apple TV's Reduce Motion setting is respected

— PERFORMANCE
• Fewer requests to your server: disabled home rows are no longer loaded, and episode navigation is much lighter

— BUGS FIXED
• "Continue Watching" no longer shows an episode's season and series on Jellyfin 12
• The Top Shelf opens the right title, even when a page is already open
• Parental controls now apply to the Top Shelf too

— REMOVED
• The subtitle size setting, which had no effect on ASS subtitles

Thanks for using JellyGlass. Bug reports and suggestions: https://github.com/b-raillard/Cinemax/issues
```
