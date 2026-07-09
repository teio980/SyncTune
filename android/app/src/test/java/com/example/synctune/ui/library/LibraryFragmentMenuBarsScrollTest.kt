package com.example.synctune.ui.library

import android.view.View
import com.example.synctune.R
import com.example.synctune.ui.MainActivity
import com.google.android.material.bottomnavigation.BottomNavigationView
import com.google.android.material.tabs.TabLayout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import java.util.concurrent.TimeUnit

@RunWith(RobolectricTestRunner::class)
class LibraryFragmentMenuBarsScrollTest {
    @Test
    fun hidingMenuBarsIncludesScanCardAndMovesMiniPlayerDown() {
        val activityController = Robolectric.buildActivity(MainActivity::class.java).setup()
        val activity = activityController.get()

        val header = activity.findViewById<View>(R.id.rl_header)
        val tabs = activity.findViewById<TabLayout>(R.id.tab_layout_library)
        val scanCard = activity.findViewById<View>(R.id.card_scan)
        val bottomNavigation = activity.findViewById<BottomNavigationView>(R.id.bottom_navigation)
        val miniPlayer = activity.findViewById<View>(R.id.mini_player_card)
        val initialMiniPlayerTranslationY = miniPlayer.translationY

        header.minimumHeight = 1
        tabs.minimumHeight = 1
        scanCard.minimumHeight = 1
        bottomNavigation.minimumHeight = 1

        val menuBarsController = LibraryMenuBarsAutoHideController(
            activity.findViewById(R.id.fragment_container),
            bottomNavigation,
            miniPlayer,
        )
        menuBarsController.setHidden(true)
        shadowOf(activity.mainLooper).idleFor(200, TimeUnit.MILLISECONDS)

        assertTrue(header.translationY < 0f)
        assertTrue(tabs.translationY < 0f)
        assertTrue(scanCard.translationY < 0f)
        assertTrue(bottomNavigation.translationY > 0f)
        assertTrue(miniPlayer.translationY > initialMiniPlayerTranslationY)
    }
}
