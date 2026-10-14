#!/bin/bash
# Runs inside the jellyfin image: builds a synthetic but realistic library.
set -e
FF=/usr/lib/jellyfin-ffmpeg/ffmpeg
M=/media
mkdir -p $M/art $M/movies $M/shows
# 12 distinct posters (1000x1500) and backdrops (1920x1080) with high-entropy content, like real artwork
for i in $(seq 0 11); do
  $FF -loglevel error -y -f lavfi -i "mandelbrot=s=1000x1500:start_scale=$((i+1)).0:end_pts=1,noise=alls=8:allf=t" -frames:v 1 -q:v 3 $M/art/poster$i.jpg
  $FF -loglevel error -y -f lavfi -i "mandelbrot=s=1920x1080:start_scale=$((i+2)).5,noise=alls=8:allf=t" -frames:v 1 -q:v 3 $M/art/fanart$i.jpg
done
$FF -loglevel error -y -f lavfi -i testsrc=s=320x180:d=2:r=10 -f lavfi -i sine=d=2 -c:v libx264 -preset ultrafast -c:a aac -shortest $M/art/clip.mkv
GENRES=(Action Drame Comédie Thriller Horreur Animation Aventure Romance Documentaire Fantastique)
plot="Un long synopsis réaliste de plusieurs phrases, comme ceux que fournit TMDb. Il décrit l'intrigue, les personnages principaux et le contexte du film, afin que le champ Overview ait une taille comparable à un vrai serveur. Les personnages traversent des épreuves, se perdent puis se retrouvent dans un dernier acte spectaculaire."
actors() { for a in $(seq 1 $1); do echo "  <actor><name>Acteur $(( ($2*7+a) % 900 ))</name><role>Rôle $a</role><type>Actor</type></actor>"; done; }
for n in $(seq 1 ${MOVIES:-800}); do
  y=$((1960 + n % 64)); d="$M/movies/Film $n ($y)"; mkdir -p "$d"
  cp $M/art/clip.mkv "$d/Film $n ($y).mkv"
  cp $M/art/poster$((n%12)).jpg "$d/poster.jpg"; cp $M/art/fanart$((n%12)).jpg "$d/fanart.jpg"
  { echo "<movie><title>Film $n</title><year>$y</year><plot>$plot</plot><rating>$((n%10)).$((n%7))</rating><mpaa>PG-13</mpaa>"
    echo "<genre>${GENRES[$((n%10))]}</genre><genre>${GENRES[$(((n+3)%10))]}</genre><studio>Studio $((n%30))</studio><director>Réal $((n%50))</director>"
    actors 20 $n; echo "</movie>"; } > "$d/movie.nfo"
done
for s in $(seq 1 ${SHOWS:-25}); do
  d="$M/shows/Série $s (20$((10+s%15)))"; mkdir -p "$d"
  cp $M/art/poster$((s%12)).jpg "$d/poster.jpg"; cp $M/art/fanart$((s%12)).jpg "$d/fanart.jpg"
  { echo "<tvshow><title>Série $s</title><plot>$plot</plot><genre>${GENRES[$((s%10))]}</genre>"; actors 15 $s; echo "</tvshow>"; } > "$d/tvshow.nfo"
  for se in 1 2 3; do mkdir -p "$d/Season $se"; for e in $(seq 1 10); do
    f="$d/Season $se/Série $s S0${se}E$(printf %02d $e)"; cp $M/art/clip.mkv "$f.mkv"
    echo "<episodedetails><title>Épisode $e</title><season>$se</season><episode>$e</episode><plot>$plot</plot></episodedetails>" > "$f.nfo"
  done; done
done
echo generated
