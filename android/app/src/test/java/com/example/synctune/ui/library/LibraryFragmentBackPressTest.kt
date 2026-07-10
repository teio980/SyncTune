package com.example.synctune.ui.library

import android.view.View
import androidx.recyclerview.widget.RecyclerView
import com.example.synctune.R
import com.example.synctune.ui.MainActivity
import com.google.android.material.textfield.TextInputLayout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class LibraryFragmentBackPressTest {
    @Test
    fun backPressClosesSearchWithoutFinishingActivity() {
        val controller = Robolectric.buildActivity(MainActivity::class.java).setup()
        val activity = controller.get()

        activity.findViewById<View>(R.id.btn_search).performClick()

        val searchLayout = activity.findViewById<TextInputLayout>(R.id.til_search)
        assertEquals(View.VISIBLE, searchLayout.visibility)

        activity.onBackPressedDispatcher.onBackPressed()

        assertFalse(activity.isFinishing)
        assertEquals(View.GONE, searchLayout.visibility)
    }

    @Test
    fun backPressExitsSelectionModeWithoutFinishingActivity() {
        val controller = Robolectric.buildActivity(MainActivity::class.java).setup()
        val activity = controller.get()

        val recyclerView = activity.findViewById<RecyclerView>(R.id.recycler_view_songs)
        val songAdapter = recyclerView.adapter as SongAdapter
        songAdapter.setSelectionMode(true)

        assertTrue(songAdapter.isSelectionModeEnabled())

        activity.onBackPressedDispatcher.onBackPressed()

        assertFalse(songAdapter.isSelectionModeEnabled())
        assertFalse(activity.isFinishing)
    }
}
