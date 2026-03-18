package com.synctune.core.database

import java.io.File
import java.sql.Connection
import java.sql.DriverManager
import java.sql.ResultSet
import java.sql.Statement

class DatabaseManager(private val dbFile: File) {
    val connection: Connection by lazy {
        Class.forName("org.sqlite.JDBC")
        val url = "jdbc:sqlite:${dbFile.absolutePath}"
        DriverManager.getConnection(url).also { initSchema(it) }
    }

    private fun initSchema(conn: Connection) {
        conn.createStatement().use { st ->
            // Create table if not exists
            st.execute(
                "CREATE TABLE IF NOT EXISTS songs(" +
                        "fileHash TEXT PRIMARY KEY," +
                        "filePath TEXT," +
                        "fileName TEXT," +
                        "title TEXT," +
                        "artist TEXT," +
                        "album TEXT," +
                        "duration INTEGER," +
                        "modifiedTime INTEGER," +
                        "isFavourite INTEGER," +
                        "isDirty INTEGER DEFAULT 0" +
                        ")"
            )
            
            // Migration: Add isDirty if missing from existing table
            try {
                val rs = st.executeQuery("PRAGMA table_info(songs)")
                var hasDirty = false
                while (rs.next()) {
                    if (rs.getString("name") == "isDirty") {
                        hasDirty = true
                        break
                    }
                }
                if (!hasDirty) {
                    st.execute("ALTER TABLE songs ADD COLUMN isDirty INTEGER DEFAULT 0")
                }
            } catch (e: Exception) {
                e.printStackTrace()
            }

            st.execute("CREATE INDEX IF NOT EXISTS idx_song_path ON songs(filePath)")
            st.execute("CREATE INDEX IF NOT EXISTS idx_song_hash ON songs(fileHash)")
        }
    }

    fun <T> query(sql: String, binder: Statement.() -> ResultSet = { executeQuery(sql) }, mapper: (ResultSet) -> T): List<T> {
        connection.createStatement().use { st ->
            val rs = st.executeQuery(sql)
            val list = mutableListOf<T>()
            while (rs.next()) {
                list.add(mapper(rs))
            }
            return list
        }
    }

    fun execute(sql: String) {
        connection.createStatement().use { st ->
            st.execute(sql)
        }
    }
}
