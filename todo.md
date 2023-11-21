# Initial
[ ] Feeds
  [ ] Github
      - https://github.community/t/rss-feeds-for-github-projects/292
      - https://vilcins.medium.com/rss-feeds-for-your-github-releases-tags-and-activity-cbda2c51373
  [ ] Reddit
      - https://old.reddit.com/r/pathogendavid/comments/tv8m9/pathogendavids_guide_to_rss_and_reddit/
  [ ] On some sites have to figure out where to find the feed (reddit, pinboard, youtube)
[ ] UI
  [x] CLI - initial
  [ ] TUI - NotCurses
    * Example: https://github.com/dundalek/notcurses-zig-example
  [x] Web browser (http server)
[ ] Zig
  [ ] XML parsing
    - https://github.com/nektro/zig-xml
    - https://github.com/ianprime0509/zig-xml
    - https://github.com/tadeokondrak/zig-wayland/blob/4a1657a02e8f46776e8c811b73240144ec07e57c/src/xml.zig
  [ ] Redirect from http to https produces 'TlsCertificateNotVerified' error.
      For example requesting 'http://github.com' produces the error. But 
      'https://github.com' works just fine.
  [ ] Some sites might have and url to rss feed, but page's HTML doesn't contain
      any rss url. Create somekind of rule?
  [ ] Change HTML page into feed (for sites that don't have rss feed). Use CSS 
      selector to find page 'titles'? Or something like that.
[ ] HTTP ranges: https://developer.mozilla.org/en-US/docs/Web/HTTP/Range_requests
    The RSS url is usually in <head>, but also and be anywhere in the <body>.
    Not sure if it is worth using http ranges.
 

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
