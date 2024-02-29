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
    [ ] Use CSS selector to find:
      - titles
      - links
    [ ] Use page title as feed title
[ ] Decode/encode HTML characters
[ ] Add http server
  - https://github.com/zigzap/zap
  - https://github.com/cztomsik/tokamak
[ ] UI
  [ ] Explore https://github.com/webui-dev/zig-webui
[ ] HTML templating
  - https://github.com/nektro/zig-pek
  - https://github.com/jacksonsalopek/ztl

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
