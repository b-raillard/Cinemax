from sim import *
IMGq = "enableImageTypes=Primary,Backdrop,Thumb"
resume = lambda: req(f"/UserItems/Resume?userId={U}&limit=20&mediaTypes=Video&enableUserData=true&{IMGq}")
newTitles = lambda t="Movie,Series": req(items(f"includeItemTypes={t}&sortBy=DateCreated&sortOrder=Descending&limit=20", fields="Overview,Genres,ChildCount"))
latestEps = lambda: req(f"/Items/Latest?userId={U}&includeItemTypes=Episode&enableImages=true&imageTypeLimit=1&enableUserData=true&limit=6&groupItems=true")
favorites = lambda: req(items("includeItemTypes=Movie,Series&sortBy=DateCreated&sortOrder=Descending&isFavorite=true&limit=20"))
nextUp = lambda: req(f"/Shows/NextUp?userId={U}&limit=20&enableUserData=true")
playlists = lambda: req(f"/Items?userId={U}&recursive=true&sortOrder=Ascending&includeItemTypes=Playlist&sortBy=SortName&fields=CanDelete,ChildCount&enableImages=false&enableUserData=false")

async def phase1(split):
    # split=True is a REJECTED variant (Movie and Series as two queries): faster alone,
    # slower inside phase 1 on the LAN — the server is the bottleneck.
    t = time.perf_counter()
    latest = gather(newTitles("Movie"), newTitles("Series"), latestEps()) if split else gather(newTitles(), latestEps())
    await gather(resume(), latest, favorites(), nextUp(), playlists())
    return {"skeleton_drop": time.perf_counter() - t}

if __name__ == "__main__":
    for rtt in (0.002, 0.060):
        b, nb = run(phase1, n=15, rtt=rtt, split=False); a, na = run(phase1, n=15, rtt=rtt, split=True)
        print(f"RTT {rtt*1000:3.0f}ms Home skeleton->content: {b['skeleton_drop']:6.1f} -> {a['skeleton_drop']:6.1f} ms ({100*(1-a['skeleton_drop']/b['skeleton_drop']):+.0f}%) [{nb}->{na} req]")
