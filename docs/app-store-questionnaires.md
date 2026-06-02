# Cinemax — App Store Connect questionnaires (réponses prêtes à cocher)

---

## A. App Privacy (Data Types)

Localisation : **App Store Connect → My Apps → Cinemax → App Privacy → Edit**

### Question principale
> *Do you or your third-party partners collect data from this app?*

**Réponse : NO, we do not collect data from this app**

Justification (vérifiable dans le code) :
- Aucun SDK d'analyse (Firebase, Mixpanel, Amplitude, etc.) — `Package.resolved` ne contient que `jellyfin-sdk-swift`, `Nuke`, `SwiftVLC`
- Privacy manifest `Resources/PrivacyInfo.xcprivacy` : `NSPrivacyTracking=false`, `NSPrivacyCollectedDataTypes=[]`
- Le seul `NSPrivacyAccessedAPIType` est `UserDefaults` avec reason `CA92.1` (read/write preferences from your app's container) — utilisation locale uniquement

### Privacy Policy URL
```
https://b-raillard.github.io/Cinemax/privacy.html
```

---

## B. App Privacy Details — Data Linked to User / Data Used to Track

| Section | Réponse |
|---|---|
| Data linked to user | **Aucune** |
| Data not linked to user | **Aucune** |
| Data used to track user | **Aucune** |

→ Coche **"Data Not Collected"** sur la page principale et soumets.

---

## C. Encryption (Export Compliance)

Déjà géré par `ITSAppUsesNonExemptEncryption=false` dans `iOS/Info.plist` + `tvOS/Info.plist`.
ASC ne te demandera donc **plus** le questionnaire export à chaque upload. Si jamais il apparaît :
- *Does your app use encryption?* → **Yes** (HTTPS standard)
- *Does it qualify for exemption?* → **Yes** (uses only standard encryption already exempt under primary category 5A002)

---

## D. Age Rating Questionnaire

Localisation : **ASC → Cinemax → App Information → Age Rating → Edit**

Cinemax est un **lecteur tiers** — le contenu vient du serveur de l'utilisateur. Apple le classe généralement en **12+** pour les "Unrestricted Web Access" / contenu utilisateur incontrôlé.

Réponses recommandées :

| Question | Réponse |
|---|---|
| Cartoon or Fantasy Violence | **None** |
| Realistic Violence | **None** |
| Prolonged Graphic or Sadistic Realistic Violence | **None** |
| Profanity or Crude Humor | **None** |
| Mature/Suggestive Themes | **None** |
| Horror/Fear Themes | **None** |
| Medical/Treatment Information | **None** |
| Alcohol, Tobacco, or Drug Use or References | **None** |
| Sexual Content or Nudity | **None** |
| Graphic Sexual Content and Nudity | **None** |
| Gambling | **None** |
| Contests | **No** |
| **Unrestricted Web Access** | **YES** *(critique — l'utilisateur peut diffuser le contenu de son propre serveur, donc Apple considère cela comme web access non restreint)* |
| Gambling and Contests | **No** |

Résultat attendu : **17+** (à cause de "Unrestricted Web Access").

> Si tu veux viser 12+ au lieu de 17+ : tu peux répondre **No** à Unrestricted Web Access en argumentant que l'app ne fait que se connecter à un serveur Jellyfin (pas du web arbitraire). Risque : si Apple détecte de la diversité de contenu, ils peuvent forcer le 17+. Le 17+ est la réponse honnête et sûre — recommandée.

---

## E. Content Rights

ASC → Cinemax → App Information → Content Rights.

> *Does your app contain, display, or access third-party content?*

**Réponse : YES**

Apple te demandera de confirmer que tu as les droits ou que ton app sert uniquement du contenu fourni par l'utilisateur. Sélectionne la confirmation "Yes, I have all necessary rights or am otherwise authorized..." — c'est vrai puisque Cinemax ne fait que lire le contenu du serveur de l'utilisateur.

---

## F. Sign-In Information

ASC → Cinemax → App Review Information → Sign-in Required = **YES**.

Fournis :
- **URL serveur Jellyfin de démo** : *(à mettre en place — voir notes ci-dessous)*
- **Username** : `demo`
- **Password** : *(à choisir)*

### Préparer le serveur de démo

Options pour un serveur de démo accessible publiquement par Apple :

1. **Démo officielle Jellyfin** : `https://demo.jellyfin.org/stable` (compte `demo` / vide ou voir docs Jellyfin). Vérifier qu'il est en ligne le jour de la soumission.
2. **Ton propre serveur exposé via Cloudflare Tunnel** : gratuit, URL stable type `cinemax-demo.tonsite.com`. Ajoute des médias libres de droits (Blender Open Movies).
3. **Ngrok payant** (URL stable) ou ngrok gratuit (URL temporaire, plus risqué).

Option 1 est la plus simple si elle fonctionne. Tester avant de soumettre.
