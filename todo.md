- html parsing: get date from url path?
- added 'pub const c = @import(...)' to fridge package main.zig to get access to
  sqlite3_snprintf. Have to see if it is needed
- make feed updating non-blocking

- website:
  - print form errors near fields where the error took place
  - minify html
  - a11y styling
    - https://github.com/Terryc21/XcodeResources/blob/main/Colorblind_Accessibility_Guide.md
    - change info, warning, error colors where necessary
    - colors from? https://design.homeoffice.gov.uk/design-system/components?name=Alert
    - should also add icon
- feed page:
  - display message when failed to fetch icon
- root page:
  - limit how many items rendered
    - Paginate if there are too many items?
    - Only paginate if items are new?


- twitch and youtube integration for live streams
  - and for twitch get latest broadcasts
- validate feed tags where needed
  - Need to figure out rules for valid tags
  - Valid tag symbols?:
    - A-z, 0-9
    - no space
  - length limit?
- third party service: https://openrss.org/
- Logo ideas
  - keywords: feed, gaze, rss, atom, links
  - Something with gaze and atoms?


# Future (Maybe)
[ ] (Popular) Sites that don't support feeds (twitter, instagram, soundcloud).
  [ ] Let user defined 'feed' area?
[ ] Mark feeds to use OS notification system on new link(s)
[ ] Mark feeds that will send email on new link(s)
[ ] For cli UX implement https://en.wikipedia.org/wiki/Damerau%E2%80%93Levenshtein_distance to print word user might have meant
[ ] UI
  [ ] TUI - NotCurses
    * Example: https://github.com/dundalek/notcurses-zig-example
[ ] Can disable updating for feeds?
  Currently have no need for this.
