from sim import *
films = [v for v in js(f"/UserViews?userId={U}")["Items"] if v["Name"] == "Films"][0]["Id"]
P = f"parentId={films}&includeItemTypes=Movie"
genres = lambda: req(f"/Genres?parentId={films}&includeItemTypes=Movie&userId={U}&enableImages=false&enableTotalRecordCount=false")
hero = lambda: req(items(f"{P}&sortBy=DateCreated&sortOrder=Descending&limit=1", fields="Overview,Genres,ChildCount", count=True))
row = lambda g: req(items(f"{P}&sortBy=DateCreated&sortOrder=Descending&genres={urllib.parse.quote(g)}&limit=12"))

async def open_before():
    t = time.perf_counter()
    gs, _ = await gather(genres(), hero()); paint = time.perf_counter() - t
    names = [g["Name"] for g in gs["Items"]][:8]
    for i in range(0, len(names), 6): await gather(*[row(g) for g in names[i:i+6]])
    return {"paint": paint, "rows": time.perf_counter() - t}

async def open_after():
    # SHIPPED (MediaLibraryViewModel.performLoad).
    t = time.perf_counter(); out = {}
    async def h(): await hero(); out["paint"] = time.perf_counter() - t
    async def rows():
        gs = await genres(); names = [g["Name"] for g in gs["Items"]][:8]
        await gather(*[row(g) for g in names])          # pool still caps at 6 in flight
    await gather(h(), rows()); out["rows"] = time.perf_counter() - t
    return out

page = lambda start, count: req(items(f"{P}&sortBy=DateCreated&sortOrder=Descending&limit=40&startIndex={start}", count=count))
async def pages(first_only):
    t = time.perf_counter(); lat = []
    for start in range(0, 800, 40):
        s = time.perf_counter(); await page(start, (start == 0) or not first_only); lat.append(time.perf_counter() - s)
    return {"page_mean_ex_first": statistics.mean(lat[1:])}

async def open_after2():
    # Rejected variant: rows after the paint without waves — rows barely faster.
    t = time.perf_counter()
    gs, _ = await gather(genres(), hero()); paint = time.perf_counter() - t
    names = [g["Name"] for g in gs["Items"]][:8]
    await gather(*[row(g) for g in names])
    return {"paint": paint, "rows": time.perf_counter() - t}


if __name__ == "__main__":
    for rtt in (0.002, 0.060):
        b, nb = run(open_before, rtt=rtt); a, na = run(open_after, rtt=rtt)
        print(f"RTT {rtt*1000:3.0f}ms library open: paint {b['paint']:6.1f} -> {a['paint']:6.1f} ms | all genre rows {b['rows']:6.1f} -> {a['rows']:6.1f} ms ({100*(1-a['rows']/b['rows']):+.0f}%)  [{nb}->{na} req]")
        b, _ = run(pages, n=3, rtt=rtt, first_only=False); a, _ = run(pages, n=3, rtt=rtt, first_only=True)
        pb, pa = b['page_mean_ex_first'], a['page_mean_ex_first']
        print(f"RTT {rtt*1000:3.0f}ms grid page fetch (pages 2-20): count every page {pb:6.1f} ms -> count first page only {pa:6.1f} ms ({100*(1-pa/pb):+.0f}%)")
        # Scroll model: iPhone grid, 3 columns, user flick-scrolling at 8 rows/s.
        # Trigger at last card => user is already at the end: stall = page latency.
        # Trigger 20 cards early (~7 rows ≈ 0.83 s of scroll lead) => stall = max(0, latency - lead).
        lead = (20/3)/8*1000
        for name, lat in (("last-card trigger, count on", pb), ("20-card lookahead, count on", pb), ("20-card lookahead, count 1st page", pa)):
            stall = lat if name.startswith("last") else max(0, lat - lead)
            print(f"      stall per page boundary [{name}]: {stall:6.1f} ms  -> x19 boundaries over 800 films = {19*stall/1000:5.2f} s")
