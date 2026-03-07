/*
 * Copyright 2024 SyncTune
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package com.example.synctune.library

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper

class MusicDbHelper(context: Context) : SQLiteOpenHelper(context, DATABASE_NAME, null, DATABASE_VERSION) {

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL(SQL_CREATE_ENTRIES)
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        if (oldVersion < 2) {
            db.execSQL("ALTER TABLE ${SongContract.SongEntry.TABLE_NAME} ADD COLUMN ${SongContract.SongEntry.COLUMN_NAME_IS_FAVOURITE} INTEGER DEFAULT 0")
        }
        if (oldVersion < 3) {
            db.execSQL("ALTER TABLE ${SongContract.SongEntry.TABLE_NAME} ADD COLUMN ${SongContract.SongEntry.COLUMN_NAME_FILE_NAME} TEXT")
        }
        if (oldVersion < 4) {
            db.execSQL("ALTER TABLE ${SongContract.SongEntry.TABLE_NAME} ADD COLUMN ${SongContract.SongEntry.COLUMN_NAME_FILE_HASH} TEXT")
        }
    }

    companion object {
        const val DATABASE_VERSION = 4
        const val DATABASE_NAME = "Music.db"

        private const val SQL_CREATE_ENTRIES = """
            CREATE TABLE IF NOT EXISTS ${SongContract.SongEntry.TABLE_NAME} (
                ${SongContract.SongEntry.COLUMN_NAME_ID} INTEGER PRIMARY KEY,
                ${SongContract.SongEntry.COLUMN_NAME_TITLE} TEXT,
                ${SongContract.SongEntry.COLUMN_NAME_ARTIST} TEXT,
                ${SongContract.SongEntry.COLUMN_NAME_ALBUM} TEXT,
                ${SongContract.SongEntry.COLUMN_NAME_FILE_PATH} TEXT,
                ${SongContract.SongEntry.COLUMN_NAME_FILE_NAME} TEXT,
                ${SongContract.SongEntry.COLUMN_NAME_FILE_HASH} TEXT,
                ${SongContract.SongEntry.COLUMN_NAME_MODIFIED_TIME} INTEGER,
                ${SongContract.SongEntry.COLUMN_NAME_IS_FAVOURITE} INTEGER DEFAULT 0)
            """

        private const val SQL_DELETE_ENTRIES = "DROP TABLE IF EXISTS ${SongContract.SongEntry.TABLE_NAME}"
    }
}
