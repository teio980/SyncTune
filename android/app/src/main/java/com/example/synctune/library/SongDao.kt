package com.example.synctune.library

import android.content.ContentValues
import android.content.Context
import android.database.Cursor

class SongDao(context: Context) {

    private val dbHelper = MusicDbHelper(context)

    fun insertSong(song: Song): Long {
        val db = dbHelper.writableDatabase

        val values = ContentValues().apply {
            put(SongContract.SongEntry.COLUMN_NAME_TITLE, song.title)
            put(SongContract.SongEntry.COLUMN_NAME_ARTIST, song.artist)
            put(SongContract.SongEntry.COLUMN_NAME_ALBUM, song.album)
            put(SongContract.SongEntry.COLUMN_NAME_FILE_PATH, song.filePath)
            put(SongContract.SongEntry.COLUMN_NAME_FILE_NAME, song.fileName)
            put(SongContract.SongEntry.COLUMN_NAME_FILE_HASH, song.fileHash)
            put(SongContract.SongEntry.COLUMN_NAME_MODIFIED_TIME, song.modifiedTime)
            put(SongContract.SongEntry.COLUMN_NAME_IS_FAVOURITE, if (song.isFavourite) 1 else 0)
        }

        return db.insert(SongContract.SongEntry.TABLE_NAME, null, values)
    }

    fun getAllSongs(): List<Song> {
        val db = dbHelper.readableDatabase
        val cursor = db.query(
            SongContract.SongEntry.TABLE_NAME,
            null,
            null,
            null,
            null,
            null,
            null
        )
        return cursorToSongs(cursor)
    }

    fun getFavouriteSongs(): List<Song> {
        val db = dbHelper.readableDatabase
        val selection = "${SongContract.SongEntry.COLUMN_NAME_IS_FAVOURITE} = ?"
        val selectionArgs = arrayOf("1")
        val cursor = db.query(
            SongContract.SongEntry.TABLE_NAME,
            null,
            selection,
            selectionArgs,
            null,
            null,
            null
        )
        return cursorToSongs(cursor)
    }

    fun updateFavouriteStatus(songId: Long, isFavourite: Boolean) {
        val db = dbHelper.writableDatabase
        val values = ContentValues().apply {
            put(SongContract.SongEntry.COLUMN_NAME_IS_FAVOURITE, if (isFavourite) 1 else 0)
        }
        val selection = "${SongContract.SongEntry.COLUMN_NAME_ID} = ?"
        val selectionArgs = arrayOf(songId.toString())
        db.update(SongContract.SongEntry.TABLE_NAME, values, selection, selectionArgs)
    }

    fun updateFavouriteByHash(fileHash: String, isFavourite: Boolean) {
        val db = dbHelper.writableDatabase
        val values = ContentValues().apply {
            put(SongContract.SongEntry.COLUMN_NAME_IS_FAVOURITE, if (isFavourite) 1 else 0)
        }
        val selection = "${SongContract.SongEntry.COLUMN_NAME_FILE_HASH} = ?"
        val selectionArgs = arrayOf(fileHash)
        db.update(SongContract.SongEntry.TABLE_NAME, values, selection, selectionArgs)
    }

    fun updateFileNameAndPath(fileHash: String, fileName: String, filePath: String) {
        val db = dbHelper.writableDatabase
        val values = ContentValues().apply {
            put(SongContract.SongEntry.COLUMN_NAME_FILE_NAME, fileName)
            put(SongContract.SongEntry.COLUMN_NAME_FILE_PATH, filePath)
        }
        val selection = "${SongContract.SongEntry.COLUMN_NAME_FILE_HASH} = ?"
        val selectionArgs = arrayOf(fileHash)
        db.update(SongContract.SongEntry.TABLE_NAME, values, selection, selectionArgs)
    }

    private fun cursorToSongs(cursor: Cursor): List<Song> {
        val songs = mutableListOf<Song>()
        with(cursor) {
            val idIndex = getColumnIndexOrThrow(SongContract.SongEntry.COLUMN_NAME_ID)
            val titleIndex = getColumnIndexOrThrow(SongContract.SongEntry.COLUMN_NAME_TITLE)
            val artistIndex = getColumnIndexOrThrow(SongContract.SongEntry.COLUMN_NAME_ARTIST)
            val albumIndex = getColumnIndexOrThrow(SongContract.SongEntry.COLUMN_NAME_ALBUM)
            val filePathIndex = getColumnIndexOrThrow(SongContract.SongEntry.COLUMN_NAME_FILE_PATH)
            val fileNameIndex = getColumnIndex(SongContract.SongEntry.COLUMN_NAME_FILE_NAME)
            val fileHashIndex = getColumnIndexOrThrow(SongContract.SongEntry.COLUMN_NAME_FILE_HASH)
            val modifiedTimeIndex = getColumnIndexOrThrow(SongContract.SongEntry.COLUMN_NAME_MODIFIED_TIME)
            val isFavouriteIndex = getColumnIndexOrThrow(SongContract.SongEntry.COLUMN_NAME_IS_FAVOURITE)

            while (moveToNext()) {
                val song = Song(
                    id = getLong(idIndex),
                    title = getString(titleIndex) ?: "Unknown",
                    artist = getString(artistIndex) ?: "Unknown Artist",
                    album = getString(albumIndex) ?: "Unknown Album",
                    filePath = getString(filePathIndex) ?: "",
                    fileName = if (fileNameIndex != -1) getString(fileNameIndex) ?: "" else "",
                    fileHash = getString(fileHashIndex) ?: "",
                    modifiedTime = getLong(modifiedTimeIndex),
                    isFavourite = getInt(isFavouriteIndex) == 1
                )
                songs.add(song)
            }
        }
        cursor.close()
        return songs
    }

    fun isSongExists(fileHash: String): Boolean {
        val db = dbHelper.readableDatabase
        val selection = "${SongContract.SongEntry.COLUMN_NAME_FILE_HASH} = ?"
        val selectionArgs = arrayOf(fileHash)
        val cursor = db.query(
            SongContract.SongEntry.TABLE_NAME,
            null,
            selection,
            selectionArgs,
            null,
            null,
            null
        )
        val exists = cursor.count > 0
        cursor.close()
        return exists
    }

    fun isSongExistsByPath(filePath: String): Boolean {
        val db = dbHelper.readableDatabase
        val selection = "${SongContract.SongEntry.COLUMN_NAME_FILE_PATH} = ?"
        val selectionArgs = arrayOf(filePath)
        val cursor = db.query(
            SongContract.SongEntry.TABLE_NAME,
            null,
            selection,
            selectionArgs,
            null,
            null,
            null
        )
        val exists = cursor.count > 0
        cursor.close()
        return exists
    }

    fun deleteSongById(id: Long) {
        val db = dbHelper.writableDatabase
        val selection = "${SongContract.SongEntry.COLUMN_NAME_ID} = ?"
        val selectionArgs = arrayOf(id.toString())
        db.delete(SongContract.SongEntry.TABLE_NAME, selection, selectionArgs)
    }
}
