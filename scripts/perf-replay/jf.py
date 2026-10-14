import http.client, time, json, statistics, threading, gzip
import os
_D=os.environ.get("BENCH_DIR", ".")
HOST=os.environ.get("JF_HOST", "localhost"); PORT=int(os.environ.get("JF_PORT", "8096"))
T=open(os.path.join(_D, "token")).read().strip(); U=open(os.path.join(_D, "userid")).read().strip()
_local=threading.local()
def conn():
    c=getattr(_local,"c",None)
    if c is None: c=_local.c=http.client.HTTPConnection(HOST,PORT,timeout=60)
    return c
def get(path, hdr=None):
    h={"X-Emby-Token":T,"Accept-Encoding":"gzip, deflate"}; h.update(hdr or {})
    for attempt in (0,1):
        try:
            c=conn(); t=time.perf_counter(); c.request("GET",path,headers=h); r=c.getresponse(); body=r.read(); dt=time.perf_counter()-t
            return r.status, body, dt, r.getheader("Content-Encoding")
        except (http.client.HTTPException, ConnectionError):
            _local.c=None
    raise RuntimeError(path)
def js(path):
    s,b,_,enc=get(path); return json.loads(gzip.decompress(b) if enc=="gzip" else b)
def bench(path, n=15, hdr=None):
    get(path,hdr); get(path,hdr)
    ts=[]; size=0
    for _ in range(n):
        s,b,dt,enc=get(path,hdr); ts.append(dt*1000); size=len(b)
    assert s==200,(s,path,b[:200])
    return statistics.median(ts), size
