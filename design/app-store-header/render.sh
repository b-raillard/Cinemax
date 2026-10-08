#!/bin/zsh
# render.sh <out.png> "<query>"   e.g.  render.sh ~/Desktop/x.png "v=tel&fmt=search&lang=en"
#                                     render.sh ~/Desktop/x.png "fmt=plank&lang=en"  (iPhone Duo plank)
#                                     render.sh ~/Desktop/x.png "fmt=shot&n=2&lang=de&shot=de/02-detail.png"  (iPhone planks 1–6)
# Lays out page.html at half size and captures it at device scale 2, then
# flattens to RGB (App Store Connect refuses an alpha channel). Source images
# (film backdrops, device captures) are read from $ASSETS, which defaults to
# the Desktop working folder: they are not committed.
set -e
here=${0:A:h}
out=${1:A}
query=$2
assets=${ASSETS:-$HOME/Desktop/JellyGlass App Store/En-tete/sources}
page=page.html; scale=2
if [[ $query == *fmt=header* ]]; then size=1920,823; else size=1920,1280; fi
# The iPhone plank (plank.html): a 440 × 956 board at scale 3 → 1320 × 2868.
if [[ $query == *fmt=plank* ]]; then page=plank.html; size=440,956; scale=3; fi
# iPhone planks 1–6 (shots.html, n=1..6): same board, same scale.
if [[ $query == *fmt=shot* ]]; then page=shots.html; size=440,956; scale=3; fi
# iPhone Duo planks (duo.html): a 669 × 951 board at scale 3 → 2007 × 2853, the inner display.
if [[ $query == *fmt=duo* ]]; then page=duo.html; size=669,951; scale=3; fi
# Ecosystem planks (eco.html): f=ios → iPhone board; f=tv → 640 × 360 at scale 6 → 3840 × 2160.
if [[ $query == *fmt=eco* ]]; then page=eco.html; size=440,956; scale=3; fi
if [[ $query == *fmt=eco*f=tv* ]]; then size=640,360; scale=6; fi
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --disable-gpu \
  --hide-scrollbars --force-device-scale-factor=$scale --allow-file-access-from-files \
  --virtual-time-budget=4000 --window-size=$size --screenshot="$out" \
  "file://$here/$page?$query&dir=file://${assets// /%20}" 2>/dev/null
python3 - "$out" <<'EOF'
import sys
from PIL import Image
p = sys.argv[1]
Image.open(p).convert('RGB').save(p)
im = Image.open(p); print(p.split('/')[-1], im.size, im.mode)
EOF
