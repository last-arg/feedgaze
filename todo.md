- html parsing: get date from url path?
- added 'pub const c = @import(...)' to fridge package main.zig to get access to
  sqlite3_snprintf. Have to see if it is needed
- make feed updating non-blocking
- old reddit feed gets error NoHtmlOptions
- 'https://implaustin.hashnode.dev/' returns Forbidden
  Probably because cloudflare protection?
- check image warnings
```
warning: Failed to get icon 'https://insidegovuk.blog.gov.uk/wp-content/themes/gds-blogs/build/node_modules/govuk-frontend/dist/govuk/assets/rebrand/images/favicon.ico'. Response body is empty. Got HTTP status code 404

url: https://storage.ghost.io/c/b4/3e/b43eb8f8-cafd-49ee-ab1f-e4fe989d2890/content/images/size/w256h256/2023/03/apis-logo-square.png
warning: Failed to parse date '6255c65600e043e626c7a318'. Error: error.Overflow

url: https://storage.ghost.io/c/e9/cd/e9cd41fa-38ff-4a54-98d9-175f5b5d501c/content/images/size/w256h256/2018/11/glider_big.png
warning: Failed to parse date '756cffb5002e1cf71dbca318'. Error: error.Overflow

warning: Failed to process image 'https://www.sarasoueidan.com/favicon.ico'

Should be '/favicon/ico' without '/images/'
warning: Failed to get icon 'https://antithesis.com/images/favicon.ico'. Response body is empty. Got HTTP status code 404
```

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
