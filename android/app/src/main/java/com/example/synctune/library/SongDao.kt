package com.example.synctune.library

import android.content.ContentValues
import android.content.Context
import android.database.Cursor

class SongDao(context: Context) {

    private val dbHelper = MusicDbHelper(context)

    fun insertSong(song: Song): Long {
        val db = dbHelper.writableDatabase
        return db.insert(SongContract.SongEntry.TABLE_NAME, null, songToContentValues(song))
    }

    fun getAllSongs(): List<Song> {
        return getAllSongsSorted()
    }

    fun getAllSongsSorted(orderBy: String = "title"): List<Song> {
        val db = dbHelper.readableDatabase
        val sortOrder = when(orderBy) {
            "artist" -> "${SongContract.SongEntry.COLUMN_NAME_ARTIST} COLLATE NOCASE ASC"
            "date" -> "${SongContract.SongEntry.COLUMN_NAME_MODIFIED_TIME} DESC"
            else -> "${SongContract.SongEntry.COLUMN_NAME_TITLE} COLLATE NOCASE ASC"
        }
        val cursor = db.query(SongContract.SongEntry.TABLE_NAME, null, null, null, null, null, sortOrder)
        return cursorToSongs(cursor)
    }

    fun getSongByHash(hash: String): Song? {
        val db = dbHelper.readableDatabase
        val selection = "${SongContract.SongEntry.COLUMN_NAME_FILE_HASH} = ?"
        val selectionArgs = arrayOf(hash)
        val cursor = db.query(SongContract.SongEntry.TABLE_NAME, null, selection, selectionArgs, null, null, null)
        val songs = cursorToSongs(cursor)
        return if (songs.isNotEmpty()) songs[0] else null
    }

    fun getFavouriteSongs(orderBy: String = "title"): List<Song> {
        val db = dbHelper.readableDatabase
        val selection = "${SongContract.SongEntry.COLUMN_NAME_IS_FAVOURITE} = ?"
        val selectionArgs = arrayOf("1")
        val sortOrder = when(orderBy) {
            "artist" -> "${SongContract.SongEntry.COLUMN_NAME_ARTIST} COLLATE NOCASE ASC"
            "date" -> "${SongContract.SongEntry.COLUMN_NAME_MODIFIED_TIME} DESC"
            else -> "${SongContract.SongEntry.COLUMN_NAME_TITLE} COLLATE NOCASE ASC"
        }
        val cursor = db.query(SongContract.SongEntry.TABLE_NAME, null, selection, selectionArgs, null, null, sortOrder)
        return cursorToSongs(cursor)
    }

    fun updateSong(song: Song) {
        val db = dbHelper.writableDatabase
        val selection = "${SongContract.SongEntry.COLUMN_NAME_ID} = ?"
        val selectionArgs = arrayOf(song.id.toString())
        db.update(SongContract.SongEntry.TABLE_NAME, songToContentValues(song), selection, selectionArgs)
    }

    fun updateFavouriteStatus(songId: Long, isFavourite: Boolean) {
        val db = dbHelper.writableDatabase
        val values = ContentValues().apply { 
            put(SongContract.SongEntry.COLUMN_NAME_IS_FAVOURITE, if (isFavourite) 1 else 0)
            // 关键：每次更新收藏状态时，自动更新最后修改时间
            put(SongContract.SongEntry.COLUMN_NAME_FAV_LAST_UPDATED, System.currentTimeMillis())
        }
        db.update(SongContract.SongEntry.TABLE_NAME, values, "${SongContract.SongEntry.COLUMN_NAME_ID} = ?", arrayOf(songId.toString()))
    }

    // 内部同步专用：允许手动指定时间戳（从云端同步时使用）
    fun updateFavouriteStatusWithTimestamp(songId: Long, isFavourite: Boolean, timestamp: Long) {
        val db = dbHelper.writableDatabase
        val values = ContentValues().apply { 
            put(SongContract.SongEntry.COLUMN_NAME_IS_FAVOURITE, if (isFavourite) 1 else 0)
            put(SongContract.SongEntry.COLUMN_NAME_FAV_LAST_UPDATED, timestamp)
        }
        db.update(SongContract.SongEntry.TABLE_NAME, values, "${SongContract.SongEntry.COLUMN_NAME_ID} = ?", arrayOf(songId.toString()))
    }

