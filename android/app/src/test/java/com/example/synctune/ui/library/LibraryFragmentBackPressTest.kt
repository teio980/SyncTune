package com.example.synctune.ui.library

import android.view.View
import com.example.synctune.R
import com.example.synctune.ui.MainActivity
import com.google.android.material.textfield.TextInputLayout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
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
}
