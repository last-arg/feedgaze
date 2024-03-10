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
  [ ] Add tags
[ ] Parsing RSS: <guid isPermalink="true"> mean value is valid link. Useful if 
there is no <link>
[ ] Decode/encode HTML characters
[ ] Remove html tags when parsing title/description
  [ ] Can be "&lt;", "&gt;" 
  [ ] Can be "<", ">" if inside "<![CDATA[ ... ]]>" 
    [ ] Can probably also be "&lt;", "&gt;" 
  [ ] Some symbols are just part of the text. Are not tags
  - Considerations
    - tags must be alphanumeric https://html.spec.whatwg.org/multipage/syntax.html#syntax-tag-name
      - I think tag must start with a alphabet letter
      - but custom tags can contain "-"?
    - open tag must follow with tag name "<code ... >"
    - close tag must follow with "/" ("</code>")
    - this will probably remove more than I want in rare cases
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
[ ] Add http server
  - https://github.com/zigzap/zap
  - https://github.com/cztomsik/tokamak
  - https://github.com/karlseguin/http.zig
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

# Old 
[ ] UI with [zig-webui](https://github.com/webui-dev/zig-webui)
Tried this and liked it. But I think I can just go with a server. 
