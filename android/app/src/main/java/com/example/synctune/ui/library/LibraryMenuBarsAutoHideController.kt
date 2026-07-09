package com.example.synctune.ui.library

import android.view.View
import android.view.animation.DecelerateInterpolator
import androidx.recyclerview.widget.RecyclerView
import com.example.synctune.R

private const val SCROLL_HIDE_THRESHOLD = 6
private const val MENU_BAR_ANIMATION_DURATION_MS = 180L

internal class LibraryMenuBarsAutoHideController(
    private val rootView: View,
    private val bottomNavigation: View,
    private val miniPlayer: View,
) {
    private val interpolator = DecelerateInterpolator()
    private var hidden = false
    private var scrollListener: RecyclerView.OnScrollListener? = null

    fun attach() {
        val recyclerView = rootView.findViewById<RecyclerView>(R.id.recycler_view_songs)
        val listener = object : RecyclerView.OnScrollListener() {
            override fun onScrolled(recyclerView: RecyclerView, dx: Int, dy: Int) {
                when {
                    dy > SCROLL_HIDE_THRESHOLD -> setHidden(true)
                    dy < -SCROLL_HIDE_THRESHOLD -> setHidden(false)
                }
            }
        }
        recyclerView.addOnScrollListener(listener)
        scrollListener = listener
    }

    fun detach() {
        val listener = scrollListener ?: return
        rootView.findViewById<RecyclerView>(R.id.recycler_view_songs).removeOnScrollListener(listener)
        scrollListener = null
    }

    fun setHidden(nextHidden: Boolean) {
        if (hidden == nextHidden) return
        hidden = nextHidden

        animateTopMenuBar(rootView.findViewById(R.id.rl_header), nextHidden)
        animateTopMenuBar(rootView.findViewById(R.id.tab_layout_library), nextHidden)
        animateTopMenuBar(rootView.findViewById(R.id.card_scan), nextHidden)
        animateBottomNavigation(bottomNavigation, nextHidden)
        animateBottomNavigation(miniPlayer, nextHidden)
    }

    private fun animateTopMenuBar(view: View, hidden: Boolean) {
        view.animate().cancel()
        if (!hidden) {
            view.visibility = View.VISIBLE
            view.translationY = -menuBarOffset(view)
            view.alpha = 0f
        }

        view.animate()
            .translationY(if (hidden) -menuBarOffset(view) else 0f)
            .alpha(if (hidden) 0f else 1f)
            .setDuration(MENU_BAR_ANIMATION_DURATION_MS)
            .setInterpolator(interpolator)
            .withEndAction { if (hidden) view.visibility = View.GONE }
            .start()
    }

    private fun animateBottomNavigation(view: View, hidden: Boolean) {
        view.animate().cancel()
        view.animate()
            .translationY(if (hidden) menuBarOffset(view) else 0f)
            .alpha(if (hidden) 0f else 1f)
            .setDuration(MENU_BAR_ANIMATION_DURATION_MS)
            .setInterpolator(interpolator)
            .start()
    }

    private fun menuBarOffset(view: View): Float {
        return view.height.coerceAtLeast(view.minimumHeight).toFloat()
    }
}
