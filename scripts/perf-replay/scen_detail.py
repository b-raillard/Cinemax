from sim import *
series_id = js(f"/Items?userId={U}&recursive=true&includeItemTypes=Series&limit=1&startIndex=3")["Items"][0]["Id"]
ep_id = js(f"/Shows/NextUp?userId={U}&limit=1&seriesId={series_id}")["Items"][0]["Id"]
movie_id = js(f"/Items?userId={U}&recursive=true&includeItemTypes=Movie&limit=1&startIndex=50")["Items"][0]["Id"]
getItem = lambda i: req(f"/Items/{i}?userId={U}")
seasons = lambda s: req(f"/Shows/{s}/Seasons?userId={U}&enableUserData=true")
nextUp = lambda s: req(f"/Shows/NextUp?userId={U}&limit=1&fields=MediaSources&seriesId={s}&enableUserData=true")
episodes = lambda s, se: req(f"/Shows/{s}/Episodes?userId={U}&fields=Overview,MediaSources&seasonId={se}&enableUserData=true")

async def series_detail_before(sid):
    ss, nu = await gather(seasons(sid), nextUp(sid))
    first = ss["Items"][0]["Id"]; nus = (nu["Items"] or [{}])[0].get("SeasonId")
    if nus and nus != first: await gather(episodes(sid, first), episodes(sid, nus))
    else: await episodes(sid, first)

async def series_detail_after(sid):
    inflight = {}   # models APICache.coalesce on the episodes- key
    def eps(se):
        if se not in inflight: inflight[se] = asyncio.ensure_future(episodes(sid, se))
        return inflight[se]
    async def chainA():
        ss = await seasons(sid); return await eps(ss["Items"][0]["Id"])
    async def chainB():
        nu = await nextUp(sid); nus = (nu["Items"] or [{}])[0].get("SeasonId")
        if nus: await eps(nus)
    await gather(chainA(), chainB())

async def before(kind):
    t = time.perf_counter()
    it = await getItem(ep_id if kind == "episode" else series_id if kind == "series" else movie_id)
    if kind == "episode":
        await getItem(it["SeriesId"]); await series_detail_before(it["SeriesId"])
    elif kind == "series":
        await series_detail_before(series_id)
    return {"paint": time.perf_counter() - t}

async def after(kind):
    # Variant with independent season/next-up chains + coalesced episodes: ~3 % more, not shipped.
    t = time.perf_counter()
    if kind == "series":
        await gather(getItem(series_id), series_detail_after(series_id))
    elif kind == "episode":
        it = await getItem(ep_id)
        await gather(getItem(it["SeriesId"]), series_detail_after(it["SeriesId"]))
    else:
        await getItem(movie_id)
    return {"paint": time.perf_counter() - t}

async def after_simple(kind):
    # SHIPPED (MediaDetailViewModel.load).
    # getItem runs alongside the UNCHANGED loadSeriesDetail (seasons ∥ nextUp → episodes)
    t = time.perf_counter()
    if kind == "series":
        await gather(getItem(series_id), series_detail_before(series_id))
    elif kind == "episode":
        it = await getItem(ep_id)
        await gather(getItem(it["SeriesId"]), series_detail_before(it["SeriesId"]))
    else:
        await getItem(movie_id)
    return {"paint": time.perf_counter() - t}


if __name__ == "__main__":
    for rtt in (0.002, 0.060):
        for kind in ("movie", "series", "episode"):
            b, nb = run(before, rtt=rtt, kind=kind); a, na = run(after_simple, rtt=rtt, kind=kind)
            print(f"RTT {rtt*1000:3.0f}ms  fiche {kind:8s} before {b['paint']:6.1f} ms  after {a['paint']:6.1f} ms  ({nb}->{na} req)  {100*(1-a['paint']/b['paint']):+.0f}%")
