import os
import sys; sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sim, scen_home, json, time, statistics, asyncio, concurrent.futures, threading
from jf import js, _local
# Cold launch: every pooled connection is new -> pays TCP (1 RTT) + TLS 1.3 (1 RTT) once.
fresh = set()
orig_do = sim._do
def cold_do(path):
    tid = threading.get_ident()
    if tid not in fresh:
        fresh.add(tid); _local.c = None; time.sleep(2 * sim.RTT)
    return orig_do(path)
def run_cold(rtt, n=11):
    sim.RTT = rtt; out = []
    for _ in range(n + 1):
        fresh.clear(); sim.POOL = concurrent.futures.ThreadPoolExecutor(6); sim._do = cold_do
        out.append(asyncio.run(scen_home.phase1(split=False))["skeleton_drop"] * 1000)
    sim._do = orig_do
    return statistics.median(out[1:])
for rtt in (0.002, 0.060):
    print(f"RTT {rtt*1000:.0f} ms  cold-launch Home skeleton -> content (network): {run_cold(rtt):6.1f} ms")
U = open(os.path.join(os.environ.get("BENCH_DIR", "."), "userid")).read().strip()
I = "enableUserData=true&enableImageTypes=Primary,Backdrop,Thumb&imageTypeLimit=1"
parts = {
 "resume": js(f"/UserItems/Resume?userId={U}&limit=20&mediaTypes=Video&{I}")["Items"],
 "latest": js(f"/Items?userId={U}&recursive=true&includeItemTypes=Movie,Series&sortBy=DateCreated&sortOrder=Descending&limit=20&fields=Overview,Genres,ChildCount&{I}")["Items"],
 "favorites": js(f"/Items?userId={U}&recursive=true&includeItemTypes=Movie,Series&isFavorite=true&limit=20&fields=ChildCount&{I}")["Items"],
 "nextUp": js(f"/Shows/NextUp?userId={U}&limit=20&enableUserData=true")["Items"],
 "playlists": js(f"/Items?userId={U}&recursive=true&includeItemTypes=Playlist&fields=CanDelete,ChildCount&enableImages=false")["Items"],
}
blob = json.dumps(parts).encode()
print("snapshot payload:", sum(len(v) for v in parts.values()), "items,", round(len(blob)/1024,1), "KB JSON")
t=time.perf_counter()
for _ in range(50): json.loads(blob)
print("python json.loads of it: %.2f ms" % ((time.perf_counter()-t)/50*1000))
