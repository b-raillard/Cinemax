# Logos des chaînes (fiche, à côté de la note)

Les logos monochromes de `Resources/Assets.xcassets/Networks/` et le catalogue
`Shared/DesignSystem/NetworkLogoCatalogue.swift` sont **générés** ici. Ne jamais
les modifier à la main.

Source : le logo TMDb de chaque chaîne d'origine, lu via Seerr (Jellyseerr /
Overseerr), qui renvoie les chaînes d'une série avec leur `logoPath`. Les images
viennent du CDN public `image.tmdb.org`.

## Ajouter des chaînes (une autre bibliothèque, une nouvelle série)

```bash
JF_URL=http://serveur:8096 JF_KEY=… SEERR_URL=http://serveur:5055 SEERR_KEY=… \
  python3 design/network-logos/fetch_networks.py
python3 design/network-logos/build_assets.py
```

`fetch_networks.py` AJOUTE à `networks.json` (il ne retire rien) et télécharge
les originaux dans `_originals/` (ignoré par git). Les clés ne passent que par
l'environnement : jamais dans un fichier.

`build_assets.py` régénère toutes les images et le catalogue, puis écrit
`apercu.png` : chaque logo dans sa pastille, sur fond sombre et sur fond clair.
**Regarde-le.** Un logo dessiné sur un fond plein devient un rectangle uni, et
un logo dont le détail est blanc à l'intérieur d'une forme colorée (ABC, RTL+,
TF1) devient une forme pleine. Corrige-les dans `mask_overrides.json`, par
identifiant TMDb de la chaîne :

| Mode | Quand |
|---|---|
| `alpha` (défaut) | logo détouré : sa propre transparence |
| `knockout` (défaut si tout le bord est opaque) | logo sur un fond plein : distance à la couleur du fond |
| `nowhite` | détail blanc dans une forme colorée : le blanc devient un trou |

Deux logos restent imparfaits (Fox Kids, SAGA TV, une série chacun).

Les images font 128 px de haut (1 024 px de large au plus) : nettes sur
Apple TV comme sur iPhone, sans pixellisation.
