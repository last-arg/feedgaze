// TODO?: put default values into contants?
pub const Table = struct {
    pub const item = struct {
        pub const create =
            \\CREATE TABLE IF NOT EXISTS item(
            \\  id INTEGER PRIMARY KEY,
            \\  feed_id INTEGER,
            \\  title TEXT,
            \\  link TEXT UNIQUE DEFAULT NULL,
            \\  guid TEXT UNIQUE DEFAULT NULL,
            \\  pub_date TEXT DEFAULT NULL,
            \\  pub_date_utc INTEGER DEFAULT NULL,
            \\  created_at TEXT DEFAULT CURRENT_TIMESTAMP,
            \\  FOREIGN KEY(feed_id) REFERENCES feed(id)
            \\);
        ;
        pub const insert =
            \\INSERT INTO item (feed_id, title, link, guid, pub_date, pub_date_utc)
            \\VALUES (
            \\  ?{usize},
            \\  ?{[]const u8},
            \\  ?,
            \\  ?,
            \\  ?,
            \\  ?
            \\)
        ;
        pub const select_all =
            \\SELECT
            \\  title,
            \\  link,
            \\  pub_date,
            \\  created_at,
            \\  feed_id,
            \\  id
            \\FROM item
        ;
        pub const count_all =
            \\SELECT
            \\  count(feed_id)
            \\FROM item
        ;
        pub const on_conflict_guid =
            \\ON CONFLICT(guid) DO UPDATE SET
            \\  title = excluded.title,
            \\  link = excluded.link,
            \\  pub_date = excluded.pub_date,
            \\  pub_date_utc = excluded.pub_date_utc
            \\WHERE
            \\  excluded.feed_id = feed_id
            \\  AND excluded.pub_date_utc != pub_date_utc
        ;
        pub const on_conflict_link =
            \\ON CONFLICT(link) DO UPDATE SET
            \\  title = excluded.title,
            \\  guid = excluded.guid,
            \\  pub_date = excluded.pub_date,
            \\  pub_date_utc = excluded.pub_date_utc
            \\WHERE
            \\  excluded.feed_id = feed_id
            \\  AND excluded.pub_date_utc != pub_date_utc
        ;
        pub const has_item =
            \\SELECT 1 FROM item
            \\WHERE feed_id = ?
            \\  AND pub_date_utc = ?
            \\  AND guid IS NULL
            \\  AND link IS NULL
        ;
        pub const update =
            \\UPDATE item SET
            \\  title = ?{[]const u8},
            \\  link = ?,
            \\  guid = ?
            \\WHERE
            \\  feed_id = ?
            \\  AND pub_date_utc = ?
            \\  AND guid IS NULL
            \\  AND link IS NULL
        ;
    };
    pub const setting = struct {
        pub const create =
            \\CREATE TABLE IF NOT EXISTS setting(
            \\  version INTEGER NOT NULL DEFAULT 1
            \\);
        ;
    };
    // TODO fields:
    // 		skip_days ?
    // 		skip_hours ?
    pub const feed_update = struct {
        pub const create =
            \\CREATE TABLE IF NOT EXISTS feed_update (
            \\  feed_id INTEGER UNIQUE,
            \\  update_interval INTEGER DEFAULT 6000,
            \\  ttl INTEGER DEFAULT NULL,
            \\  last_update INTEGER DEFAULT (strftime('%s', 'now')),
            \\  FOREIGN KEY(feed_id) REFERENCES feed(id)
            \\);
        ;
        pub const insert =
            \\INSERT INTO feed_update
            \\  (feed_id, ttl)
            \\VALUES (
            \\  ?{usize},
            \\  ?
            \\)
        ;
        pub const selectAll =
            \\SELECT
            \\  feed_id,
            \\  update_interval,
            \\  ttl,
            \\  last_update
            \\FROM feed_update;
        ;
        pub const on_conflict =
            \\ON CONFLICT(feed_id) DO UPDATE SET
            \\  update_interval = excluded.update_interval,
            \\  ttl = excluded.ttl,
            \\  last_update = (strftime('%s', 'now'))
        ;
    };
    pub const feed = struct {
        pub const create =
            \\CREATE TABLE IF NOT EXISTS feed(
            \\  id INTEGER PRIMARY KEY,
            \\  title TEXT NOT NULL,
            \\  link TEXT NOT NULL,
            \\  location TEXT NOT NULL UNIQUE,
            \\  pub_date TEXT DEFAULT NULL,
            \\  pub_date_utc INTEGER DEFAULT NULL,
            \\  created_at TEXT DEFAULT CURRENT_TIMESTAMP
            \\);
        ;
    };
};

pub const Query = struct {
    pub const insert = .{
        // TODO: use UPSERT instead
        // Or something else that keeps row at one
        .setting =
        \\INSERT INTO setting (version) VALUES (?{usize});
        ,
        .feed =
        \\INSERT INTO feed (title, link, location, pub_date, pub_date_utc)
        \\VALUES (
        \\  ?{[]const u8},
        \\  ?{[]const u8},
        \\  ?{[]const u8},
        \\  ?,
        \\  ?
        \\);
        ,
        .item =
        \\INSERT INTO item (feed_id, title, link, guid, pub_date, pub_date_utc)
        \\VALUES (
        \\  ?{usize},
        \\  ?{[]const u8},
        \\  ?,
        \\  ?,
        \\  ?,
        \\  ?
        \\)
        \\ON CONFLICT(guid,link,pub_date_utc)
        // \\WHERE guid IS NULL
        \\DO UPDATE SET
        \\  title='New_Title',
        \\  link = excluded.link,
        \\  pub_date = excluded.pub_date,
        \\  pub_date_utc = excluded.pub_date_utc
        // \\WHERE link IS NOT NULL AND guid IS NOT NULL
        \\WHERE ((title is not null OR link is not null)
        \\AND excluded.pub_date_utc != pub_date_utc
        \\AND excluded.feed_id = feed_id)
        \\OR (title is null AND link is null AND excluded.feed_id = feed_id AND excluded.pub_date_utc = pub_date_utc)
    };
    pub const update = .{
        .feed_id =
        \\UPDATE feed SET
        \\  title = ?{[]const u8},
        \\  link = ?{[]const u8},
        \\  pub_date = ?,
        \\  pub_date_utc = ?
        \\WHERE id = ?{usize}
    };
    pub const select = .{
        .feed =
        \\SELECT
        \\  title,
        \\  link,
        \\  location,
        \\  id,
        \\  pub_date_utc
        \\FROM feed;
        ,
        .feed_location =
        \\SELECT
        \\  title,
        \\  link,
        \\  location,
        \\  id,
        \\  pub_date_utc
        \\FROM feed
        \\WHERE location = ?{[]const u8}
        ,
        .setting =
        \\SELECT
        \\  version
        \\FROM setting;
    };
};
