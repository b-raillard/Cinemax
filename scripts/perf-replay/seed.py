import os
import json, urllib.request, random
B=f"http://{os.environ.get('JF_HOST', 'localhost')}:{os.environ.get('JF_PORT', '8096')}"; T=open(os.path.join(os.environ.get("BENCH_DIR", "."), "token")).read().strip()
def req(m, p, body=None):
    r=urllib.request.Request(B+p, method=m, data=json.dumps(body).encode() if body is not None else None,
        headers={"X-Emby-Token":T,"Content-Type":"application/json"})
    with urllib.request.urlopen(r) as f: d=f.read(); return json.loads(d) if d else None
U=req("GET","/Users/Me")["Id"]; open(os.path.join(os.environ.get("BENCH_DIR", "."), "userid"), "w").write(U)
movies=req("GET",f"/Items?userId={U}&includeItemTypes=Movie&recursive=true&sortBy=SortName")["Items"]
series=req("GET",f"/Items?userId={U}&includeItemTypes=Series&recursive=true")["Items"]
random.seed(1)
for m in movies[:120]: req("POST",f"/UserPlayedItems/{m['Id']}?userId={U}")
for m in movies[120:135]: req("POST",f"/UserItems/{m['Id']}/UserData?userId={U}",{"PlaybackPositionTicks":10000000,"LastPlayedDate":"2026-10-1%dT10:00:00Z"%random.randint(0,4)})
for m in movies[200:240]+series[:5]: req("POST",f"/UserFavoriteItems/{m['Id']}?userId={U}")
# partially watch 12 series -> next up
for s in series[:12]:
    eps=req("GET",f"/Shows/{s['Id']}/Episodes?userId={U}")["Items"]
    n=random.randint(3,15)
    for e in eps[:n]: req("POST",f"/UserPlayedItems/{e['Id']}?userId={U}")
    req("POST",f"/UserItems/{eps[n]['Id']}/UserData?userId={U}",{"PlaybackPositionTicks":5000000,"LastPlayedDate":"2026-10-14T1%d:00:00Z"%random.randint(0,8)})
for i in range(4):
    ids=",".join(m["Id"] for m in random.sample(movies,25))
    req("POST","/Playlists",{"Name":f"Playlist {i}","Ids":ids.split(","),"UserId":U,"MediaType":"Video"})
print("seeded", U, len(movies), len(series))
