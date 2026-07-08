package com.synctune.core.database

import com.synctune.core.model.Song
import java.sql.PreparedStatement
import java.sql.ResultSet

class SongDao(private val db: DatabaseManager) {
    fun insertSong(song: Song) {
        val sql = "INSERT OR REPLACE INTO songs(fileHash,filePath,fileName,title,artist,album,duration,modifiedTime,isFavourite,isDirty) VALUES(?,?,?,?,?,?,?,?,?,?)"
        db.connection.prepareStatement(sql).use { ps ->
            ps.setString(1, song.fileHash)
            ps.setString(2, song.filePath)
            ps.setString(3, song.fileName)
            ps.setString(4, song.title)
            ps.setString(5, song.artist)
            ps.setString(6, song.album)
            ps.setLong(7, song.duration)
            ps.setLong(8, song.modifiedTime)
            ps.setInt(9, if (song.isFavourite) 1 else 0)
            ps.setInt(10, if (song.isDirty) 1 else 0)
            ps.executeUpdate()
        }
    }

    fun updateSong(song: Song) {
        val sql = "UPDATE songs SET filePath=?,fileName=?,title=?,artist=?,album=?,duration=?,modifiedTime=?,isFavourite=?,isDirty=? WHERE fileHash=?"
        db.connection.prepareStatement(sql).use { ps ->
            ps.setString(1, song.filePath)
            ps.setString(2, song.fileName)
            ps.setString(3, song.title)
            ps.setString(4, song.artist)
            ps.setString(5, song.album)
            ps.setLong(6, song.duration)
            ps.setLong(7, song.modifiedTime)
            ps.setInt(8, if (song.isFavourite) 1 else 0)
            ps.setInt(9, if (song.isDirty) 1 else 0)
            ps.setString(10, song.fileHash)
            ps.executeUpdate()
        }
    }

    fun updateFavourite(hash: String, value: Boolean) {
        // 设置收藏时，同时标记 isDirty 为 1，这样下一次同步会上传
        val sql = "UPDATE songs SET isFavourite=?, isDirty=1 WHERE fileHash=?"
        db.connection.prepareStatement(sql).use { ps ->
            ps.setInt(1, if (value) 1 else 0)
            ps.setString(2, hash)
            ps.executeUpdate()
        }
    }

    fun getAllSongs(): List<Song> {
        val sql = "SELECT * FROM songs"
        return db.query(sql) { rs -> toSong(rs) }
    }

    fun getFavouriteHashes(): Set<String> {
        val sql = "SELECT fileHash FROM songs WHERE isFavourite=1"
        return db.query(sql, mapper = { it.getString("fileHash") }).toSet()
    }

    private fun toSong(rs: ResultSet): Song {
        return Song(
            fileHash = rs.getString("fileHash"),
            filePath = rs.getString("filePath"),
            fileName = rs.getString("fileName"),
            title = rs.getString("title"),
            artist = rs.getString("artist"),
            album = rs.getString("album"),
            duration = rs.getLong("duration"),
            modifiedTime = rs.getLong("modifiedTime"),
            isFavourite = rs.getInt("isFavourite") == 1,
            isDirty = rs.getInt("isDirty") == 1
        )
    }
}
