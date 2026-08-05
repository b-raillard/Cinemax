# Passation — Saccades 4K sur Apple TV (session locale)

> Document de travail pour reprendre ce diagnostic depuis une session Claude Code **locale sur le Mac de Bastien**. Branche : `claude/apple-tv-video-stuttering-2ceqpg`. Rédigé depuis une session remote (Linux, sans Xcode) le 2026-08-04. À supprimer une fois le sujet clos.

## 1. Symptôme et état du diagnostic

« 72 heures » (2026) saccade sur l'Apple TV 4K 2022 (A15, tvOS 26) via le lecteur VLC de l'app — « des images qui manquent, pas de coupure buffer » — alors qu'il est fluide sur iPhone 17 Pro (même app, même réseau, même instant) et en web Safari. Tout le reste du catalogue est fluide sur l'Apple TV, **y compris d'autres 4K HDR10 HEVC**.

### Films témoins (fiches média complètes vérifiées)

| | 72 heures (saccade) | Avatar F&A (fluide) | Toy Story 4 (fluide) |
|---|---|---|---|
| Débit vidéo | **20 289 kbps** | 16 207 kbps | 4 609 kbps |
| Résolution | 3840×2160 | 3840×2080 | 3840×1608 |
| Codec | HEVC Main 10 @ L150 | idem | idem |
| HDR / pixfmt | HDR10 / yuv420p10le | idem | idem |
| fps | 24.000 | 24.000 | 23.976 |
| Audio | E-AC-3 5.1 (Atmos) 768k | E-AC-3 5.1 640k | AAC 7.1 |
| Conteneur | MKV (Netflix WEB-DL) | MKV (WEB CA) | MKV (BluRay light) |

### Éliminé (avec la preuve)

- **Réseau / débit** : borne Wi-Fi 300 Mbps symétriques stable, iPhone fluide au même moment sur la même borne ; serveur lit 20 Mbps vers l'extérieur (test Safari à 60 km). Et le symptôme (drops sans pause buffer) n'est pas une signature de famine réseau.
- **Audio E-AC-3** (horloge maîtresse) : Avatar est aussi E-AC-3 5.1 et fluide.
- **Paramètres codec refusés par VideoToolbox** : les trois fichiers sont jumeaux (Main 10, L150, progressif, yuv420p10le).
- **Modules manquants dans le binaire tvOS** : inventaire `vlc_entry__*` fait sur le `.a` — `codec_videotoolbox`, `glinterop_cvpx` (zéro-copie), vouts `caeagl_ios`/`cvpx_gl`/`samplebufferdisplay`, `audiounit_ios` tous présents. Tranches iOS/tvOS équivalentes (delta = chromecast + archive, iOS-only).
- **Serveur** : lecture distante Safari parfaite.

### Théorie de tête (à confirmer, pas encore prouvée)

