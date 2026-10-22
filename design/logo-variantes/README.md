# Variantes de couleur du logo

L'icône de l'app, **recolorée sans être redessinée**. Seule la teinte de la méduse change. Les formes, les reflets, le diaphragme, le halo et la lumière sont les pixels d'origine. Le fond et l'alpha restent identiques au pixel près, sauf dans la variante « fond aubergine ».

`design/` n'appartient à aucune cible Xcode, donc ces fichiers ne partent pas dans le bundle. **Une seule variante est livrée comme icône alternative** (depuis le 2026-10-22, lot D, fonction Pro) : **« A + fond aubergine »**, sous le nom `AppIconHalloween`, sur iPhone/iPad et Apple TV — voir « Icônes alternatives livrées » plus bas.

## Coins (appliqué à l'app le 2026-09-28)

Les icônes d'origine avaient leurs coins arrondis peints dans l'image, blancs à l'extérieur (gris clair sur l'icône sombre), avec un liseré le long de la courbe. iOS et tvOS appliquent leur propre masque à une icône **carrée**. `recolor.py` remplace ce blanc et ce liseré par le fond, prolongé en douceur depuis les pixels voisins (le reflet du bord haut s'estompe dans le coin). Hors des quatre coins, aucun pixel ne change : le script le vérifie.

**Logo tvOS des Réglages (`AppLogo.imageset/app_logo_tv.png`), redécoupé le 2026-10-13** : l'ancien détourage gardait autour de la méduse une bande du fond sombre de l'icône (et des taches entre les tentacules), visible sur le fond des Réglages. `recut_tv_logo.py <original> <sortie> <dossier d'aperçus> 90 30` retire tout ce fond : remplissage depuis les bords de l'image sur les pixels proches du fond (le néon l'arrête ; l'objectif est protégé), seuls les pixels collés au néon restent, adoucis et recolorés à la couleur du néon voisin. L'original est gardé dans `originaux/AppLogo.imageset/app_logo_tv.png`. Les déclinaisons de couleur sous `declinaisons/` gardent l'ancien détourage.

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

## Icônes alternatives livrées (lot D, 2026-10-22)

Réglages → Apparence → « Icône de l'app » : **Classique** (l'icône principale, gratuite) et **Halloween** (`AppIconHalloween` = « A + fond aubergine », Pro). Règles : `Shared/DesignSystem/CLAUDE.md` (App Icons).

- **Installation** : `python3 design/logo-variantes/recolor.py --alternates`. Aucun recoloriage : les fichiers de `declinaisons/<variante>/` sont copiés TELS QUELS (table `ALTERNATES`) vers `<nom>.appiconset` (iOS clair + sombre ; la teintée est celle de l'icône principale, en niveaux de gris) et `<nom>.imagestack` (tvOS, face + fond, taille Small). Le script écrit aussi les vignettes du sélecteur (`AppIconPreview` = l'icône principale, `<nom>Preview`) et celles de chaque variante sous `declinaisons/<variante>/AppIconPreview.imageset/`, que `scripts/seasonal-icon.py` emporte avec l'icône principale.
- **tvOS** : il faut une pile d'images de PREMIER niveau au nom de l'icône. Une seconde `.brandassets` n'atteint jamais `CFBundleAlternateIcons` (actool : « No applicable image stack found for alternate app icon name »). L'image Top Shelf ne fait jamais partie d'une icône alternative.
- **Vérifié au simulateur** (clones iOS 27 et tvOS 27, 2026-10-22) : l'icône change bien sur l'écran d'accueil de l'iPhone et dans le dock de l'Apple TV. Les deux systèmes affichent leur propre alerte (« You have changed the icon for "JellyGlass" »). Captures : `_artifacts/lot-d-icone/`, à côté du dépôt.
- **Le mode complet (sans option) refuse de tourner tant que l'icône principale est une déclinaison saisonnière** : il lit les faces tvOS dans `Resources/` et les aurait recolorées une seconde fois (constaté le 2026-10-22 : toutes les faces tvOS de toutes les variantes dérivaient). Lancer `scripts/seasonal-icon.py classique` d'abord.
- **Pour l'icône suivante** : une entrée dans `ALTERNATES`, `--alternates`, le nom dans `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES` des deux cibles de `project.yml`, un choix dans `AppIconCatalogue`, ses libellés fr/en/de.

### Poids (mesuré le 2026-10-22, builds Release simulateur)

| | Sources PNG | `Assets.car` |
|---|---|---|
| iOS — clair / sombre / teintée | 1 092 215 / 1 015 493 / 455 160 o | 1 421 609 / 1 208 460 / 484 106 o |
| iOS — total de l'icône Halloween | 2,56 Mo | **+3 154 000 o** (4 016 216 → 7 170 216) |
| tvOS — face 1x+2x / fond 1x+2x | 235 488 / 2 537 o | 181 649 / 1 259 o, + 301 426 o de rendus de pile (dont flous) |
| tvOS — total de l'icône Halloween | 0,24 Mo | **+561 600 o** (2 467 880 → 3 029 480) |
| Vignettes (×2) | 30–45 Ko chacune | iOS ≈ 0, tvOS 38 Ko chacune |

- **Pourquoi ~1 Mo pour un carré de 1024** : 3,1 Mo de pixels bruts, 79 454 couleurs distinctes, et 79 % des pixels voisins diffèrent de 1 à 8 niveaux (dégradés du halo, grain) : deflate n'y trouve presque pas de répétitions. Le PNG est déjà optimal pour Pillow (`optimize=True` + niveau 9 : 0 octet gagné).
- **actool ne garde pas le PNG** : il décode et range chaque 1024² en ARGB brut compressé lzfse, plus lourd que le PNG (1,42 Mo contre 1,09 Mo pour l'icône claire). Une optimisation SANS perte de la source ne change donc rien au bundle : catalogue identique, mesuré. La teintée n'est pas dédupliquée avec celle de l'icône principale (484 106 o deux fois).
- **Palette de 256 couleurs (avec perte, NON appliquée)** : PNG 1 092 215 → 452 091 o (−59 %) ; dans `Assets.car`, clair + sombre 2,63 → 1,42 Mo, soit −1,2 Mo par icône iOS. Risque d'aplats ou de bandes sur les halos à vérifier à l'œil avant tout usage.
- Ce que paie un utilisateur : l'App Store découpe le catalogue par appareil, mais l'icône 1024 sert à toutes les tailles. Comptez environ 3 Mo par icône alternative iOS et 0,5 Mo sur Apple TV.

## Pour aller plus loin

- D'autres icônes peuvent suivre l'accent choisi, ou une autre saison.
- iOS et tvOS affichent une alerte système à chaque changement d'icône.

Icône de saison : `python3 scripts/seasonal-icon.py halloween` pose la variante Halloween comme icône principale (App Store compris), `python3 scripts/seasonal-icon.py classique` la retire. Chaque bascule part dans une version. La variante `classique` (coins remplis, teinte d'origine) est produite par `recolor.py` pour ce retour.
