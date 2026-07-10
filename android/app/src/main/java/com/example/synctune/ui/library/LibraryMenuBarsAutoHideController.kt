package com.example.synctune.ui.library

import android.transition.ChangeBounds
import android.transition.TransitionManager
import android.os.Handler
import android.os.Looper
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.ViewGroup
import android.view.ViewTreeObserver
import androidx.constraintlayout.widget.ConstraintLayout
import androidx.recyclerview.widget.RecyclerView
import com.example.synctune.R
import com.google.android.material.animation.AnimationUtils
import kotlin.math.abs

private const val MENU_BAR_ANIMATION_DURATION_MS = 200L
private const val TOUCH_SLOP_MULTIPLIER = 3

internal class LibraryMenuBarsAutoHideController(
    private val rootView: View,
    private val bottomNavigation: View,
    private val miniPlayer: View,
) {
    private val recyclerView = rootView.findViewById<RecyclerView>(R.id.recycler_view_songs)
    private val interpolator = AnimationUtils.FAST_OUT_SLOW_IN_INTERPOLATOR
    private val scrollNoiseThreshold = ViewConfiguration.get(rootView.context).scaledTouchSlop
    private val scrollTriggerDistance = scrollNoiseThreshold * TOUCH_SLOP_MULTIPLIER
    private val originalRecyclerTopMargin = (recyclerView.layoutParams as ConstraintLayout.LayoutParams).topMargin
    private val originalRecyclerBottomPadding = recyclerView.paddingBottom
    private val expandedRecyclerBottomPadding = recyclerView.paddingLeft
    private var hidden = false
    private var layoutTransitionGuard = false
    private var pendingScrollDelta = 0
    private var activeTouchScrollDirection = 0
    private var lastTouchY: Float? = null
    private var scrollListener: RecyclerView.OnScrollListener? = null
    private val touchListener = object : RecyclerView.OnItemTouchListener {
        override fun onInterceptTouchEvent(recyclerView: RecyclerView, event: MotionEvent): Boolean {
            updateTouchScrollDirection(event)
            return false
        }

        override fun onTouchEvent(recyclerView: RecyclerView, event: MotionEvent) {
            updateTouchScrollDirection(event)
        }

        override fun onRequestDisallowInterceptTouchEvent(disallowIntercept: Boolean) = Unit
    }

    fun attach() {
        val listener = object : RecyclerView.OnScrollListener() {
            override fun onScrolled(recyclerView: RecyclerView, dx: Int, dy: Int) {
                if (isScrollDeltaAlignedWithTouch(dy)) {
                    onScrollDelta(dy)
                }
            }

            override fun onScrollStateChanged(recyclerView: RecyclerView, newState: Int) {
                if (newState == RecyclerView.SCROLL_STATE_IDLE) {
                    resetScrollTracking()
                }
            }
        }
        recyclerView.addOnItemTouchListener(touchListener)
        recyclerView.addOnScrollListener(listener)
        scrollListener = listener
    }

    fun detach() {
        val listener = scrollListener ?: return
        recyclerView.removeOnScrollListener(listener)
        recyclerView.removeOnItemTouchListener(touchListener)
        scrollListener = null
    }

    fun onScrollDelta(dy: Int) {
        if (layoutTransitionGuard) return
        if (abs(dy) < scrollNoiseThreshold) return
        if (pendingScrollDelta != 0 && (pendingScrollDelta > 0) != (dy > 0)) {
            pendingScrollDelta = 0
        }

        pendingScrollDelta += dy
        when {
            pendingScrollDelta >= scrollTriggerDistance -> {
                pendingScrollDelta = 0
                setHidden(true)
            }
            pendingScrollDelta <= -scrollTriggerDistance -> {
                pendingScrollDelta = 0
                setHidden(false)
            }
        }
    }

    fun setHidden(nextHidden: Boolean) {
        if (hidden == nextHidden) return
        hidden = nextHidden

        guardLayoutTransition()
        updateSongListBounds(nextHidden)
        animateTopMenuBar(rootView.findViewById(R.id.rl_header), nextHidden)
        animateTopMenuBar(rootView.findViewById(R.id.tab_layout_library), nextHidden)
        animateTopMenuBar(rootView.findViewById(R.id.card_scan), nextHidden)
        animateBottomNavigation(bottomNavigation, nextHidden)
        animateBottomNavigation(miniPlayer, nextHidden)
    }

    private fun updateSongListBounds(hidden: Boolean) {
        (recyclerView.parent as? ViewGroup)?.let { parent ->
            TransitionManager.beginDelayedTransition(
                parent,
                ChangeBounds().apply {
                    duration = MENU_BAR_ANIMATION_DURATION_MS
                    interpolator = this@LibraryMenuBarsAutoHideController.interpolator
                },
            )
        }
        val params = recyclerView.layoutParams as ConstraintLayout.LayoutParams
        if (hidden) {
            params.topToTop = ConstraintLayout.LayoutParams.PARENT_ID
            params.topToBottom = ConstraintLayout.LayoutParams.UNSET
            params.topMargin = 0
            recyclerView.setPadding(
                recyclerView.paddingLeft,
                recyclerView.paddingTop,
                recyclerView.paddingRight,
                expandedRecyclerBottomPadding,
            )
        } else {
            params.topToTop = ConstraintLayout.LayoutParams.UNSET
            params.topToBottom = R.id.card_scan
            params.topMargin = originalRecyclerTopMargin
            recyclerView.setPadding(
                recyclerView.paddingLeft,
                recyclerView.paddingTop,
                recyclerView.paddingRight,
                originalRecyclerBottomPadding,
            )
        }
        recyclerView.layoutParams = params
    }

    private fun animateTopMenuBar(view: View, hidden: Boolean) {
        view.animate().cancel()
        view.animate()
            .translationY(if (hidden) -menuBarOffset(view) else 0f)
            .alpha(if (hidden) 0f else 1f)
            .setDuration(MENU_BAR_ANIMATION_DURATION_MS)
            .setInterpolator(interpolator)
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

    private fun updateTouchScrollDirection(event: MotionEvent) {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                activeTouchScrollDirection = 0
                lastTouchY = event.y
            }
            MotionEvent.ACTION_MOVE -> {
                val previousTouchY = lastTouchY ?: event.y
                val touchDeltaY = previousTouchY - event.y
                if (abs(touchDeltaY) >= scrollNoiseThreshold) {
                    activeTouchScrollDirection = touchDeltaY.compareTo(0f)
                }
                lastTouchY = event.y
            }
        }
    }

    private fun isScrollDeltaAlignedWithTouch(dy: Int): Boolean {
        return activeTouchScrollDirection == 0 || dy.compareTo(0) == activeTouchScrollDirection
    }

    private fun resetScrollTracking() {
        pendingScrollDelta = 0
        activeTouchScrollDirection = 0
        lastTouchY = null
    }

    private fun guardLayoutTransition() {
        layoutTransitionGuard = true
        if (!rootView.isLaidOut) {
            Handler(Looper.getMainLooper()).post { layoutTransitionGuard = false }
            return
        }

        val observer = rootView.viewTreeObserver
        observer.addOnPreDrawListener(object : ViewTreeObserver.OnPreDrawListener {
            override fun onPreDraw(): Boolean {
                if (observer.isAlive) {
                    observer.removeOnPreDrawListener(this)
                }
                layoutTransitionGuard = false
                return true
            }
        })
    }
}