Une étape **logicielle** dans la chaîne vidéo tvOS — soit le décodage retombé sur `avcodec` au lieu de `videotoolbox`, soit une conversion/upload CPU dans le vout — dont le budget A15 est dépassé par ce fichier précis : premier vrai 4K plein débit du catalogue, ET le plus cher à décoder (grain live-action Netflix vs CGI propre d'Avatar — le coût decode ne suit pas que le débit). L'iPhone encaisse par force brute (A19 Pro), d'autant que son chemin de rendu est différent (voir §7).

**La donnée manquante : la ligne `Modules` des stats sur l'Apple TV.** L'instrumentation est en place (§2) mais n'a jamais tourné sur le device.

## 2. Instrumentation déjà en place (commit `ed0713f`)

libVLC logge en debug la ligne `using <capability> module "<name>"` à chaque sélection de module. `VLCEngineLog` consomme désormais le flux en `.debug`, les parse (`parseModuleSelection`, testé) dans `VLCEngineFacts`, et l'overlay Statistiques du player affiche :

- `Modules : demux mkv · vdec <?> · adec <?> · vout <?> · interop <?> [· vconv <?>]`
- `Demux : N corrupt · M discont` (piste résiduelle : MKV mal muxé par la release)

Chaque sélection est aussi miroir en OSLog : subsystem `com.cinemax`, category `libVLC`, message `libVLC module ▸ …` (visible dans Console.app, device Apple TV).

## 3. Étape 0 — Environnement local (à faire en premier)

Bastien a validé la montée **Xcode 26.2 → 26.5** (cohérent avec la CI, débloque swift-tools 6.3 pour SwiftVLC ≥ 0.4.0).

1. Installer Xcode 26.5 (App Store ou developer.apple.com), puis :
   `sudo xcode-select -s /Applications/Xcode.app && sudo xcodebuild -license accept`
   Installer la plateforme tvOS si demandée (`xcodebuild -downloadPlatform tvOS`).
2. xcodegen **pinné 2.46.0** — jamais brew (RULE CLAUDE.md) :
   ```sh
   curl -fsSL -o /tmp/xcodegen.zip "https://github.com/yonaskolb/XcodeGen/releases/download/2.46.0/xcodegen.zip"
   unzip -q /tmp/xcodegen.zip -d /tmp/xcodegen-dist && sudo cp -R /tmp/xcodegen-dist/xcodegen/bin/xcodegen /usr/local/bin/
   ```
3. Contrôles avant toute modif : builds iOS + tvOS (commandes dans CLAUDE.md §Build — sérialisés, `set -o pipefail`) et la suite de tests (`xcodebuild test -scheme Cinemax …`, suite complète, jamais `-only-testing`).
4. Signing : compte dev habituel, automatic signing ; l'Apple TV et l'iPhone appairés dans Xcode (Devices & Simulators).

## 4. Étape 1 — LA mesure qui manque (avant toute montée de version)

Déployer `CinemaxTV` (branche telle quelle, SwiftVLC 0.3.0) sur l'Apple TV, lancer « 72 heures », laisser 5-10 min dans une scène chargée, puis swipe bas (HUD masqué) → Statistiques. Relever `Modules`, `Images perdues`, `Demux`, `Débit`. Refaire sur Avatar (témoin fluide). Grille :

| Lecture | Verdict |
|---|---|
| `vdec avcodec` | **Décodage logiciel** — théorie confirmée. La montée SwiftVLC 1.0.0 (moteur assert-free) devient le correctif candidat n°1 → étape 2, puis re-mesurer. |
| `vdec videotoolbox` + `vconv`/`interop sw` présents | Décodage matériel mais conversion CPU dans le vout → étape 2 quand même (binaire plus rapide), puis investiguer le vout. |
| `vdec videotoolbox`, chaîne propre, `lost` grimpe | Regarder `late` vs `lost` et comparer à Avatar au même point. |
| `Demux` corrupt/discont non nuls sur 72h seulement | Piste mux de la release → test : remux local `mkvmerge` du fichier et rejouer. |

Comparer la même ligne sur l'iPhone (fluide) est aussi discriminant : même chaîne = budget ; chaîne différente = sélection de modules divergente entre les deux OS.

## 5. Étape 2 — Montée SwiftVLC 0.3.0 → 1.0.0

### Pourquoi (mesuré sur les binaires, pas spéculé)

| | 0.3.0 (mars 2026) | 1.0.0 (juil. 2026) |
|---|---|---|
| libVLC embarqué | 4.0.6 | 4.0.6 (identique) |
| `.a` tvOS | 82,5 Mo | 70,3 Mo |
| Réfs `__assert_rtn` | **860** | **348** (cœur libVLC assert-free depuis v0.9.0 ; reliquat = contribs) |
| min-OS binaire | 26.2 (pinne notre deploymentTarget) | **tvOS 18.0** (SDK 26.5) |

On shippe aujourd'hui un moteur qui évalue des centaines d'assertions dans les chemins chauds demux/decode/vout. Invisible sur A19 Pro, potentiellement la marge manquante sur A15.

### Modifs `project.yml`

- `xcodeVersion: "26.2"` → `"26.5"`.
- `SwiftVLC: exactVersion: 0.3.0` → `1.0.0` + réécrire le commentaire du pin (l'ancienne raison — swift-tools 6.3 — tombe avec Xcode 26.5).
- `deploymentTarget` 26.2 : la contrainte venait du min-OS du binaire 0.3.0 ; le binaire 1.0.0 est min-OS 18.0 → garder 26.2 (choix produit iOS 26+) mais réécrire le commentaire qui l'attribuait à SwiftVLC.
- Le hook PostToolUse relance `xcodegen generate` automatiquement sur édition de `project.yml` (session locale = hook actif). Committer le `project.pbxproj` régénéré (la CI vérifie sa fraîcheur).

### Carte de migration API (vérifiée en diffant les sources v0.3.0 ↔ v1.0.0)

**Cassures confirmées :**
1. `player.audioDelay` / `player.subtitleDelay` deviennent **get-only** ; muter = `try setAudioDelay(_:)` / `try setSubtitleDelay(_:)` (throws). Sites : les pickers de delay dans `VLCStreamPresenter` (~4 + 4 usages).
2. `PiPVideoView.init` gagne `startsAutomaticallyFromInline: Bool = true, managesAudioSession: Bool = true`. Compile sans changement (defaults) **MAIS `managesAudioSession: true` entre en conflit avec notre RULE « `PlaybackAudioSession` est l'unique owner de l'AVAudioSession »** → passer explicitement `managesAudioSession: false` dans `PlayerEngineSurface.swift`, et vérifier au runtime que l'activation reste séquencée avant l'open (RULE `activate()` await).
3. `PiPController` : `isPossible`/`isActive` supprimés (non utilisés chez nous a priori — le presenter ne fait que `toggle()`), nouveau hook `onRestoreUserInterface` — à brancher si le restore PiP régresse.

**Additif (opportunités, pas obligatoire dans ce lot) :**
- `PlayerEvent` : cases identiques à 0.3.0 **plus** `mediaStopping`, `endReached`, `corked`/`uncorked`, `audioDeviceChanged`. `endReached` permettrait de remplacer la désambiguïsation fragile du `.stopped` de fin de média (`isTearingDown` + `lastPlayStart` + near-end guard, documentée dans CLAUDE.md) — à faire dans un lot séparé, pas pendant la montée.
- `Media` : API slaves (pistes externes) — sans usage chez nous.
- `logStream` et `player.statistics` **survivent** → l'instrumentation §2 est compatible telle quelle.

**Bruit à ignorer :** le diff Player.swift montre des dizaines de méthodes « supprimées » (seek, chapters, ABLoop…) — elles sont déplacées vers des extensions/fichiers. Laisser le compilateur guider, ne pas re-plumber.

### Après migration

- Builds iOS + tvOS + suite de tests complète.
- MAJ CLAUDE.md : §Dependencies (pin SwiftVLC, raison), commentaire deploymentTarget, et la note VLCEngineLog si quoi que ce soit a bougé.
- Re-mesurer §4 sur l'Apple TV avec le nouveau moteur → comparer `Images perdues` à build égale par ailleurs.

## 6. Étape 3 — selon le verdict

- **La montée suffit** (saccade disparue) : nettoyer, PR, fin. Garder l'instrumentation Modules (elle est peu coûteuse et précieuse).
- **`vdec avcodec` persiste en 1.0.0** : investiguer pourquoi VideoToolbox ne s'engage pas — expérience contrôlée : option média `:codec=videotoolbox,none` (force la préférence décodeur) sur un build de test, + lecture des logs debug complets. Selon résultat : issue upstream SwiftVLC/libVLC, ou fallback app (voir ci-dessous).
- **Chaîne matérielle mais vout/interop en cause** : piste `glinterop_sw` vs `cvpx` — vérifier si le vout `samplebufferdisplay` (présent dans le binaire) peut être forcé (`:vout=…`) en expérience.
- **Filet de sécurité produit** (si le fix moteur traîne) : fallback lecteur natif AVPlayer automatique sur tvOS pour les sources au-dessus d'un seuil de débit (~15 Mbps) — le serveur remuxe le MKV en HLS (copie vidéo, pas de ré-encodage). Design à valider avec Bastien avant d'implémenter (interaction avec la RULE VLC-par-défaut).

## 7. Contexte technique utile (appris pendant le diagnostic)

- **Les chemins de rendu iOS et tvOS divergent structurellement** dans SwiftVLC : iOS (`PiPVideoView`) = callbacks vmem forçant **BGRA** (conversion logicielle pleine trame par libVLC) → `AVSampleBufferDisplayLayer` avec PTS immédiat — brutal en CPU mais tolérant. tvOS (`VideoView`) = `libvlc_media_player_set_nsobject` → vout natif libVLC (OpenGL ES), images présentées **contre l'horloge** — efficace mais exigeant. Un iPhone fluide ne blanchit donc PAS la chaîne tvOS.
- `VLCInstance.defaultArguments` = purement cosmétique ; la seule option média posée par l'app est `:network-caching=5000` (`makeMedia`). Aucun réglage app ne touche au choix hw/sw.
- Sémantique des compteurs stats (`MediaStatistics`) : `lostPictures` = « decoder too slow » (jetées), `latePictures` = affichées en retard (horloge), `lostAudioBuffers` = sortie audio qui décroche.
- L'Apple TV 2022 décode le HEVC 4K Main10 en **matériel** sans effort (Avatar 16 Mbps le prouve in-app) — « format trop lourd » n'existe qu'en logiciel.

## 8. Journal de branche

- `ed0713f` — instrumentation Modules/Demux (VLCEngineLog `.debug` + `VLCEngineFacts` + HUD + tests + clés fr/en + CLAUDE.md).
- `e5c65d3` — ce document.
- `2b9cdb2` — fix : contrainte trailing manquante sur l'overlay stats (la ligne Modules sortait de l'écran sans wrapper — vu au smoke-test sim iPhone).
- `460c5d8` — **étape 2 faite** (2026-08-04, local, Xcode 26.6/SDK 26.5) : SwiftVLC 1.0.0. Migration réelle plus large que la carte §5 : `rate` get-only (`try setPlaybackRate(PlaybackRate)`, 4 sites dont hold-to-2×) et `seek(to:)` throws (`engineSeek`), en plus des delays et de `managesAudioSession: false`. 402 tests OK. **Validation runtime OK** : « 72 heures » DirectStream sur sim tvOS 26.5, chaîne complète assemblée. Baseline 0.3.0 device signée : `~/projets/perso/jellyfin/_artifacts/CinemaxTV-swiftvlc-0.3.0-baseline.app`.

## 10. ROOT CAUSE PROUVÉE (2026-08-05, mesures sur l'Apple TV physique)

**Le CodecPrivate MKV de « 72 heures » est un hvcC NU de 23 octets (`numOfArrays = 0` — aucun VPS/SPS/PPS, les parameter sets sont in-band).** Chaîne causale, chaque maillon mesuré sur la TV (tvOS 26.5, `VTIsHardwareDecodeSupported(HEVC) = true`) :

1. `CopyDecoderExtradataHEVC` (libVLC decoder.c, rev c833c4be0) passe ce hvcC **verbatim** à `VTDecompressionSessionCreate` → **OSStatus -4 (`unimpErr`)** → `VTSESSION_STATUS_ABORT` → le module videotoolbox abandonne. Preuve : sonde in-app (`VTDecodeProbe`) — la même création avec un hvcC Main10 4K HDR10 **complet** répond `noErr` sur la même TV (toutes variantes : spec dict fidèle, GLES on/off, chroma forcé x420/BGRA) ; avec le hvcC réel de 23 o → `-4` systématique. Ni GLES, ni HDR, ni le spec-dict, ni les asserts (la montée 1.0.0 n'y change rien), ni l'app state (`-19431` = bruit connu).
2. Repli `avcodec` : décodage **logiciel** 4K HEVC Main10 20 Mbps (6 threads) sur l'A15.
3. Le vout ne prend pas l'I0AL : chaîne `I0AL→CVPP` échoue (« Failed to create video converter ») → repli **`I0AL→BGRA` par swscale Bicubic**, une conversion 4K logicielle PAR TRAME en plus du décodage.
4. Budget A15 explosé → `picture is too late to be displayed (missing 47-224 ms)` en boucle = la saccade. L'iPhone 17 Pro encaisse le même chemin logiciel par force brute (A19 Pro).
5. Avatar/Toy Story fluides ⇒ leurs MKV portent vraisemblablement un hvcC complet (VT s'engage). Aussi cohérent : pas de « forcing output chroma » dans les logs (sans SPS le helper ignore la chroma), et le sim répond `-8971` sans hvcC vs `-4` avec hvcC nu.

**Fixes possibles** : (a) **remux serveur** du fichier (mkvmerge reconstruit le CodecPrivate avec les parameter sets → VT s'engage → matériel) — soulagement immédiat, généralisable en inventaire « hvcC nu » dans l'esprit de `scripts/remux-seek-heavy.sh` ; (b) **bug upstream libVLC** : le module videotoolbox devrait late-starter quand l'extradata n'a pas de parameter sets (`LateStartHEVC` ne teste que `i_extra == 0` ; `CopyDecoderExtradataHEVC` devrait préférer l'extradata reconstruite par le helper quand `hxxx_helper_has_config`) — patch ~2 conditions, à reporter chez VideoLAN/SwiftVLC ; (c) fork SwiftVLC patché si l'upstream traîne.

Outils de diagnostic sur la branche (DEBUG-only, à retirer avant merge) : `VTDecodeProbe.swift` (auto-run au launch — sert encore à valider un remux) + miroir stderr complet dans `VLCEngineLog`.

## 9. Acquis simulateur (2026-08-04) — à confronter au device

Chaîne tvOS **simulateur** (26.2 et 26.5, 0.3.0 et 1.0.0 identiques) sur « 72 heures » : `demux mkv · vdec avcodec · adec avcodec · vout samplebufferdisplay · vconv cvpx/swscale/chain`. Deux lignes discriminantes pour l'étape 1 sur la VRAIE TV (toutes deux miroir en OSLog, `log collect` possible) :
- **`libVLC [libvlc] device doesn't support HEVC`** — c'est ELLE qui force `vdec avcodec` sur le sim. Si elle apparaît sur l'Apple TV physique, théorie confirmée d'un coup.
- `vout display = samplebufferdisplay` — le §7 supposait un vout OpenGL sur tvOS ; le sim choisit samplebufferdisplay. À vérifier sur device.
