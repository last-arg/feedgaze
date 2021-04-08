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
        pub const insert_minimal =
            \\INSERT INTO item (feed_id, title, pub_date, pub_date_utc)
            \\VALUES (
            \\  ?{usize},
            \\  ?{[]const u8},
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
        pub const select_id_by_title =
            \\SELECT id FROM item
            \\WHERE feed_id = ?
            \\  AND title = ?
            \\  AND guid IS NULL
            \\  AND link IS NULL
        ;
        pub const upsert_guid =
            \\INSERT INTO item (feed_id, title, guid, link, pub_date, pub_date_utc)
            \\VALUES ( ?{usize}, ?{[]const u8}, ?, ?, ?, ? )
            \\ON CONFLICT(guid) DO UPDATE SET
            \\  title = excluded.title,
            \\  link = excluded.link,
            \\  pub_date = excluded.pub_date,
            \\  pub_date_utc = excluded.pub_date_utc
            \\WHERE
            \\  excluded.feed_id = feed_id
            \\  AND excluded.pub_date_utc != pub_date_utc
        ;
        // NOTE: no guid inserted because if this query is run guid == null
        pub const upsert_link =
            \\INSERT INTO item (feed_id, title, link, pub_date, pub_date_utc)
            \\VALUES ( ?{usize}, ?{[]const u8}, ?, ?, ? )
            \\ON CONFLICT(link) DO UPDATE SET
            \\  title = excluded.title,
            \\  pub_date = excluded.pub_date,
            \\  pub_date_utc = excluded.pub_date_utc
            \\WHERE
            \\  excluded.feed_id = feed_id
            \\  AND excluded.pub_date_utc != pub_date_utc
        ;
        pub const update_date =
            \\UPDATE item SET
            \\  pub_date = ?,
            \\  pub_date_utc = ?
            \\WHERE
            \\  id = ?
            \\  AND pub_date_utc != ?
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

    pub const feed_update_local = struct {
        pub const create =
            \\CREATE TABLE IF NOT EXISTS feed_update_local (
            \\  feed_id INTEGER UNIQUE,
            \\  update_interval INTEGER DEFAULT 600,
            \\  last_update INTEGER DEFAULT (strftime('%s', 'now')),
            \\  last_modified_timestamp INTEGER,
            \\  FOREIGN KEY(feed_id) REFERENCES feed(id) ON DELETE CASCADE
            \\);
        ;
        pub const insert =
            \\INSERT INTO feed_update_local
            \\  (feed_id, last_modified_timestamp)
            \\VALUES (
            \\  ?{usize},
            \\  ?{i64}
            \\)
        ;
        pub const on_conflict_feed_id =
            \\ON CONFLICT(feed_id) DO UPDATE SET
            \\  last_modified_timestamp = excluded.last_modified_timestamp,
            \\  last_update = (strftime('%s', 'now'))
        ;
        pub const selectAllWithLocation =
            \\SELECT
            \\  feed.location as location,
            \\  feed_id,
            \\  feed.updated_timestamp as feed_update_timestamp,
            \\  update_interval,
            \\  last_update,
            \\  last_modified_timestamp
            \\FROM feed_update_local
            \\LEFT JOIN feed ON feed_update_local.feed_id = feed.id;
        ;
    };

    pub const feed_update_http = struct {
        const name = "feed_update_http";
        pub const create =
            \\CREATE TABLE IF NOT EXISTS feed_update_http (
            \\  feed_id INTEGER UNIQUE,
            \\  update_interval INTEGER DEFAULT 600,
            \\  last_update INTEGER DEFAULT (strftime('%s', 'now')),
            \\  cache_control_max_age INTEGER DEFAULT NULL,
            \\  expires_utc INTEGER DEFAULT NULL,
            \\  last_modified_utc INTEGER DEFAULT NULL,
            \\  etag TEXT DEFAULT NULL,
            \\  FOREIGN KEY(feed_id) REFERENCES feed(id) ON DELETE CASCADE
            \\);
        ;
        pub const insert =
            \\INSERT INTO feed_update_http
            \\  (feed_id, cache_control_max_age, expires_utc, last_modified_utc, etag)
            \\VALUES (
            \\  ?{usize},
            \\  ?,
            \\  ?,
            \\  ?,
            \\  ?
            \\)
        ;

        pub const update_id =
            \\UPDATE feed_update_http SET
            \\  cache_control_max_age = ?,
            \\  expires_utc = ?,
            \\  last_modified_utc = ?,
            \\  etag = ?,
            \\  last_update = ?
            \\WHERE feed_id = ?
        ;
        pub const selectAll =
            \\SELECT
            \\  etag,
            \\  feed_id,
            \\  update_interval,
            \\  last_update,
            \\  expires_utc,
            \\  last_modified_utc,
            \\  cache_control_max_age
            \\FROM feed_update_http;
        ;
        pub const selectAllWithLocation =
            \\SELECT
            \\  feed.location as location,
            \\  etag,
            \\  feed_id,
            \\  feed.updated_timestamp as feed_update_timestamp,
            \\  update_interval,
            \\  last_update,
            \\  expires_utc,
            \\  last_modified_utc,
            \\  cache_control_max_age
            \\FROM feed_update_http
            \\LEFT JOIN feed ON feed_update_http.feed_id = feed.id;
        ;
        pub const on_conflict_feed_id =
            \\ ON CONFLICT(feed_id) DO UPDATE SET
            \\  cache_control_max_age = excluded.cache_control_max_age,
            \\  expires_utc = excluded.expires_utc,
            \\  last_modified_utc = excluded.last_modified_utc,
            \\  etag = excluded.etag,
            \\  last_update = (strftime('%s', 'now'))
        ;
    };
    pub const feed = struct {
        pub const create =
            \\CREATE TABLE IF NOT EXISTS feed(
            \\  id INTEGER PRIMARY KEY,
            \\  location TEXT NOT NULL UNIQUE,
            \\  title TEXT NOT NULL,
            \\  link TEXT DEFAULT NULL,
            \\  updated_raw TEXT DEFAULT NULL,
            \\  updated_timestamp INTEGER DEFAULT NULL,
            \\  added_at INTEGER DEFAULT (strftime('%s', 'now'))
            \\);
        ;
        pub const insert =
            \\INSERT INTO feed (title, location, link, updated_raw, updated_timestamp)
            \\VALUES (
            \\  ?{[]const u8},
            \\  ?{[]const u8},
            \\  ?,
            \\  ?,
            \\  ?
            \\)
        ;
        pub const on_conflict_location =
            \\ ON CONFLICT(location) DO UPDATE SET
            \\   title = excluded.title,
            \\   link = excluded.link,
            \\   updated_raw = excluded.updated_raw,
            \\   updated_timestamp = excluded.updated_timestamp
            \\WHERE updated_timestamp != excluded.updated_timestamp
        ;
        pub const delete_where_location =
            \\delete from feed where location = ?
        ;
        pub const delete_where_id =
            \\delete from feed where id = ?
        ;
        pub const select =
            \\SELECT
            \\  title,
            \\  location,
            \\  link,
            \\  updated_raw,
            \\  id,
            \\  updated_timestamp
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
        pub const update_where_id =
            \\UPDATE feed SET
            \\  title = ?{[]const u8},
            \\  link = ?,
            \\  updated_raw = ?,
            \\  updated_timestamp = ?
            \\WHERE id = ?{usize}
        ;
    };
};
