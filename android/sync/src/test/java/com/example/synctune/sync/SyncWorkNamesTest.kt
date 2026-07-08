package com.example.synctune.sync

import org.junit.Assert.assertEquals
import org.junit.Test

class SyncWorkNamesTest {
    @Test
    fun syncNowAndProgressObserverUseSameUniqueWorkName() {
        assertEquals("music_sync", SyncManager.UNIQUE_SYNC_WORK_NAME)
    }
}
