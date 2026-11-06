"""Reads the series' original networks and their TMDb logos, through Seerr.

Read-only on both servers. Keys come from the environment, never from a file:
    JF_URL, JF_KEY        Jellyfin server + API key
    SEERR_URL, SEERR_KEY  Seerr (Jellyseerr / Overseerr) + its API key

Merges into networks.json (id, name, logoPath, count) and downloads each logo,
original size, into _originals/ (git-ignored). A network already listed keeps
its entry, so a second library ADDS networks instead of replacing the list.
Then run build_assets.py.
"""
import collections, json, os, urllib.parse, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
JF, JF_KEY = os.environ['JF_URL'].rstrip('/'), os.environ['JF_KEY']
SEERR, SEERR_KEY = os.environ['SEERR_URL'].rstrip('/'), os.environ['SEERR_KEY']


def get_json(url, headers):
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=30) as r:
        return json.loads(r.read())


series = get_json(JF + '/Items?' + urllib.parse.urlencode(
    {'IncludeItemTypes': 'Series', 'Recursive': 'true', 'Fields': 'ProviderIds'}),
    {'Authorization': f'MediaBrowser Token="{JF_KEY}"'})['Items']

path = os.path.join(HERE, 'networks.json')
known = {n['id']: n for n in json.load(open(path))} if os.path.exists(path) else {}
count = collections.Counter()
for s in series:
    tmdb = (s.get('ProviderIds') or {}).get('Tmdb')
    if not tmdb:
        continue
    try:
        tv = get_json(f'{SEERR}/api/v1/tv/{tmdb}', {'X-Api-Key': SEERR_KEY})
    except Exception as e:  # one series Seerr cannot resolve must not stop the run
        print('skip', s['Name'], e)
        continue
    for n in tv.get('networks') or []:
        known.setdefault(n['id'], {'id': n['id'], 'name': n['name'], 'logoPath': n.get('logoPath')})
        count[n['id']] += 1

os.makedirs(os.path.join(HERE, '_originals'), exist_ok=True)
for nid, n in known.items():
    n['count'] = max(n.get('count', 0), count[nid])
    if n.get('logoPath'):
        n['file'] = f'{nid}{os.path.splitext(n["logoPath"])[1]}'
        dest = os.path.join(HERE, '_originals', n['file'])
        if not os.path.exists(dest):
            with urllib.request.urlopen('https://image.tmdb.org/t/p/original' + n['logoPath'], timeout=30) as r:
                open(dest, 'wb').write(r.read())
out = sorted(known.values(), key=lambda n: (-n['count'], n['name']))
json.dump(out, open(path, 'w'), ensure_ascii=False, indent=1)
print('networks', len(out), 'with logo', sum(1 for n in out if n.get('file')))
