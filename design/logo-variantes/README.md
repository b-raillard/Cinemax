# Variantes de couleur du logo

L'icône de l'app, **recolorée sans être redessinée**. Seule la teinte de la méduse change. Les formes, les reflets, le diaphragme, le halo et la lumière sont les pixels d'origine. Le fond et l'alpha restent identiques au pixel près, sauf dans la variante « fond aubergine ».

`design/` n'appartient à aucune cible Xcode, donc ces fichiers ne partent pas dans le bundle. Rien n'est encore branché comme icône alternative.

## Coins (appliqué à l'app le 2026-09-28)

Les icônes d'origine avaient leurs coins arrondis peints dans l'image, blancs à l'extérieur (gris clair sur l'icône sombre), avec un liseré le long de la courbe. iOS et tvOS appliquent leur propre masque à une icône **carrée**. `recolor.py` remplace ce blanc et ce liseré par le fond, prolongé en douceur depuis les pixels voisins (le reflet du bord haut s'estompe dans le coin). Hors des quatre coins, aucun pixel ne change : le script le vérifie.

Les icônes de `Resources/` ont reçu cette version sans coins : `app_icon_1024.png`, `_dark`, `_tinted` (couleurs inchangées) et `AppLogo.imageset/app_logo.png`. Les originaux, coins compris, sont gardés dans `originaux/` et restent la source du script. Les calques tvOS et le logo tvOS n'avaient pas de coins peints.

## Contenu

| Chemin | Quoi |
|---|---|
| `declinaisons/<variante>/` | Pour chaque variante, les fichiers qu'elle change, rangés sous leur chemin dans `Assets.xcassets` : icône iOS claire et sombre, face des deux piles tvOS (Large, Small 1x et 2x), `app_logo_tv.png`. La variante aubergine a aussi les fonds tvOS. |
| `originaux/` | Les 4 icônes à coins peints, telles qu'elles étaient avant le 2026-09-28. |
| `apercu_accents.png`, `apercu_halloween.png` | L'icône iOS claire de chaque variante, sous un masque arrondi. |
| `apercu_declinaisons.png` | Toutes les déclinaisons, une ligne par variante : iOS clair, iOS sombre, tvOS (fond + face), logo tvOS. |
| `recolor.py` | Régénère tout (Pillow + numpy) : `python3 design/logo-variantes/recolor.py`. `--install-corners` réécrit en plus les icônes sans coins dans `Resources/`. |

Les variantes :
- **Accents** : rouge, orange, jaune, vert, cyan, bleu, indigo, violet, rose. La teinte est l'`accentDark` de `AccentOption.swift`. Un léger dégradé sur la même teinte garde la profondeur de l'original.
- **Halloween** : les teintes du thème saisonnier « Nuit d'Halloween », Citrouille `#FF7A1A` et Potion `#A57BFF`. **A** : cloche citrouille, tentacules potion. **B** : l'inverse. **A + fond aubergine** : le fond gris prend les surfaces du thème, de Nuit `#0C0A10` à Tombe `#262033`.

Pas de variante pour :
- l'icône teintée d'iOS : elle est en niveaux de gris ;
- `app_logo.png` : c'est `app_icon_1024.png` au pixel près ;
- les calques Middle de tvOS : ils sont vides ;
- les images Top Shelf : une icône alternative ne les remplace jamais.

Le thème « Nuit d'Halloween » vient de la maquette « Cinemax — Logo & Halloween », sur le canevas de design claude.ai. Ses pistes d'icône redessinaient la méduse (citrouille, fantôme, sorcière). Ces variantes-ci gardent le logo tel quel.

## Méthode (pour itérer)

- Le halo d'origine va du vert (≈ 150°, tentacules et diaphragme) au bleu (≈ 200°, cloche), sur toutes les sources. Le script repère chaque pixel sur ce dégradé (`t`, de 0 pour le vert à 1 pour le bleu).
- Un pixel n'est recoloré que s'il est saturé et dans la bande de teinte du halo, avec des bords progressifs pour que le halo se fonde dans le fond.
- Réglages dans `recolor.py` :
  - `ACCENT_SPREAD` : 0 donne une teinte unie, 1 garde tout l'écart de teinte d'origine ;
  - les deux teintes Halloween ;
  - la rampe `AUBERGINE` ;
  - `CORNER_BOX` et `CORNER_GROW` : la zone de coin traitée et la marge qui emporte le liseré.
- Entre Potion et Citrouille, le dégradé passe par le magenta et le rouge, comme l'original passe par le cyan.

## Pour aller plus loin

Icônes alternatives (`CFBundleAlternateIcons` via `ASSETCATALOG_COMPILER_ALTERNATE_APP_ICON_NAMES` dans `project.yml`, puis `UIApplication.setAlternateIconName`) :
- elles peuvent suivre l'accent choisi, ou s'activer pendant la période du thème Halloween ;
- iOS affiche une alerte système à chaque changement d'icône ;
- sur tvOS, chaque icône alternative est une pile de parallaxe complète (fond + face, déjà produites ici).

Icône de saison : `python3 scripts/seasonal-icon.py halloween` pose la variante Halloween comme icône principale (App Store compris), `python3 scripts/seasonal-icon.py classique` la retire. Chaque bascule part dans une version. La variante `classique` (coins remplis, teinte d'origine) est produite par `recolor.py` pour ce retour.
