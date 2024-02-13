# Initial
[ ] Feeds
  [ ] Github
      - https://github.community/t/rss-feeds-for-github-projects/292
      - https://vilcins.medium.com/rss-feeds-for-your-github-releases-tags-and-activity-cbda2c51373
  [ ] Reddit
      - https://old.reddit.com/r/pathogendavid/comments/tv8m9/pathogendavids_guide_to_rss_and_reddit/
  [ ] Create rules for some urls
    [ ] On some sites have to figure out where to find the feed (reddit, pinboard, youtube)
    [ ] Some sites might have and url to rss feed, but page's HTML doesn't contain
        any rss url. Create somekind of rule?
  [ ] Turn HTML page into feed (for sites that don't have rss feed). Use CSS 
      selector to find page 'titles'? Or something like that.
  [ ] Feed ordering
      [ ] Get feeds based on newest first. This is not case for all feeds.
      For example 'https://ishadeed.com/feed.xml', no idea how it is ordered.
      [?] Disable ordering based on newest for some feeds?
      [ ] Fill max amount items up. In case of new item compare oldest date
      with new item's and if necessary swap. After all items have been processed
      sort items in list. If no dates don't swap, take top most items. 
      If there is a mix of dates and not dates: 
      1) swap last null date with date one
      2) When sorting put null dates to end? Or keep them was the were found and
      sort only dates?
[ ] DB: consolidate cache_control_max_age and expires_utc. Also update_interval?
  [ ] HTTP: Convert expires into seconds
  Final number has to be bigger than 0.
  How to pick number:
  1) smaller or larger? 
  2) max_age or expires?
[ ] Decode/encode HTML characters
[ ] Add http server
  - https://github.com/zigzap/zap
  - https://github.com/cztomsik/tokamak


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
