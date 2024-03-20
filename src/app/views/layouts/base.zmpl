<!DOCTYPE html>
<html>
  <head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta http-equiv="X-UA-Compatible" content="ie=edge">
    <title>entr-reload</title>
    <link rel="stylesheet" type="text/css" href="/styles.css">
  </head>

  <body>
    <header>
      <h1>feedgaze</h1>
      <div>
        <a href="/">Home</a>
        <a href="/feeds">Feeds</a>
        <a href="/tags">Tags</a>
      </div>

      <form action="/">
        <button style="display: none">Default form action</button>
        var data = try zmpl.get("tags");
        var it = data.iterator();
        var i: i64 = 0;
        while (it.next()) |tag| : (i += 1) {
          const index = zmpl.integer(i);
          <span>
            <input type="checkbox" name="tag" id="head-tag-{index}" value="{tag}">
            <label for="head-tag-{index}">{tag}</label>
          </span>
          <a href="/?tag={tag}">{tag}</a>
        }

        <button name="tags-only">Filter tags only</button>

        <label for="search_value">Search feeds</label>
        <input type="search" name="search" id="search_value" value="TODO">
        <button>Filter</button>
      </form>
    </header>

    <main>{zmpl.content}</main>
  </body>
</html>
