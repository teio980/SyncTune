package com.example.synctune.ui

import android.content.ComponentName
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.GradientDrawable
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import android.view.View
import android.view.animation.AnimationUtils
import android.widget.ImageButton
import android.widget.ImageView
import android.widget.TextView
import androidx.activity.enableEdgeToEdge
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.updatePadding
import androidx.fragment.app.Fragment
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import androidx.palette.graphics.Palette
import androidx.work.*
import com.example.synctune.R
import com.example.synctune.library.PlaybackCacheHelper
import com.example.synctune.library.SongDao
import com.example.synctune.player.PlaybackService
import com.example.synctune.player.PlayerManager
import com.example.synctune.sync.SyncManager
import com.example.synctune.sync.SyncWorker
import com.example.synctune.ui.library.LibraryFragment
import com.example.synctune.ui.nowplaying.NowPlayingFragment
import com.example.synctune.ui.settings.SettingsFragment
import com.example.synctune.ui.sync.SyncFragment
import com.google.android.material.bottomnavigation.BottomNavigationView
import com.google.android.material.card.MaterialCardView
import com.google.android.material.progressindicator.LinearProgressIndicator
import com.google.common.util.concurrent.ListenableFuture
import com.google.common.util.concurrent.MoreExecutors

class MainActivity : AppCompatActivity() {

    private lateinit var navView: BottomNavigationView
    private var miniPlayerCard: MaterialCardView? = null
    private var miniIvAlbumArt: ImageView? = null
    private var miniTvTitle: TextView? = null
    private var miniTvArtistAlbum: TextView? = null
    private var miniBtnPlayPause: ImageButton? = null
    private var miniBtnNext: ImageButton? = null
    private var miniBtnPrev: ImageButton? = null
    private var miniProgressBar: LinearProgressIndicator? = null
    private var miniBackgroundGradient: View? = null
    
    private var controllerFuture: ListenableFuture<MediaController>? = null
    private var observedPlayer: Player? = null
    private var shouldRestorePlayback = false
    private lateinit var songDao: SongDao

    private val handler = Handler(Looper.getMainLooper())
    private val updateProgressAction = object : Runnable {
        override fun run() {
            updateMiniProgress()
            handler.postDelayed(this, 1000)
        }
    }
    private val miniPlayerListener = object : Player.Listener {
        override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
            runOnUiThread { updateMiniPlayerUI(mediaItem) }
        }

        override fun onIsPlayingChanged(isPlaying: Boolean) {
            runOnUiThread {
                updatePlayPauseIcon(isPlaying)
                if (isPlaying) {
                    handler.removeCallbacks(updateProgressAction)
                    handler.post(updateProgressAction)
                } else {
                    handler.removeCallbacks(updateProgressAction)
                }
            }
        }

        override fun onPlaybackStateChanged(playbackState: Int) {
            runOnUiThread { updateMiniPlayerVisibility() }
        }

        override fun onEvents(player: Player, events: Player.Events) {
            runOnUiThread { updateMiniPlayerVisibility() }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        // 1. 基础组件初始化
        songDao = SongDao(this)

        // 2. 核心 View 初始化 (必须在设置监听器之前)
        navView = findViewById(R.id.bottom_navigation)
        initMiniPlayer()

        // 3. 安全地设置 Window Insets
        ViewCompat.setOnApplyWindowInsetsListener(findViewById(android.R.id.content)) { _, insets ->
            val systemBars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            if (::navView.isInitialized) {
                navView.updatePadding(bottom = systemBars.bottom)
            }
            insets
        }

        // Must create notification channels before starting foreground service.
        createNotificationChannels()

        if (savedInstanceState == null) {
            loadFragment(LibraryFragment(), false)
            triggerAutoSync()
            checkIntentForNavigation(intent)
            shouldRestorePlayback = true
        }

        requestNotificationPermission()

        navView.setOnItemSelectedListener { item ->
            val btnClickAnim = AnimationUtils.loadAnimation(this, R.anim.btn_click)
            navView.findViewById<View>(item.itemId)?.startAnimation(btnClickAnim)

            when (item.itemId) {
                R.id.navigation_library -> {
                    loadFragment(LibraryFragment())
                    true
                }
                R.id.navigation_sync -> {
                    loadFragment(SyncFragment())
                    true
                }
                R.id.navigation_settings -> {
                    loadFragment(SettingsFragment())
                    true
                }
                else -> false
            }
        }
    }

