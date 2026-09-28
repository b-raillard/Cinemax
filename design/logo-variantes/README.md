# Variantes de couleur du logo

L'icône actuelle de l'app (`Resources/Assets.xcassets/AppIcon.appiconset/app_icon_1024.png`), **recolorée sans être redessinée**. Seule la teinte de la méduse change. Les formes, les reflets, le diaphragme, le halo et la lumière sont les pixels d'origine. Le fond reste identique au pixel près, sauf dans la variante « fond aubergine ».

Rien ici n'est encore branché dans l'app. `design/` n'appartient à aucune cible Xcode, donc ces fichiers ne partent pas dans le bundle.

## Contenu

| Dossier | Quoi |
|---|---|
| `accent/` | Une icône par couleur d'accent du thème : rouge, orange, jaune, vert, cyan, bleu, indigo, violet, rose. La teinte est l'`accentDark` de `AccentOption.swift`. Un léger dégradé sur la même teinte garde la profondeur de l'original. |
| `halloween/` | Les teintes du thème saisonnier « Nuit d'Halloween » : Citrouille `#FF7A1A` et Potion `#A57BFF`. **A** : cloche citrouille, tentacules potion. **B** : l'inverse. **A + fond aubergine** : le fond gris prend les surfaces du thème, de Nuit `#0C0A10` à Tombe `#262033`. |
| `apercu_accents.png`, `apercu_halloween.png` | Planches de comparaison avec l'icône actuelle. |
| `recolor.py` | Régénère tout (Pillow + numpy) : `python3 design/logo-variantes/recolor.py`. |

Le thème « Nuit d'Halloween » vient de la maquette « Cinemax — Logo & Halloween », sur le canevas de design claude.ai. Ses pistes d'icône redessinaient la méduse (citrouille, fantôme, sorcière). Ces variantes-ci gardent le logo tel quel.

## Méthode (pour itérer)

- Le halo d'origine va du vert (≈ 150°, tentacules et diaphragme) au bleu (≈ 200°, cloche). Le script repère chaque pixel sur ce dégradé (`t`, de 0 pour le vert à 1 pour le bleu).
- Un pixel n'est recoloré que s'il est saturé et dans la bande de teinte du halo, avec des bords progressifs pour que le halo se fonde dans le fond.
- Réglages dans `recolor.py` :
  - `ACCENT_SPREAD` : 0 donne une teinte unie, 1 garde tout l'écart de teinte d'origine.
  - les deux teintes Halloween ;
  - la rampe `AUBERGINE`.
- Entre Potion et Citrouille, le dégradé passe par le magenta et le rouge, comme l'original passe par le cyan.

## Pour aller plus loin

- Déclinaisons encore à faire pour une variante retenue :
  - la version sombre (`app_icon_1024_dark.png`) ;
  - les 3 calques de parallaxe tvOS (`App Icon & Top Shelf Image.brandassets`) ;
  - le logo affiché dans l'app (`AppLogo.imageset`, dont `app_logo_tv.png` en 1280 × 768).

  La version teintée d'iOS est en niveaux de gris et n'a pas besoin de variante.
- Icônes alternatives (`CFBundleAlternateIcons` via `ASSETCATALOG_COMPILER_ALTERNATE_APP_ICON_NAMES` dans `project.yml`, puis `UIApplication.setAlternateIconName`) :
  - elles peuvent suivre l'accent choisi, ou s'activer pendant la période du thème Halloween ;
  - iOS affiche une alerte système à chaque changement d'icône ;
  - tvOS le permet aussi, mais chaque icône alternative y est une pile de parallaxe complète à produire.
