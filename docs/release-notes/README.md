# Notes de version (App Store « What's New »)

Un dossier par version publiée, avec deux fichiers :

- `ios.md` : app iOS / iPadOS (`com.cinemax.ios`)
- `tvos.md` : app Apple TV (`com.cinemax.tvos`)

Chaque fichier contient un bloc par langue (français, anglais, allemand depuis la 2.3.1), à copier tel quel dans App Store Connect › la version › « Notes de version ».

## Règles de rédaction

- **4000 caractères max** par bloc.
- **Deux textes distincts** : le contrôle « Reprendre la lecture », les widgets, l'export de diagnostics et l'administration n'existent que sur iOS ; sur Apple TV on « sélectionne », on ne « touche » pas.
- **Siri / Raccourcis** reste volontairement passé sous silence (pas assez abouti pour être annoncé).
- Forme : une ligne d'accroche `JellyGlass <version> : …`, des puces `•`, puis la ligne de remerciement avec le lien des issues.
- **Les petits correctifs sont regroupés en une ligne générique**, jamais énumérés. Seul ce que l'utilisateur remarque est décrit, avec ses mots à lui, sans terme interne.
- L'allemand tutoie (« du »). Les libellés cités reprennent exactement ceux de l'app (`Resources/<langue>.lproj/Localizable.strings`).
- Une version préparée mais jamais envoyée (ex. 2.3.2) n'a pas de dossier : son contenu passe dans la suivante.

L'annonce dans l'app (« Quoi de neuf ») est indépendante : `Shared/Update/WhatsNewCatalogue.swift`, voir `Shared/Update/CLAUDE.md`.
