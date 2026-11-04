- html parsing: get date from url path?
- replace http.zig with dusty?
- zt use 'fn format' or 'fn formatHtml'
    - especially enums that need to be turned into numbers
- check adding timeout to async code? Can I?
- handle feed_pick_post fetch errors
- error:
```
thread 197014 panic: index out of bounds: index 40595, len 19221
/mnt/hdd/code/feedgaze/src/feed_parse.zig:49:24: 0x16b6713 in slice_from_loc (main.zig)
    return self.content[loc.offset..loc.offset + loc.len];
                       ^
/mnt/hdd/code/feedgaze/src/feed_parse.zig:1476:48: 0x130672f in parse (main.zig)
            const item_id = self.slice_from_loc(loc);
                                               ^
/mnt/hdd/code/feedgaze/src/app.zig:1438:41: 0x1309ee0 in update_feed (main.zig)
        const parsed = try parsing.parse(arena.allocator(), html_options, .{
                                        ^
/nix/store/vvg5zp3bwmbygxdcafkhl7zs1j0x9pa9-zig-0.17.0/lib/std/Io.zig:2537:13: 0x1bd3cbf in start (std.zig)
            result_casted.* = @call(.auto, function, args_casted.*);
            ^
/nix/store/vvg5zp3bwmbygxdcafkhl7zs1j0x9pa9-zig-0.17.0/lib/std/Io/Threaded.zig:744:20: 0x1290d5e in start (std.zig)
        future.func(future.contextPointer(), future.resultPointer());
                   ^
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
