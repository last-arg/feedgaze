const comptimePrint = @import("std").fmt.comptimePrint;
pub const update_interval = 600;
pub const Table = struct {
    pub const item = struct {
        pub const create =
            \\CREATE TABLE IF NOT EXISTS item(
            \\  id INTEGER PRIMARY KEY,
            \\  feed_id INTEGER NOT NULL,
            \\  title TEXT NOT NULL,
            \\  link TEXT DEFAULT NULL,
            \\  guid TEXT DEFAULT NULL,
            \\  pub_date TEXT DEFAULT NULL,
            \\  pub_date_utc INTEGER DEFAULT NULL,
            \\  modified_at INTEGER DEFAULT (strftime('%s', 'now')),
            \\  FOREIGN KEY(feed_id) REFERENCES feed(id) ON DELETE CASCADE,
            \\  UNIQUE(feed_id, guid),
            \\  UNIQUE(feed_id, link)
            \\);
        ;
    };

    pub const feed_update_local = struct {
        pub const create = comptimePrint(
            \\CREATE TABLE IF NOT EXISTS feed_update_local (
            \\  feed_id INTEGER UNIQUE,
            \\  update_interval INTEGER DEFAULT {d},
            \\  last_update INTEGER DEFAULT (strftime('%s', 'now')),
            \\  last_modified_timestamp INTEGER,
            \\  FOREIGN KEY(feed_id) REFERENCES feed(id) ON DELETE CASCADE
            \\);
        , .{update_interval});
    };

    pub const feed_update_http = struct {
        const name = "feed_update_http";
        pub const create = comptimePrint(
            \\CREATE TABLE IF NOT EXISTS feed_update_http (
            \\  feed_id INTEGER UNIQUE,
            \\  update_countdown INTEGER DEFAULT 0,
            \\  update_interval INTEGER DEFAULT {d},
            \\  last_update INTEGER DEFAULT (strftime('%s', 'now')),
            \\  cache_control_max_age INTEGER DEFAULT NULL,
            \\  expires_utc INTEGER DEFAULT NULL,
            \\  last_modified_utc INTEGER DEFAULT NULL,
            \\  etag TEXT DEFAULT NULL,
            \\  FOREIGN KEY(feed_id) REFERENCES feed(id) ON DELETE CASCADE
            \\);
        , .{update_interval});
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
        pub const update_where_id =
            \\UPDATE feed SET
            \\  link = ?,
            \\  updated_raw = ?,
            \\  updated_timestamp = ?
            \\WHERE id = ?{u64}
        ;
    };

    pub const feed_tag = struct {
        pub const create =
            \\CREATE TABLE IF NOT EXISTS feed_tag (
            \\  feed_id INTEGER NOT NULL,
            \\  tag TEXT NOT NULL,
            \\  UNIQUE(feed_id, tag)
            \\  FOREIGN KEY(feed_id) REFERENCES feed(id) ON DELETE CASCADE
            \\);
            \\
        ;
    };
};
