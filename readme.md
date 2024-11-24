# feedgaze
- Follow feeds (Rss, Atom)
- Make html page into feed
- Add tags to feeds
- Web server to manage feeds in the browser


## Usage
```
Usage: feedgaze [command] [options]

Commands

  add       Add feed
  remove    Remove feed(s)
  update    Update feed(s)
  rule      Feed adding rules
  run       Run update in foreground
  show      Print feeds' items
  server    Start server
  batch     Do path actions

General options:

  -h, --help        Print command-specific usage
  -d, --database    Database location
```


## HTML to feed
### Fields
- Feed item's selector (required)
- Feed item link selector (optional)
  - If no selector provided for link:
    - Will use first found <a> element's 'href' attribute
- Feed item title selector (optional)
  - If no selector provided for title:
    - Will use first found <h1>-<h6>
    - Will use whole item container's text 
- Feed item date selector (optional)
  - If no selector provided for title:
    - Finds first <time> element's 'datetime' attribute otherwise uses <time> elements content as date
- Date format (optional)
  - Format options:
    - year: YY, YYYY
    - month: MM, MMM (Jan, Sep)
    - day: DD
    - hour: HH
    - minute: mm
    - second: ss
    - timezone: Z (+02:00, -0800)
  - Example: 'xxx MMM DD YYYY'
    - 'xxx' is text I don't care about


## Inspiration
[fraidycat](https://fraidyc.at/) - [github](https://github.com/kickscondor/fraidycat)

