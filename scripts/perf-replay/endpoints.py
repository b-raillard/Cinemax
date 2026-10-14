import os
import sys; sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from jf import *
IMG="enableImageTypes=Primary,Backdrop,Thumb"
I=f"/Items?userId={U}&recursive=true&enableUserData=true&{IMG}&imageTypeLimit=1"
movies=js(f"{I}&includeItemTypes=Movie&limit=1&sortBy=SortName")["Items"]
series=js(f"{I}&includeItemTypes=Series&limit=1")["Items"][0]
ep=js(f"/Shows/NextUp?userId={U}&limit=1")["Items"][0]
seasons=js(f"/Shows/{series['Id']}/Seasons?userId={U}")["Items"]
E={
 "home.resume": f"/UserItems/Resume?userId={U}&limit=20&mediaTypes=Video&enableUserData=true&{IMG}",
 "home.newTitles(.detail)": f"{I}&includeItemTypes=Movie,Series&sortBy=DateCreated&sortOrder=Descending&limit=20&fields=Overview,Genres,ChildCount&enableTotalRecordCount=false",
 "home.newTitles(.card)": f"{I}&includeItemTypes=Movie,Series&sortBy=DateCreated&sortOrder=Descending&limit=20&fields=ChildCount&enableTotalRecordCount=false",
 "home.latestEpisodes": f"/Items/Latest?userId={U}&includeItemTypes=Episode&enableImages=true&imageTypeLimit=1&enableUserData=true&limit=6&groupItems=true",
 "home.favorites": f"{I}&includeItemTypes=Movie,Series&sortBy=DateCreated&sortOrder=Descending&isFavorite=true&limit=20&fields=ChildCount&enableTotalRecordCount=false",
 "home.nextUp": f"/Shows/NextUp?userId={U}&limit=20&enableUserData=true",
 "home.playlists": f"/Items?userId={U}&recursive=true&sortOrder=Ascending&includeItemTypes=Playlist&sortBy=SortName&fields=CanDelete,ChildCount&enableImages=false&enableUserData=false",
 "home.genres": f"/Genres?includeItemTypes=Movie,Series&userId={U}&enableImages=false&enableTotalRecordCount=false",
 "home.genreRow": f"{I}&includeItemTypes=Movie,Series&genres=Action&sortBy=Random&limit=10&fields=ChildCount&enableTotalRecordCount=false",
 "detail.getItem(movie)": f"/Items/{movies[0]['Id']}?userId={U}",
 "detail.getItem(series)": f"/Items/{series['Id']}?userId={U}",
 "detail.seasons": f"/Shows/{series['Id']}/Seasons?userId={U}&enableUserData=true",
 "detail.nextUp(series)": f"/Shows/NextUp?userId={U}&limit=1&fields=MediaSources&seriesId={series['Id']}&enableUserData=true",
 "detail.episodes(ov+ms)": f"/Shows/{series['Id']}/Episodes?userId={U}&fields=Overview,MediaSources&seasonId={seasons[0]['Id']}&enableUserData=true",
 "detail.similar": f"/Items/{movies[0]['Id']}/Similar?userId={U}&limit=12",
 "lib.hero(count on)": f"{I}&includeItemTypes=Movie&parentId=&sortBy=DateCreated&sortOrder=Descending&limit=1&fields=Overview,Genres,ChildCount",
 "lib.page40(count on)": f"{I}&includeItemTypes=Movie&sortBy=SortName&sortOrder=Ascending&limit=40&startIndex=400&fields=ChildCount&enableTotalRecordCount=true",
 "lib.page40(count off)": f"{I}&includeItemTypes=Movie&sortBy=SortName&sortOrder=Ascending&limit=40&startIndex=400&fields=ChildCount&enableTotalRecordCount=false",
 "search.term": f"/Items?userId={U}&limit=30&recursive=true&searchTerm=film%201&includeItemTypes=Movie,Series,Episode&enableTotalRecordCount=false&enableImageTypes=Primary&imageTypeLimit=1",
}
if __name__=="__main__":
    for k,p in E.items():
        ms,size=bench(p)
        print(f"{k:28s} {ms:7.1f} ms  {size/1024:7.1f} KB(gz)")
