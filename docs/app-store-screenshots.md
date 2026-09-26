# JellyGlass — Guide de captures d'écran App Store

Apple exige **au minimum 1 capture** par taille obligatoire. Recommandé : **3 à 5 captures par taille** pour maximiser la conversion.

---

## 1. Tailles obligatoires (App Store Connect 2026)

Pour JellyGlass tu as besoin de **3 tailles** :

| Plateforme | Appareil cible | Résolution exacte | Sert aussi pour |
|---|---|---|---|
| iPhone | iPhone 17 Pro Max (6.9") | **1320 × 2868 px** (portrait) | tous les iPhones 6.5"+ |
| iPad | iPad Pro 13" (M5) | **2752 × 2064 px** (paysage ; 2064 × 2752 en portrait accepté aussi) | tous les iPads |
| tvOS | Apple TV | **3840 × 2160 px** (paysage 4K) | toutes les Apple TV |

Apple "remplit en cascade" automatiquement : si tu fournis seulement la plus grande taille iPhone, elle est utilisée pour tous les iPhones.

---

## 2. La série livrée (2026-09-26)

Compte `reviewer` sur la bibliothèque démo (Blender Open Movies uniquement), heure 9:41, gabarit du canvas de refonte
(fond noir + halo accent, sur-titre, titre sur 2 lignes, appareil incliné). Exportée par Chrome headless à
l'échelle exacte des planches (iPhone ×3, iPad ×4, Apple TV ×6), en RGB — App Store Connect refuse le canal alpha.

| Appareil | Ordre |
|---|---|
| iPhone | Accueil · Fiche (Sintel, ligne Version) · Médiathèque (grille) · Lecteur (chapitres) · Recherche « an » · Widgets |
| iPad (paysage) | Fiche en deux colonnes (Caminandes) · Accueil (barre latérale) · Médiathèque (onglets en haut, 13 films) |
| Apple TV | Accueil · Médiathèque · Lecteur · Contrôle parental (pavé du code) |

« Regarder ensemble » n'y figure pas : une vraie capture exige deux comptes dans la même séance, et une
reconstitution dessinée au milieu de vraies captures détonne.

**Pièges rencontrés — à revérifier avant chaque nouvelle série :**

- **Les widgets suivent la langue de l'APPAREIL**, pas celle de l'app : sur un simulateur en anglais ils
  affichent « NEXT UP » / « See all ». Passer le simulateur en français (`defaults write -g AppleLanguages`
  puis redémarrage) avant de capturer.
- **Une limite d'âge active masque des titres** (`privacy.maxContentAge`) : 12 films au lieu de 13.
- **La disposition « Grille » de la médiathèque** (`library.tvBrowseLayout = grid`) donne l'écran « toute la
  collection » ; la disposition par défaut (héros + rangées de genres) montre peu d'affiches.
- **Le lecteur** : couper les sous-titres (ils passent sur le curseur en portrait) et les statistiques de
  débogage ; le HUD se masque seul, capturer juste après l'avoir fait apparaître.
- **La fiche iPad en paysage coupait son titre** jusqu'au correctif du 2026-09-25 (voir la RULE « full-bleed
  hero » dans `Shared/DesignSystem/CLAUDE.md`) : une série prise sur un binaire antérieur est à refaire.

---

## 3. Méthode A — Simulator + Cmd+S (rapide, recommandée)

```bash
# Boot le simulateur ciblé
xcrun simctl boot "iPhone 17 Pro Max"
open -a Simulator

# Lance l'app
xcodebuild build -project Cinemax.xcodeproj -scheme Cinemax \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max'

# Puis dans l'app, Cmd+S enregistre une capture dans ~/Desktop
# Résolution = exactement celle exigée par Apple
```

Idem pour `iPad Pro 13-inch (M4)` et `Apple TV 4K (3rd generation)`.

---

## 4. Méthode B — `xcrun simctl io` (scriptable, idéal pour la batch)

```bash
# Capture l'écran courant du Simulator au format PNG
xcrun simctl io booted screenshot ~/Desktop/cinemax-iphone-01-home.png

# Variante avec affichage forcé en clair pour la version "dark/light"
xcrun simctl ui booted appearance light   # ou dark
xcrun simctl io booted screenshot ~/Desktop/cinemax-iphone-02-detail.png
```

---

## 5. Méthode C — Captures sur appareil physique (Apple TV indispensable)

Apple TV Simulator ne permet pas certaines actions Siri Remote complexes (touchpad scrub variable, etc.). Pour des screenshots tvOS de qualité :

1. Apple TV physique + Xcode connecté via réseau (Window → Devices and Simulators → Network)
2. Xcode → menu Window → Devices → sélectionner Apple TV → bouton **"Take Screenshot"** (1920×1080 ou 3840×2160 selon le modèle)

**Astuce** : si tu n'as pas d'Apple TV physique, le Simulator Apple TV 4K génère du 3840×2160 valable pour ASC.

---

## 6. Localisation des screenshots

ASC accepte un set distinct de screenshots **par langue**. Si tu as le temps :
- Fournir un set FR + un set EN, capturés avec `LocalizationManager` switché manuellement (Settings → Langue).
- Sinon, un seul set en FR suffit (langue par défaut), il sera utilisé pour l'EN aussi.

---

## 7. Checklist avant upload sur ASC

- [ ] Pas d'éléments "personnels" visibles (vraie bibliothèque privée → utiliser des médias libres de droits comme Blender Open Movies)
- [ ] Pas de timestamp / heure système distractive (régler l'heure du Simulator avec `xcrun simctl status_bar booted override --time "9:41"` — convention Apple)
- [ ] Pas d'indicateur batterie "low"
- [ ] **Les captures « marketing » encadrées et légendées sont AUTORISÉES** — Apple ne les rejette pas, et la
      quasi-totalité des apps du top en livrent. La consigne inverse qui figurait ici était fausse.
      Le gabarit retenu (fond noir + halo accent, sur-titre, titre 2 lignes, appareil incliné) vit sur le
      canvas de refonte ; seul le PNG de l'écran change d'une version à l'autre.
- [ ] Vérifier que la résolution exacte est respectée (Apple rejette le upload sinon)

```bash
# Régler la status bar iOS comme dans les screenshots Apple officiels
xcrun simctl status_bar booted override \
  --time "9:41" \
  --dataNetwork wifi \
  --wifiBars 3 \
  --cellularMode notSupported \
  --batteryState charged \
  --batteryLevel 100
```

---

## 8. Captures App Preview (vidéo) — optionnel

ASC accepte jusqu'à **3 vidéos de prévisualisation** (15-30s) par taille. Si tu veux te démarquer :
- Enregistre via `xcrun simctl io booted recordVideo ~/Desktop/cinemax-preview.mp4`
- Convertir au format `.mov` H.264, 1080p, 30fps via ffmpeg si Apple rejette

Optionnel pour la v1.0 — peut être ajouté plus tard sans nouvelle review.
