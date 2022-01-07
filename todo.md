# Initial
[ ] typed SQLite - [Strict tables](https://www.sqlite.org/stricttables.html)
[ ] HTTP(S) request
  [?] HTTP (plain secure)? use https only?
  [?] Replace zig BearSSL implementation - (https://github.com/stef/zphinx-zerver/blob/master/ssl.zig)
[ ] Feeds
  [ ] Github
      - https://github.community/t/rss-feeds-for-github-projects/292
      - https://vilcins.medium.com/rss-feeds-for-your-github-releases-tags-and-activity-cbda2c51373
  [ ] Reddit
      - https://old.reddit.com/r/pathogendavid/comments/tv8m9/pathogendavids_guide_to_rss_and_reddit/
  [?] [Json feed](https://www.jsonfeed.org/)
  [ ] On some sites have to figure out where to find the feed (reddit, pinboard, youtube)
[ ] parse.zig
    [ ] Fix: parsing Feed.link. rel = self/alternative
[ ] UI
  [ ] CLI - initial
  [ ] TUI - NotCurses
  [ ] Web browser (http server) - later
[ ] Zig
  [ ] Https client
    - https://github.com/truemedian/zfetch
    - https://github.com/ducdetronquito/requestz
    - https://github.com/haze/zelda
  [ ] Async
    - https://github.com/kprotty/zap
    - https://github.com/lithdew/pike
[ ] SQLite
  - [Setting suggestions](https://news.ycombinator.com/item?id=26103776)
 
# Future (Maybe)
[ ] Image (icon/logo)
  [ ] download or just save link
  [ ] if save:
    [?] save to database?
    [?] save to file?
  [ ] If image missing from feed try to get site's icon
[ ] (Popular) Sites that don't support feeds (twitter, instagram, soundcloud).
  [ ] Let user defined 'feed' area?
[ ] Mark feeds to use OS notification system on new link(s)
[ ] Mark feeds that will send email on new link(s)

