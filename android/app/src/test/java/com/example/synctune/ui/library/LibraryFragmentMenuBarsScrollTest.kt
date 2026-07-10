package com.example.synctune.ui.library

import android.os.Looper
import android.view.LayoutInflater
import android.view.View
import android.view.ContextThemeWrapper
import androidx.constraintlayout.widget.ConstraintLayout
import androidx.recyclerview.widget.RecyclerView
import com.example.synctune.R
import com.google.android.material.bottomnavigation.BottomNavigationView
import com.google.android.material.tabs.TabLayout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import java.util.concurrent.TimeUnit

@RunWith(RobolectricTestRunner::class)
class LibraryFragmentMenuBarsScrollTest {
    @Test
    fun hidingMenuBarsIncludesScanCardAndMovesMiniPlayerDown() {
        val views = createMenuBarsTestViews()
        val initialMiniPlayerTranslationY = views.miniPlayer.translationY

        views.header.minimumHeight = 1
        views.tabs.minimumHeight = 1
        views.scanCard.minimumHeight = 1
        views.bottomNavigation.minimumHeight = 1

        views.controller.setHidden(true)
        waitForAnimation()

        assertTrue(views.header.translationY < 0f)
        assertTrue(views.tabs.translationY < 0f)
        assertTrue(views.scanCard.translationY < 0f)
        assertTrue(views.bottomNavigation.translationY > 0f)
        assertTrue(views.miniPlayer.translationY > initialMiniPlayerTranslationY)
    }

    @Test
    fun hidingMenuBarsExpandsSongListToParentBounds() {
        val views = createMenuBarsTestViews()
        val originalPaddingBottom = views.songs.paddingBottom

        views.controller.setHidden(true)
        val hiddenParams = views.songs.layoutParams as ConstraintLayout.LayoutParams
        assertEquals(ConstraintLayout.LayoutParams.PARENT_ID, hiddenParams.topToTop)
        assertEquals(ConstraintLayout.LayoutParams.UNSET, hiddenParams.topToBottom)
        assertTrue(views.songs.paddingBottom < originalPaddingBottom)

        views.controller.setHidden(false)
        val shownParams = views.songs.layoutParams as ConstraintLayout.LayoutParams
        assertEquals(R.id.card_scan, shownParams.topToBottom)
        assertEquals(ConstraintLayout.LayoutParams.UNSET, shownParams.topToTop)
        assertEquals(originalPaddingBottom, views.songs.paddingBottom)
    }

    @Test
    fun tinyAlternatingScrollDeltasDoNotToggleMenuBars() {
        val views = createMenuBarsTestViews()

        repeat(6) {
            views.controller.onScrollDelta(7)
            views.controller.onScrollDelta(-7)
        }
        waitForAnimation()

        assertEquals(0f, views.header.translationY)
        assertEquals(0f, views.tabs.translationY)
        assertEquals(0f, views.scanCard.translationY)
        assertEquals(0f, views.bottomNavigation.translationY)
        assertEquals(0f, views.miniPlayer.translationY)
    }

    @Test
    fun repeatedTinyScrollNoiseDoesNotAccumulateIntoMenuToggle() {
        val views = createMenuBarsTestViews()

        repeat(40) { views.controller.onScrollDelta(7) }
        waitForAnimation()

        assertEquals(0f, views.header.translationY)
        assertEquals(0f, views.tabs.translationY)
        assertEquals(0f, views.scanCard.translationY)
        assertEquals(0f, views.bottomNavigation.translationY)
        assertEquals(0f, views.miniPlayer.translationY)
    }

    @Test
    fun scrollUpDuringHideAnimationReturnsSongListToShownBounds() {
        val views = createMenuBarsTestViews()

        views.controller.onScrollDelta(1_000)
        waitForAnimation()
        views.controller.onScrollDelta(-1_000)
        waitForAnimation()

        val params = views.songs.layoutParams as ConstraintLayout.LayoutParams
        assertEquals(ConstraintLayout.LayoutParams.UNSET, params.topToTop)
        assertEquals(R.id.card_scan, params.topToBottom)
    }

    @Test
    fun layoutMutationDoesNotReverseMenuBarsFromAnImmediateScrollCallback() {
        val views = createMenuBarsTestViews()

        views.controller.setHidden(true)
        views.controller.onScrollDelta(-1_000)
        waitForAnimation()

        val params = views.songs.layoutParams as ConstraintLayout.LayoutParams
        assertEquals(ConstraintLayout.LayoutParams.PARENT_ID, params.topToTop)
        assertEquals(ConstraintLayout.LayoutParams.UNSET, params.topToBottom)
    }

    private fun createMenuBarsTestViews(): MenuBarsTestViews {
        val context = ContextThemeWrapper(RuntimeEnvironment.getApplication(), R.style.Theme_SyncTune)
        val rootView = LayoutInflater.from(context).inflate(R.layout.fragment_library, null)
        val bottomNavigation = BottomNavigationView(context).apply { minimumHeight = 1 }
        val miniPlayer = View(context).apply { minimumHeight = 1 }
        val songs = rootView.findViewById<RecyclerView>(R.id.recycler_view_songs)

        return MenuBarsTestViews(
            controller = LibraryMenuBarsAutoHideController(rootView, bottomNavigation, miniPlayer),
            header = rootView.findViewById(R.id.rl_header),
            tabs = rootView.findViewById(R.id.tab_layout_library),
            scanCard = rootView.findViewById(R.id.card_scan),
            bottomNavigation = bottomNavigation,
            miniPlayer = miniPlayer,
            songs = songs,
        )
    }

    private fun waitForAnimation() {
        shadowOf(Looper.getMainLooper()).idleFor(200, TimeUnit.MILLISECONDS)
    }

    private data class MenuBarsTestViews(
        val controller: LibraryMenuBarsAutoHideController,
        val header: View,
        val tabs: TabLayout,
        val scanCard: View,
        val bottomNavigation: BottomNavigationView,
        val miniPlayer: View,
        val songs: RecyclerView,
    )
}