    private fun createNotificationChannels() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            // Media3 媒体播放通知渠道（MediaSessionService 使用此 ID）
            val mediaChannel = NotificationChannel(
                "default_notification_channel",
                "Playback",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Media playback controls"
                setShowBadge(false)
            }
            // SyncWorker 使用的同步通知渠道
            val syncChannel = NotificationChannel(
                "sync_channel",
                "Sync",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Background sync progress"
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(mediaChannel)
            manager.createNotificationChannel(syncChannel)
        }
    }

    private fun requestNotificationPermission() {
        // Android 13+ 需要运行时请求 POST_NOTIFICATIONS 才能显示前台服务通知
        if (Build.VERSION.SDK_INT >= 33) {
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS)
                != PackageManager.PERMISSION_GRANTED
            ) {
                ActivityCompat.requestPermissions(
                    this,
                    arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                    1001
                )
            }
        }
    }

    override fun onStart() {
        super.onStart()
        val sessionToken = SessionToken(this, ComponentName(this, PlaybackService::class.java))
        controllerFuture = MediaController.Builder(this, sessionToken).buildAsync()
        controllerFuture?.addListener({
            try {
                val controller = controllerFuture?.get()
                controller?.let {
                    PlayerManager.setController(it)
                    setupPlayerListener(it)
                    if (shouldRestorePlayback) {
                        restorePlaybackIfNeeded()
                        shouldRestorePlayback = false
                    }
                }
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }, MoreExecutors.directExecutor())
        
        if (activePlayer()?.isPlaying == true) {
            handler.post(updateProgressAction)
        }
    }

    override fun onStop() {
        super.onStop()
        controllerFuture?.let {
            MediaController.releaseFuture(it)
        }
        observedPlayer?.removeListener(miniPlayerListener)
        observedPlayer = null
        PlayerManager.setController(null)
        handler.removeCallbacks(updateProgressAction)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        checkIntentForNavigation(intent)
    }

    private fun checkIntentForNavigation(intent: Intent?) {
        if (intent?.getBooleanExtra("open_now_playing", false) == true) {
            openNowPlayingFragment()
        }
    }

    private fun openNowPlayingFragment() {
        val currentFragment = supportFragmentManager.findFragmentById(R.id.fragment_container)
        if (currentFragment is NowPlayingFragment) return

        supportFragmentManager.beginTransaction()
            .setCustomAnimations(
                R.anim.slide_up,
                R.anim.no_anim,
                R.anim.no_anim,
                R.anim.slide_down
            )
            .replace(R.id.fragment_container, NowPlayingFragment())
            .addToBackStack("now_playing")
            .commit()
    }

    private fun triggerAutoSync() {
        val syncManager = SyncManager(this)
        if (syncManager.isAutoSyncEnabled() && syncManager.isWebDAVConfigured()) {
            val constraints = Constraints.Builder()
                .setRequiredNetworkType(NetworkType.CONNECTED)
                .build()

            val syncRequest = OneTimeWorkRequestBuilder<SyncWorker>()
                .setConstraints(constraints)
                .setInputData(workDataOf("sync_type" to "TWO_WAY"))
                .addTag("auto_sync_on_launch")
                .build()

            WorkManager.getInstance(this).enqueueUniqueWork(
                "auto_sync_on_launch",
                ExistingWorkPolicy.REPLACE,
                syncRequest
            )
        }
    }

    private fun restorePlaybackIfNeeded() {
        try {
            val cache = PlaybackCacheHelper(this).getCache() ?: return
            val song = songDao.getSongByHash(cache.songHash) ?: return

            PlayerManager.restoreFromCache(
                song,
                cache.position,
                cache.repeatMode,
                cache.shuffleMode
            )
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    private fun initMiniPlayer() {
        miniPlayerCard = findViewById(R.id.mini_player_card)
        miniIvAlbumArt = findViewById(R.id.mini_iv_album_art)
        miniTvTitle = findViewById(R.id.mini_tv_title)
        miniTvArtistAlbum = findViewById(R.id.mini_tv_artist_album)
        miniBtnPlayPause = findViewById(R.id.mini_btn_play_pause)
        miniBtnNext = findViewById(R.id.mini_btn_next)
        miniBtnPrev = findViewById(R.id.mini_btn_prev)
        miniProgressBar = findViewById(R.id.mini_progress_bar)
        miniBackgroundGradient = findViewById(R.id.mini_background_gradient)

        val btnClickAnim = AnimationUtils.loadAnimation(this, R.anim.btn_click)

        miniPlayerCard?.setOnClickListener {
            openNowPlayingFragment()
        }

        miniBtnPlayPause?.setOnClickListener {
            it.startAnimation(btnClickAnim)
            val player = activePlayer() ?: return@setOnClickListener
            if (player.isPlaying) player.pause() else player.play()
        }

        miniBtnNext?.setOnClickListener {
            it.startAnimation(btnClickAnim)
            activePlayer()?.seekToNext()
        }

        miniBtnPrev?.setOnClickListener {
            it.startAnimation(btnClickAnim)
            activePlayer()?.seekToPrevious()
        }

        supportFragmentManager.addOnBackStackChangedListener {
            updateMiniPlayerVisibility()
        }
    }

    private fun setupPlayerListener(player: Player) {
        observedPlayer?.removeListener(miniPlayerListener)
        observedPlayer = player
        player.addListener(miniPlayerListener)
        
        runOnUiThread {
            updateMiniPlayerUI(player.currentMediaItem)
            updatePlayPauseIcon(player.isPlaying)
            updateMiniPlayerVisibility()
            if (player.isPlaying) handler.post(updateProgressAction)
        }
    }

    private fun updateMiniPlayerVisibility() {
        val currentFragment = supportFragmentManager.findFragmentById(R.id.fragment_container)
        val player = activePlayer()
        if (player == null) {
            miniPlayerCard?.visibility = View.GONE
            navView.visibility = if (currentFragment !is NowPlayingFragment) View.VISIBLE else View.GONE
            return
        }
        
        val hasMedia = player.mediaItemCount > 0
        val isNotIdle = player.playbackState != Player.STATE_IDLE
        val notInNowPlaying = currentFragment !is NowPlayingFragment
        
        val shouldShow = notInNowPlaying && hasMedia && isNotIdle
        
        miniPlayerCard?.visibility = if (shouldShow) View.VISIBLE else View.GONE
        navView.visibility = if (notInNowPlaying) View.VISIBLE else View.GONE
        
        if (shouldShow) {
            updateMiniPlayerUI(player.currentMediaItem)
            updateMiniProgress()
        }
    }

    private fun updateMiniPlayerUI(mediaItem: MediaItem?) {
        if (mediaItem == null) return

        val metadata = mediaItem.mediaMetadata
        miniTvTitle?.text = metadata.title ?: "Unknown Title"
        miniTvArtistAlbum?.text = "${metadata.artist ?: "Unknown Artist"} - ${metadata.albumTitle ?: "Unknown Album"}"

        val bitmap = getAlbumArt(mediaItem) ?: getDefaultBitmap()
        miniIvAlbumArt?.setImageBitmap(bitmap)
        updateMiniPlayerBackground(bitmap)
    }

    private fun updatePlayPauseIcon(isPlaying: Boolean) {
        miniBtnPlayPause?.setImageResource(if (isPlaying) R.drawable.ic_pause else R.drawable.ic_play)
    }

    private fun updateMiniPlayerBackground(bitmap: Bitmap) {
        Palette.from(bitmap).generate { palette ->
            val dominantColor = palette?.getDominantColor(ContextCompat.getColor(this, R.color.black)) ?: 0
            val darkMutedColor = palette?.getDarkMutedColor(ContextCompat.getColor(this, R.color.black)) ?: 0
            
            val gradient = GradientDrawable(
                GradientDrawable.Orientation.TOP_BOTTOM,
                intArrayOf(dominantColor, darkMutedColor, ContextCompat.getColor(this, R.color.black))
            )
            gradient.cornerRadius = 16f * resources.displayMetrics.density
            miniBackgroundGradient?.background = gradient

            val textColor = if (isColorDark(dominantColor))
                ContextCompat.getColor(this, R.color.white)
            else
                ContextCompat.getColor(this, R.color.black)

            miniTvTitle?.setTextColor(textColor)
            miniTvArtistAlbum?.setTextColor(if (isColorDark(dominantColor)) 0xFFCCCCCC.toInt() else 0xFF666666.toInt())
            miniBtnPlayPause?.setColorFilter(textColor)
            miniBtnNext?.setColorFilter(textColor)
            miniBtnPrev?.setColorFilter(textColor)
            
            miniProgressBar?.setIndicatorColor(ContextCompat.getColor(this, R.color.white))
            miniProgressBar?.setTrackColor(0x33FFFFFF)
        }
    }

    private fun updateMiniProgress() {
        val player = activePlayer() ?: return
        if (player.duration > 0) {
            miniProgressBar?.max = player.duration.toInt()
            miniProgressBar?.progress = player.currentPosition.toInt()
        }
    }

    private fun activePlayer(): Player? {
        return PlayerManager.getController() ?: PlayerManager.getPlayer()
    }

    private fun isColorDark(color: Int): Boolean {
        val darkness = 1 - (0.299 * android.graphics.Color.red(color) + 0.587 * android.graphics.Color.green(color) + 0.114 * android.graphics.Color.blue(color)) / 255
        return darkness >= 0.5
    }

    private fun getAlbumArt(mediaItem: MediaItem): Bitmap? {
        val retriever = MediaMetadataRetriever()
        return try {
            val path = mediaItem.localConfiguration?.uri.toString()
            val uri = Uri.parse(path)
            if (path.startsWith("content://")) {
                contentResolver.openFileDescriptor(uri, "r")?.use { pfd ->
                    retriever.setDataSource(pfd.fileDescriptor)
                }
            } else {
                retriever.setDataSource(path)
            }
            val art = retriever.embeddedPicture
            if (art != null) BitmapFactory.decodeByteArray(art, 0, art.size) else null
        } catch (e: Exception) {
            null
        } finally {
            retriever.release()
        }
    }

    private fun getDefaultBitmap(): Bitmap {
        val drawable = ContextCompat.getDrawable(this, R.drawable.default_album_art)
        if (drawable is BitmapDrawable) return drawable.bitmap
        val bitmap = Bitmap.createBitmap(500, 500, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        drawable?.setBounds(0, 0, canvas.width, canvas.height)
        drawable?.draw(canvas)
        return bitmap
    }

    private fun loadFragment(fragment: Fragment, animate: Boolean = true) {
        val transaction = supportFragmentManager.beginTransaction()
        if (animate) {
            transaction.setCustomAnimations(android.R.anim.fade_in, android.R.anim.fade_out)
        }
        transaction.replace(R.id.fragment_container, fragment)
        transaction.commit()
    }

    override fun onDestroy() {
        super.onDestroy()
        handler.removeCallbacks(updateProgressAction)
        observedPlayer?.removeListener(miniPlayerListener)
        observedPlayer = null
        // Player 生命周期由 PlaybackService 管理
        // 不在 Activity.onDestroy() 中释放，保证播放器在后台划掉时仍能继续播放
    }
}
