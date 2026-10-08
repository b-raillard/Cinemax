#!/bin/zsh
# render.sh <out.png> "<query>"   e.g.  render.sh ~/Desktop/x.png "v=tel&fmt=search&lang=en"
#                                     render.sh ~/Desktop/x.png "fmt=plank&lang=en"  (iPhone Duo plank)
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
