package com.example.synctune

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test

class RecoveryFolderLookupTest {
    private data class Entry(val directory: Boolean)

    @Test
    fun missingRecoveryFolderIsOrdinaryAbsenceForReadOnlyProbe() {
        var created = false
        val result = optionalRecoveryFolder(
            create = false,
            find = { null },
            createFolder = { created = true; Entry(directory = true) },
            isFolder = { it.directory },
            label = "recovery",
        )

        assertNull(result)
        assertEquals(false, created)
    }

    @Test
    fun writableProbeCreatesOnlyWhenAsked() {
        val result = optionalRecoveryFolder(
            create = true,
            find = { null },
            createFolder = { Entry(directory = true) },
            isFolder = { it.directory },
            label = "recovery",
        )

        assertEquals(Entry(directory = true), result)
    }

    @Test
    fun providerErrorsAreNotTreatedAsMissing() {
        val error = IllegalStateException("permission revoked")
        val thrown = assertThrows(IllegalStateException::class.java) {
            optionalRecoveryFolder(
                create = false,
                find = { throw error },
                createFolder = { Entry(directory = true) },
                isFolder = { it.directory },
                label = "recovery",
            )
        }

        assertEquals(error, thrown)
    }

    @Test
    fun fileAtRecoveryFolderNameIsAnError() {
        assertThrows(IllegalStateException::class.java) {
            optionalRecoveryFolder(
                create = false,
                find = { Entry(directory = false) },
                createFolder = { Entry(directory = true) },
                isFolder = { it.directory },
                label = "recovery",
            )
        }
    }
}
