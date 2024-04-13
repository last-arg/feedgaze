# Initial
[ ] Feeds
  [ ] Github
      - https://github.community/t/rss-feeds-for-github-projects/292
      - https://vilcins.medium.com/rss-feeds-for-your-github-releases-tags-and-activity-cbda2c51373
  [ ] Reddit
      - https://old.reddit.com/r/pathogendavid/comments/tv8m9/pathogendavids_guide_to_rss_and_reddit/
  [ ] Url rules to transform them into feed urls
    [ ] On some sites have to figure out where to find the feed (reddit, pinboard)
    [ ] Some sites might have and url to rss feed, but page's HTML doesn't contain
        any rss url. Create somekind of rule?
  [ ] HTML page into feed
    - Use CSS selector to find:
      - titles
      - links
    - Use page title as feed title
[ ] add transactions
[ ] Can disable updating for feeds?
[ ] Reduce how often feed update http request are made
  - increase update interval base on when last update was
    - more than 1 year = several days?
    - more than 1 month = 1 day or more?
[ ] Decode/encode HTML characters
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
Web page
  [ ] Design
    - I think it would be better to make navigation area into sidebar. Will give
    more vertical space to display more feeds and items. And usually don't 
    want text to go too wide. And tag list can grow big, would be harder to 
    mitigate it when navigation it horizontal area on top.
    - If feed + item area goes to wide have two choices
      - Make feeds into columns. Latest feeds' would go from left to right.
      - Make items into columns. Latest items' would go top to bottom.
  [ ] Session example: https://github.com/nonk123/cheesle/blob/3412acc7d34bebf4882705e8bd480a907c03f7b3/src/session.zig#L54

# Future (Maybe)
[ ] typed SQLite - [Strict tables](https://www.sqlite.org/stricttables.html)
[ ] Image (icon/logo)
  [ ] download or save
  [ ] save: database or file or both
  [ ] feed has no image, try html page
[ ] (Popular) Sites that don't support feeds (twitter, instagram, soundcloud).
  [ ] Let user defined 'feed' area?
[ ] Mark feeds to use OS notification system on new link(s)
[ ] Mark feeds that will send email on new link(s)
[ ] For cli UX implement https://en.wikipedia.org/wiki/Damerau%E2%80%93Levenshtein_distance to print word user might have meant
[ ] HTTP ranges: https://developer.mozilla.org/en-US/docs/Web/HTTP/Range_requests
    The RSS url is usually in <head>, but also and be anywhere in the <body>.
    Not sure if it is worth using http ranges.
[ ] UI
  [ ] TUI - NotCurses
    * Example: https://github.com/dundalek/notcurses-zig-example

# Old 
[ ] UI with [zig-webui](https://github.com/webui-dev/zig-webui)
Tried this and liked it. But I think I can just go with a server. 
[ ] Add http server
  - https://github.com/zigzap/zap
  - https://github.com/cztomsik/tokamak
  - https://github.com/karlseguin/http.zig
[ ] HTML templating
  - https://github.com/nektro/zig-pek
  - https://github.com/jacksonsalopek/ztl

