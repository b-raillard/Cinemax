# Cinemax — Guide de captures d'écran App Store

Apple exige **au minimum 1 capture** par taille obligatoire. Recommandé : **3 à 5 captures par taille** pour maximiser la conversion.

---

## 1. Tailles obligatoires (App Store Connect 2026)

Pour Cinemax tu as besoin de **3 tailles** :

| Plateforme | Appareil cible | Résolution exacte (portrait) | Sert aussi pour |
|---|---|---|---|
| iPhone | iPhone 17 Pro Max (6.9") | **1320 × 2868 px** | tous les iPhones 6.5"+ |
| iPad | iPad Pro 13" (M4) | **2064 × 2752 px** | tous les iPads |
| tvOS | Apple TV | **3840 × 2160 px** (paysage 4K) | toutes les Apple TV |

Apple "remplit en cascade" automatiquement : si tu fournis seulement la plus grande taille iPhone, elle est utilisée pour tous les iPhones.

---

## 2. Écrans à capturer (5 par appareil, conseillé)

Choix éditorial — ce qui met le mieux Cinemax en valeur :

1. **Home Screen** avec un hero plein écran (un film bien rendu, backdrop riche)
2. **MediaDetailScreen** d'un film (badges qualité visibles : 4K, Dolby Vision, Atmos)
3. **VideoPlayer en lecture** avec HUD visible (chapitres, scrub bar)
4. **Library** en mode grid avec un filtre actif (chips colorés)
5. **Settings → Appearance** avec accent rainbow ou couleur originale

Pour Apple TV : remplacer #5 par un écran de **lecture tvOS** avec chapter strip visible.

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
- [ ] Pas de bordures / cadres ajoutés (Apple les rejette)
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
