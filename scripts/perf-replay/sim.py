import os
"""Replays the app's request graphs against the live server.
Network model: URLSession-like pool of 6 keep-alive HTTP/1.1 connections per host;
each request holds its connection for RTT (wire) + real server time."""
import urllib.parse
import sys, asyncio, time, statistics, threading, concurrent.futures, json, gzip
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from jf import get, U, js
RTT = 0.002
POOL = concurrent.futures.ThreadPoolExecutor(6)
LOG = []
def _do(path):
    time.sleep(RTT)
    s, b, dt, enc = get(path)
    assert s in (200, 204), (s, path)
    return json.loads(gzip.decompress(b) if enc == "gzip" else b) if b else None
async def req(path):
    t = time.perf_counter()
    r = await asyncio.get_running_loop().run_in_executor(POOL, _do, path)
    LOG.append(path.split("?")[0]); return r
async def gather(*c): return await asyncio.gather(*c)

IMG = "enableImageTypes=Primary,Backdrop,Thumb&imageTypeLimit=1"
def items(extra, fields="ChildCount", count=False):
    return f"/Items?userId={U}&recursive=true&enableUserData=true&{IMG}&fields={fields}&enableTotalRecordCount={'true' if count else 'false'}&{extra}"

def run(fn, n=9, rtt=0.002, **kw):
    global RTT; RTT = rtt
    asyncio.run(fn(**kw)); asyncio.run(fn(**kw))   # warm
    marks = {}
    for _ in range(n):
        LOG.clear(); m = asyncio.run(fn(**kw))
        for k, v in m.items(): marks.setdefault(k, []).append(v * 1000)
    return {k: statistics.median(v) for k, v in marks.items()}, len(LOG)
