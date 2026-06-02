# Cinemax — Checklist soumission App Store Connect

Ordre d'exécution recommandé. **Tout est à faire deux fois** : une fois pour `Cinemax` (iOS) et une fois pour `CinemaxTV` (tvOS). ASC gère les deux apps comme des produits séparés même si tu peux les regrouper en "App Bundle" plus tard.

---

## Phase 0 — Pré-requis (déjà fait)

- [x] Apple Developer Program actif
- [x] Bundle ID enregistré pour iOS et tvOS
- [x] Build TestFlight uploadé et processé pour iOS
- [x] Build TestFlight uploadé et processé pour tvOS
- [x] Privacy manifest (`Resources/PrivacyInfo.xcprivacy`) présent
- [x] `ITSAppUsesNonExemptEncryption=false` dans les deux Info.plist

---

## Phase 1 — Hébergement de la politique de confidentialité

- [ ] Merger la PR #23 sur `main` : https://github.com/b-raillard/Cinemax/pull/23
- [ ] GitHub repo → **Settings → Pages** :
  - Source : `Deploy from a branch`
  - Branch : `main`
  - Folder : `/docs`
  - Save
- [ ] Attendre 1–2 min, vérifier https://b-raillard.github.io/Cinemax/privacy.html dans un navigateur

---

## Phase 2 — Préparer les écrans App Store Connect (iOS)

Va sur https://appstoreconnect.apple.com → My Apps → Cinemax (iOS).

### 2.1 App Information

- [ ] **Name** : `Cinemax`
- [ ] **Subtitle** : `Lecteur Jellyfin pour Apple` (FR) / `Jellyfin player for Apple` (EN)
- [ ] **Primary Category** : Photo & Video
- [ ] **Secondary Category** : Entertainment
- [ ] **Content Rights** : YES (third-party content) — voir `app-store-questionnaires.md` section E
- [ ] **Age Rating** : remplir le questionnaire (section D du même doc) → résultat 17+ attendu

### 2.2 Pricing and Availability

- [ ] **Price** : Free (Tier 0)
- [ ] **Availability** : Edit Countries → décocher tout sauf France, Belgique, Suisse, Luxembourg, Canada
- [ ] **Pre-Orders** : Off

### 2.3 App Privacy

- [ ] **Privacy Policy URL** : `https://b-raillard.github.io/Cinemax/privacy.html`
- [ ] **Data Collection** : "We do not collect data from this app"
- [ ] Submit la section App Privacy (séparée du reste — peut être faite avant le reste)

### 2.4 Version 1.0 — Préparer la fiche store

Tab "Distribution" → iOS App → 1.0 Prepare for Submission :

- [ ] **Promotional Text** (FR + EN) : copier depuis `app-store-metadata.md`
- [ ] **Description** (FR + EN)
- [ ] **Keywords** (FR + EN)
- [ ] **Support URL** : `https://github.com/b-raillard/Cinemax/issues`
- [ ] **Marketing URL** *(optionnel)* : `https://github.com/b-raillard/Cinemax`
- [ ] **Screenshots** : upload des sets iPhone 6.9" + iPad 13" (voir `app-store-screenshots.md`)
- [ ] **Build** : "+" → sélectionner le dernier build TestFlight
- [ ] **What's New in This Version** : copier depuis `app-store-metadata.md`
- [ ] **Copyright** : `2026 Bastien Raillard`
- [ ] **Contact Information** (pour App Review) :
  - First Name / Last Name : `Bastien Raillard`
  - Phone : ton numéro
  - Email : `bastienraillard@gmail.com`
- [ ] **Sign-In Information** : YES → renseigner URL serveur démo + credentials (voir `app-store-questionnaires.md` section F)
- [ ] **Notes for Reviewer** : copier depuis `app-store-metadata.md` section 4
- [ ] **Version Release** :
  - "Automatically release after App Review" (recommandé pour v1.0)
  - OU "Manually release this version" si tu veux contrôler le jour J

### 2.5 Submit

- [ ] Bouton **"Add for Review"** en haut à droite → puis **"Submit to App Review"**
- [ ] Apple répond dans 24–48h en général (peut être plus pour une 1ère soumission)

---

## Phase 3 — Répéter pour tvOS

Reproduire exactement Phase 2 pour l'app `CinemaxTV` dans ASC, avec ces différences :

- **Screenshots** : seulement la taille Apple TV (3840×2160)
- **Sign-In Information** : même serveur démo, mais préciser dans les Notes que la saisie URL se fait via clavier à l'écran tvOS
- **App Privacy** : peut être copiée à l'identique (même comportement)
- **Categories, Description, Keywords** : identiques à iOS

> Astuce : ASC permet de copier les métadonnées d'une plateforme à l'autre via le menu "..." → Copy Localization. Vérifie quand même la limite 30 chars pour le sous-titre.

---

## Phase 4 — Suivi de la review

- État ASC : `Waiting for Review` → `In Review` → `Pending Developer Release` (si manual) ou `Ready for Sale` (si automatic)
- Notifications par email sur `bastienraillard@gmail.com`
- En cas de **rejet** :
  - Lis le message ; corrige ; reply via Resolution Center sans nouvel upload si c'est juste une explication
  - Si correction code nécessaire : bump `CURRENT_PROJECT_VERSION`, archive, upload, sélectionner le nouveau build dans la fiche, re-submit

---

## Phase 5 — Après le go-live

- [ ] Vérifier la disponibilité sur l'App Store dans chaque pays sélectionné (peut prendre 2–24h après "Ready for Sale")
- [ ] Mettre à jour le README GitHub avec un badge "Download on the App Store"
- [ ] Annoncer sur les communautés Jellyfin (Reddit r/jellyfin, Discord, forum) — **après** que ce soit live, pas avant

---

## Annexe — Rejets typiques pour une app type Jellyfin client

| Motif | Prévention |
|---|---|
| **Guideline 5.2.2** — Third-party trademark | Ne pas mentionner "Jellyfin" dans le nom de l'app. ✅ Déjà OK ("Cinemax" seul) |
| **Guideline 4.0** — Design : "lecteur sans contenu" | Apple peut tester sans entrer de serveur → s'assurer que ServerSetupScreen est explicite et fonctionne sans crash |
| **Guideline 1.2** — User-generated content | Tu as déjà répondu YES à "Unrestricted Web Access" → 17+ couvre ce cas |
| **Guideline 5.1.1** — Data collection | Privacy manifest + ASC App Privacy disent "no data" — cohérent ✅ |
| **Reviewer ne peut pas tester** | Fournir un serveur démo fonctionnel + credentials valides au moment de la review |
| **Performance — crashes** | Tester sur device réel iOS 26.2 + tvOS 26.2 avant submission |
