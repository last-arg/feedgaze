// TODO?: put default values into contants?
// TODO: if concatenating queries have to remove semicolons
// and add spaces to end or beginning
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
            \\  created_at INTEGER DEFAULT (strftime('%s', 'now')),
            \\  FOREIGN KEY(feed_id) REFERENCES feed(id) ON DELETE CASCADE
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
        pub const select_feed_latest =
            \\SELECT pub_date_utc FROM item
            \\WHERE feed_id = ? AND pub_date_utc IS NOT NULL
            \\ORDER BY pub_date_utc DESC LIMIT 1;
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
        pub const update_without_guid_and_link =
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
        pub const insert =
            \\INSERT INTO setting (version) VALUES (?{usize});
        ;
        pub const select =
            \\SELECT
            \\  version
            \\FROM setting;
        ;
    };
    pub const feed_update = struct {
        // TODO: move last_build_date* fields to feed table
        pub const create =
            \\CREATE TABLE IF NOT EXISTS feed_update (
            \\  feed_id INTEGER UNIQUE,
            \\  update_interval INTEGER DEFAULT 600,
            \\  ttl INTEGER DEFAULT NULL,
            \\  last_update INTEGER DEFAULT (strftime('%s', 'now')),
            \\  cache_control_max_age INTEGER DEFAULT NULL,
            \\  expires_utc INTEGER DEFAULT NULL,
            \\  last_modified_utc INTEGER DEFAULT NULL,
            \\  etag TEXT DEFAULT NULL,
            \\  FOREIGN KEY(feed_id) REFERENCES feed(id) ON DELETE CASCADE
            \\);
        ;
        pub const insert =
            \\INSERT INTO feed_update
            \\  (feed_id, ttl, cache_control_max_age, expires_utc, last_modified_utc, etag)
            \\VALUES (
            \\  ?{usize},
            \\  ?,
            \\  ?,
            \\  ?,
            \\  ?,
            \\  ?
            \\)
        ;

        pub const update_all =
            \\UPDATE feed_update SET last_update = strftime('%s', 'now')
        ;
        pub const update_id =
            \\UPDATE feed_update SET
            \\  ttl = ?,
            \\  cache_control_max_age = ?,
            \\  expires_utc = ?,
            \\  last_modified_utc = ?,
            \\  etag = ?
            \\WHERE feed_id = ?
        ;
        pub const selectAll =
            \\SELECT
            \\  etag,
            \\  feed_id,
            \\  update_interval,
            \\  ttl,
            \\  last_update,
            \\  expires_utc,
            \\  last_modified_utc,
            \\  cache_control_max_age
            \\FROM feed_update;
        ;
        pub const selectAllWithLocation =
            \\SELECT
            \\  feed.location as location,
            \\  etag,
            \\  feed_id,
            \\  update_interval,
            \\  ttl,
            \\  last_update,
            \\  expires_utc,
            \\  last_modified_utc,
            \\  cache_control_max_age,
            \\  feed.pub_date_utc as pub_date_utc,
            \\  feed.last_build_date_utc as last_build_date_utc
            \\FROM feed_update
            \\LEFT JOIN feed ON feed_update.feed_id = feed.id;
        ;
        pub const on_conflict_feed_id =
            \\ ON CONFLICT(feed_id) DO UPDATE SET
            \\  update_interval = excluded.update_interval,
            \\  ttl = excluded.ttl,
            \\  cache_control_max_age = excluded.cache_control_max_age,
            \\  expires_utc = excluded.expires_utc,
            \\  last_modified_utc = excluded.last_modified_utc,
            \\  etag = excluded.etag,
            \\  last_update = (strftime('%s', 'now'))
            // \\WHERE last_build_date_utc != excluded.last_build_date_utc
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
            \\  last_build_date TEXT DEFAULT NULL,
            \\  last_build_date_utc INTEGER DEFAULT NULL,
            \\  created_at TEXT DEFAULT CURRENT_TIMESTAMP
            \\);
        ;
        pub const insert =
            \\INSERT INTO feed (title, link, location, pub_date, pub_date_utc, last_build_date, last_build_date_utc)
            \\VALUES (
            \\  ?{[]const u8},
            \\  ?{[]const u8},
            \\  ?{[]const u8},
            \\  ?,
            \\  ?,
            \\  ?,
            \\  ?
            \\)
        ;
        pub const on_conflict_location =
            \\ ON CONFLICT(location) DO UPDATE SET
            \\   title = excluded.title,
            \\   link = excluded.link,
            \\   pub_date = excluded.pub_date,
            \\   pub_date_utc = excluded.pub_date_utc
            \\WHERE pub_date_utc != excluded.pub_date_utc
        ;
        pub const select =
            \\SELECT
            \\  title,
            \\  link,
            \\  location,
            \\  id,
            \\  pub_date_utc
            \\FROM feed
        ;
        pub const select_location =
            \\SELECT
            \\  location
            \\FROM feed
        ;
        pub const select_id =
            \\SELECT
            \\  id
            \\FROM feed
        ;
        pub const where_location =
            \\ WHERE location = ?{[]const u8}
        ;
        pub const where_id =
            \\ WHERE id = ?{usize}
        ;
        pub const update_id =
            \\UPDATE feed SET
            \\  title = ?{[]const u8},
            \\  link = ?{[]const u8},
            \\  pub_date = ?,
            \\  pub_date_utc = ?,
            \\  last_build_date = ?,
            \\  last_build_date_utc = ?
            \\WHERE id = ?{usize}
        ;
        pub const update_where_id =
            \\UPDATE feed SET
            \\  title = ?{[]const u8},
            \\  link = ?{[]const u8},
            \\  location = ?{[]const u8},
            \\  pub_date = ?,
            \\  pub_date_utc = ?,
            \\  last_build_date = ?,
            \\  last_build_date_utc = ?
            \\WHERE id = ?{usize}
        ;
    };
};
