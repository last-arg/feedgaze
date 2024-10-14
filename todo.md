# Initial
- website:
  - cache problems
    - items' relative times won't update
      - root, feed, feeds
    - updating feed fields won't break cache
      - root, feed, feeds
    - when feed is removed
      - root, feeds
  - add last-modified header where possible
    - tag page
      - remove
      - update (name)
      - add
  - add feed: 
    - can add tags
    - handle html feed
  - tags page:
    - edit (rename) tags
    - remove tags
    - better styling
  - make feed items into 2 columns on wider screens?
  - escape stuff:
    This should actually be done for all data that I don't input. Anything can 
    contain malicious scripts in title, description etc.
    - text
    - attributes
    - url: escape url -> escape attribute
  - can trigger feed update?
  - change page title on different pages
  - minify html
  - purge and minify css
  - Session example: https://github.com/nonk123/cheesle/blob/3412acc7d34bebf4882705e8bd480a907c03f7b3/src/session.zig#L54
  - Do I want list item link area to extend beyond text (when text is short one liner)?

- should 'update --force' pass http cache?
- twitch integration
- cli: try https://github.com/n0s4/flags
- can change update interval?
- Be consistent either use 'std.Uri.Component.percent_encoded' or '.raw'.
    '.percent_encoded' probably better option. Currently just get/set whatever
    is there.
- save failed favicon requests
  - don't include them in missing request or all
  - make new flag for failed icons requests '--check-failed-icons'
- add transactions
- validate feed tags where needed
  - Need to figure out rules for valid tags
  - Valid tag symbols?:
    - A-z, 0-9
    - no space
  - length limit?
- third party service: https://openrss.org/
  - could use /favicon.ico for default path. Or even /favicon.{ico,png,jpeg}.
    And mark them in DB somehow. Rest would get full path. NULL for feeds
    that don't have favicon?
- cli: feed update counter
- Logo ideas
  - keywords: feed, gaze, rss, atom, links
  - Something with gaze and atoms?

[ ] Can disable updating for feeds?
[ ] Maybe I should add field 'items' to Feed struct?
  - I am using Feed in sqlite db request, which makes the request fail.
    Have separate type for db results?
[ ] For some feeds disable taking newest items. Just take first items as they
appear in the file. 
  - These usually aggregate links from different sites. The  items are in 
    order they were entered. And date (updated_timestamp) is post date.
  - If there is not feed date, what to use? 
  [ ] If implemented have to change how feed.updated_timestamp is updated. Currently
  will used newest (first) feed item.

# Future (Maybe)
[ ] (Popular) Sites that don't support feeds (twitter, instagram, soundcloud).
  [ ] Let user defined 'feed' area?
[ ] Mark feeds to use OS notification system on new link(s)
[ ] Mark feeds that will send email on new link(s)
[ ] For cli UX implement https://en.wikipedia.org/wiki/Damerau%E2%80%93Levenshtein_distance to print word user might have meant
[ ] UI
  [ ] TUI - NotCurses
    * Example: https://github.com/dundalek/notcurses-zig-example

# Old, done, abandoned
[ ] HTTP ranges: https://developer.mozilla.org/en-US/docs/Web/HTTP/Range_requests
    The RSS url is usually in <head>, but also and be anywhere in the <body>.
    Not sure if it is worth using http ranges.
[ ] UI with [zig-webui](https://github.com/webui-dev/zig-webui)
Tried this and liked it. But I think I can just go with a server. 
[ ] Add http server
  - https://github.com/zigzap/zap
  - https://github.com/cztomsik/tokamak
  - https://github.com/karlseguin/http.zig
[ ] HTML templating
  - https://github.com/nektro/zig-pek
  - https://github.com/jacksonsalopek/ztl
[ ] Github
    - https://vilcins.medium.com/rss-feeds-for-your-github-releases-tags-and-activity-cbda2c51373
[ ] Reddit
    - https://old.reddit.com/r/pathogendavid/comments/tv8m9/pathogendavids_guide_to_rss_and_reddit/
[ ] Url rules to transform them into feed urls
  [ ] On some sites have to figure out where to find the feed (reddit, pinboard)
  [ ] Some sites might have and url to rss feed, but page's HTML doesn't contain
      any rss url. Create somekind of rule?
[ ] Atom parsing:
  [ ] see if I need to handle xhtml encoding for <title>
    https://validator.w3.org/feed/docs/atom.html#text
    <title> can have attribute type which tells how content is encoded.
    Encodings: text (default), html, xhtml
    I think function content_to_str() handles text and html encodings
    in some very general way.
[ ] Reduce how often feed update http request are made
  - increase update interval base on when last update was
    - more than 1 year = several days?
    - more than 1 month = 1 day or more?

feed.updated_timestamp? - is feed element/tag date field or latest (newest) item.updated_timestamp
feed_update.last_update - last time http request was made for feed (200 or 304)
feed_update.update_interval - value from http cache-control or expires. If no value default is used.
item.updated_timestamp? - item's publish date
item.created_timestamp - when item was added
item.item_interval - diff between first and second newest items. Otherwise fallback to default value.

```
with temp_table as (
	select feed.feed_id, coalesce(max(item.updated_timestamp) - 
		(select this.updated_timestamp from item as this where this.feed_id = feed.feed_id order by this.updated_timestamp DESC limit 1, 1), "month"
	) item_interval
	from feed 
	left join item on feed.feed_id = item.feed_id and item.updated_timestamp is not null
	group by item.feed_id
)
update feed_update set item_interval = (
CASE
	when temp_table.item_interval < 86400 then 43200
	when temp_table.item_interval < 172800 then 86400
	when temp_table.item_interval < 604800 then 259200
	when temp_table.item_interval < 2592000 then 432000
	else 864000
end
)
from temp_table where feed_update.feed_id = temp_table.feed_id;
```
[ ] 429 - Rate limit
  - 'retry-after'
    - https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Retry-After
    - date or seconds
      - date format: <day-name>, <day> <month> <year> <hour>:<minute>:<second> GMT
        - date example: Wed, 21 Oct 2015 07:28:00 GMT
      - seconds is just a number
  - x-ratelimit-* info: https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api?apiVersion=2022-11-28#checking-the-status-of-your-rate-limit

[ ] some feed item links just contain url path only
  - get items that start with slash (/): select * from item where link like '/%' order by feed_id
  - if there is only path I should be able to construct full url from feed.feed_url
  - or do I store all feeds with full url?
[ ] website: what to display if items have no date?
  [ ] also feed date
  - frontenddogma.com
  - can use http header last-modified value

+ favicon urls
  + html page: find it there
    + html: https://evilmartians.com/chronicles/how-to-favicon-in-2021-six-files-that-fit-most-needs
      <link rel="icon" href="/favicon.ico" sizes="32x32">
      <link rel="icon" href="/icon.svg" type="image/svg+xml">
      <link rel="apple-touch-icon" href="/apple-touch-icon.png"><!-- 180×180 -->
      <link rel="manifest" href="/manifest.webmanifest">
  + feed page: see if there is element that might contain it
    + atom: <icon>
    + rss: <image>
  + try requesting '/favicon.ico' or some other (popular) paths
    + to check if file exists use HEAD request
      + check https://curl.se/libcurl/c/CURLOPT_NOBODY.html
  + make sure HEAD request return content-type that starts with "image/"
  + when batch --check-missing-icons should I request html page first for
    request check path '/favicon.ico'? Doing path '/favicon.ico' first
  + check why 'https://www.foundmyfitness.com/' doesn't have favicon
    + DB has page_url as 'http://www.foundmyfitness.com/' might be a problem with
      redirect?