    fun updateDirtyStatus(songId: Long, isDirty: Boolean) {
        val db = dbHelper.writableDatabase
        val values = ContentValues().apply { put(SongContract.SongEntry.COLUMN_NAME_IS_DIRTY, if (isDirty) 1 else 0) }
        db.update(SongContract.SongEntry.TABLE_NAME, values, "${SongContract.SongEntry.COLUMN_NAME_ID} = ?", arrayOf(songId.toString()))
    }

    fun deleteSongsByIds(ids: List<Long>) {
        if (ids.isEmpty()) return
        val db = dbHelper.writableDatabase
        db.beginTransaction()
        try {
            ids.forEach { db.delete(SongContract.SongEntry.TABLE_NAME, "${SongContract.SongEntry.COLUMN_NAME_ID} = ?", arrayOf(it.toString())) }
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
    }

    private fun songToContentValues(song: Song) = ContentValues().apply {
        put(SongContract.SongEntry.COLUMN_NAME_TITLE, song.title)
        put(SongContract.SongEntry.COLUMN_NAME_ARTIST, song.artist)
        put(SongContract.SongEntry.COLUMN_NAME_ALBUM, song.album)
        put(SongContract.SongEntry.COLUMN_NAME_FILE_PATH, song.filePath)
        put(SongContract.SongEntry.COLUMN_NAME_FILE_NAME, song.fileName)
        put(SongContract.SongEntry.COLUMN_NAME_FILE_HASH, song.fileHash)
        put(SongContract.SongEntry.COLUMN_NAME_MODIFIED_TIME, song.modifiedTime)
        put(SongContract.SongEntry.COLUMN_NAME_IS_FAVOURITE, if (song.isFavourite) 1 else 0)
        put(SongContract.SongEntry.COLUMN_NAME_IS_DIRTY, if (song.isDirty) 1 else 0)
        put(SongContract.SongEntry.COLUMN_NAME_FAV_LAST_UPDATED, song.favLastUpdated)
    }

    private fun cursorToSongs(cursor: Cursor): List<Song> {
        val songs = mutableListOf<Song>()
        with(cursor) {
            val idI = getColumnIndexOrThrow(SongContract.SongEntry.COLUMN_NAME_ID)
            val titleI = getColumnIndexOrThrow(SongContract.SongEntry.COLUMN_NAME_TITLE)
            val artistI = getColumnIndexOrThrow(SongContract.SongEntry.COLUMN_NAME_ARTIST)
            val albumI = getColumnIndexOrThrow(SongContract.SongEntry.COLUMN_NAME_ALBUM)
            val pathI = getColumnIndexOrThrow(SongContract.SongEntry.COLUMN_NAME_FILE_PATH)
            val nameI = getColumnIndexOrThrow(SongContract.SongEntry.COLUMN_NAME_FILE_NAME)
            val hashI = getColumnIndexOrThrow(SongContract.SongEntry.COLUMN_NAME_FILE_HASH)
            val modI = getColumnIndexOrThrow(SongContract.SongEntry.COLUMN_NAME_MODIFIED_TIME)
            val favI = getColumnIndexOrThrow(SongContract.SongEntry.COLUMN_NAME_IS_FAVOURITE)
            val dirtyI = getColumnIndexOrThrow(SongContract.SongEntry.COLUMN_NAME_IS_DIRTY)
            val favTimeI = getColumnIndexOrThrow(SongContract.SongEntry.COLUMN_NAME_FAV_LAST_UPDATED)

            while (moveToNext()) {
                songs.add(Song(getLong(idI), getString(titleI) ?: "Unknown", getString(artistI) ?: "Unknown", getString(albumI) ?: "Unknown",
                    getString(pathI) ?: "", getString(nameI) ?: "", getString(hashI) ?: "", getLong(modI), getInt(favI) == 1, getInt(dirtyI) == 1, getLong(favTimeI)))
            }
        }
        cursor.close()
        return songs
    }
}
