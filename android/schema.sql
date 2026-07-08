```sql
-- songs table
CREATE TABLE IF NOT EXISTS songs (
    id INTEGER PRIMARY KEY,
    title TEXT,
    artist TEXT,
    album TEXT,
    file_path TEXT,
    file_hash TEXT,
    modified_time INTEGER
);

-- playback_cache: stores last played song's progress and playback mode
CREATE TABLE IF NOT EXISTS playback_cache (
    id INTEGER PRIMARY KEY,
    song_hash TEXT NOT NULL,
    file_path TEXT NOT NULL,
    position INTEGER DEFAULT 0,
    repeat_mode INTEGER DEFAULT 0,
    shuffle_mode INTEGER DEFAULT 0,
    last_played_at INTEGER
);
