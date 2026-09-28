#!/usr/bin/env python3
"""Pose l'icône d'une saison — ou la classique — comme icône PRINCIPALE de l'app.

    python3 scripts/seasonal-icon.py halloween
    python3 scripts/seasonal-icon.py classique

L'icône principale est celle de l'App Store et de tout le monde : elle change
avec une VERSION, jamais depuis l'app (spec 2026-09-28, §10). Sources :
design/logo-variantes/declinaisons/<variante>/ (produites par recolor.py) ; un
fichier qu'une variante ne change pas vient de la variante « classique ».
L'icône teintée ne change jamais ; app_logo.png reçoit l'icône claire.
"""
import shutil
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "Resources/Assets.xcassets"
DECLINAISONS = ROOT / "design/logo-variantes/declinaisons"
VARIANTS = {
    "halloween": "halloween_cloche-citrouille_tentacules-potion",
    "classique": "classique",
}
TV = "App Icon & Top Shelf Image.brandassets"
FILES = [
    "AppIcon.appiconset/app_icon_1024.png",
    "AppIcon.appiconset/app_icon_1024_dark.png",
    "AppLogo.imageset/app_logo_tv.png",
    f"{TV}/App Icon - Large.imagestack/Front.imagestacklayer/Content.imageset/front_appstore.png",
    f"{TV}/App Icon - Small.imagestack/Front.imagestacklayer/Content.imageset/front_1x.png",
    f"{TV}/App Icon - Small.imagestack/Front.imagestacklayer/Content.imageset/front_2x.png",
    f"{TV}/App Icon - Large.imagestack/Back.imagestacklayer/Content.imageset/back_appstore.png",
    f"{TV}/App Icon - Small.imagestack/Back.imagestacklayer/Content.imageset/back_1x.png",
    f"{TV}/App Icon - Small.imagestack/Back.imagestacklayer/Content.imageset/back_2x.png",
]
LOGO = "AppLogo.imageset/app_logo.png"


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in VARIANTS:
        sys.exit(f"usage: seasonal-icon.py {'|'.join(VARIANTS)}")
    folder = DECLINAISONS / VARIANTS[sys.argv[1]]
    for rel in FILES:
        src = folder / rel
        if not src.exists():
            src = DECLINAISONS / "classique" / rel
        dst = ASSETS / rel
        if not src.exists() or not dst.exists():
            sys.exit(f"{rel}: source or target missing ({src})")
        a, b = Image.open(src), Image.open(dst)
        if (a.size, a.mode) != (b.size, b.mode):
            sys.exit(f"{rel}: {a.size} {a.mode} != {b.size} {b.mode}")
        shutil.copyfile(src, dst)
        print(f"{sys.argv[1]:>10}  {rel}")
    shutil.copyfile(ASSETS / FILES[0], ASSETS / LOGO)
    print(f"{sys.argv[1]:>10}  {LOGO}")


if __name__ == "__main__":
    main()
