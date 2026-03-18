package com.example.synctune.ui

import android.content.ComponentName
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Bundle
import android.view.View
import android.view.animation.AnimationUtils
import android.widget.ImageButton
import android.widget.ImageView
import android.widget.TextView
import androidx.activity.enableEdgeToEdge
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
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
    
    private var controllerFuture: ListenableFuture<MediaController>? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        val rootLayout = findViewById<View>(R.id.fragment_container).parent as View
        ViewCompat.setOnApplyWindowInsetsListener(rootLayout) { v, insets ->
            val systemBars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            navView.updatePadding(bottom = systemBars.bottom)
            insets
        }

        navView = findViewById(R.id.bottom_navigation)
        initMiniPlayer()
        
        val player = PlayerManager.getPlayer(this)
        setupPlayerListener(player)

        if (savedInstanceState == null) {
            loadFragment(LibraryFragment(), false)
            triggerAutoSync()
            checkIntentForNavigation(intent)
        }

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
        
        updateMiniPlayerUI(player.currentMediaItem)
        updatePlayPauseIcon(player.isPlaying)
    }

    override fun onStart() {
        super.onStart()
        val sessionToken = SessionToken(this, ComponentName(this, PlaybackService::class.java))
        controllerFuture = MediaController.Builder(this, sessionToken).buildAsync()
        controllerFuture?.addListener({}, MoreExecutors.directExecutor())
    }

    override fun onStop() {
        super.onStop()
        controllerFuture?.let {
            MediaController.releaseFuture(it)
        }
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

        // 丝滑动画配置：进入(slide_up), 退出(no_anim), 弹出进入(no_anim), 弹出退出(slide_down)
        supportFragmentManager.beginTransaction()
            .setCustomAnimations(
                R.anim.slide_up,    // enter: 新 Fragment 进入时的动画
                R.anim.no_anim,     // exit: 旧 Fragment 退出时的动画
                R.anim.no_anim,     // popEnter: 返回时，旧 Fragment 重新进入的动画
                R.anim.slide_down   // popExit: 返回时，当前 Fragment 退出时的动画
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

    private fun initMiniPlayer() {
        miniPlayerCard = findViewById(R.id.mini_player_card)
        miniIvAlbumArt = findViewById(R.id.mini_iv_album_art)
        miniTvTitle = findViewById(R.id.mini_tv_title)
        miniTvArtistAlbum = findViewById(R.id.mini_tv_artist_album)
        miniBtnPlayPause = findViewById(R.id.mini_btn_play_pause)
        miniBtnNext = findViewById(R.id.mini_btn_next)
        miniBtnPrev = findViewById(R.id.mini_btn_prev)

        val btnClickAnim = AnimationUtils.loadAnimation(this, R.anim.btn_click)

        miniPlayerCard?.setOnClickListener {
            openNowPlayingFragment()
        }

        miniBtnPlayPause?.setOnClickListener {
            it.startAnimation(btnClickAnim)
            val player = PlayerManager.getPlayer(this)
            if (player.isPlaying) player.pause() else player.play()
        }

        miniBtnNext?.setOnClickListener {
            it.startAnimation(btnClickAnim)
            PlayerManager.getPlayer(this).seekToNext()
        }

        miniBtnPrev?.setOnClickListener {
            it.startAnimation(btnClickAnim)
            PlayerManager.getPlayer(this).seekToPrevious()
        }

        supportFragmentManager.addOnBackStackChangedListener {
            val currentFragment = supportFragmentManager.findFragmentById(R.id.fragment_container)
            setMainControlsVisibility(currentFragment !is NowPlayingFragment)
        }
    }

    private fun setupPlayerListener(player: Player) {
        player.addListener(object : Player.Listener {
            override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
                runOnUiThread { updateMiniPlayerUI(mediaItem) }
            }

            override fun onIsPlayingChanged(isPlaying: Boolean) {
                runOnUiThread { updatePlayPauseIcon(isPlaying) }
            }

            override fun onPlaybackStateChanged(playbackState: Int) {
                runOnUiThread {
                    if (playbackState == Player.STATE_IDLE || player.mediaItemCount == 0) {
                        miniPlayerCard?.visibility = View.GONE
                    } else if (playbackState == Player.STATE_READY || playbackState == Player.STATE_BUFFERING) {
                        val currentFragment = supportFragmentManager.findFragmentById(R.id.fragment_container)
                        if (currentFragment !is NowPlayingFragment) {
                            updateMiniPlayerUI(player.currentMediaItem)
                        }
                    }
                }
            }
        })
    }

    private fun updateMiniPlayerUI(mediaItem: MediaItem?) {
        val currentFragment = supportFragmentManager.findFragmentById(R.id.fragment_container)
        
        if (mediaItem == null || currentFragment is NowPlayingFragment) {
            miniPlayerCard?.visibility = View.GONE
            return
        }
        
        miniPlayerCard?.visibility = View.VISIBLE
        
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
            val dominantColor = palette?.getDominantColor(ContextCompat.getColor(this, R.color.white)) ?: ContextCompat.getColor(this, R.color.white)
            miniPlayerCard?.setCardBackgroundColor(dominantColor)
            
            val textColor = if (isColorDark(dominantColor)) 
                ContextCompat.getColor(this, R.color.white) 
            else 
                ContextCompat.getColor(this, R.color.black)
            
            miniTvTitle?.setTextColor(textColor)
            miniTvArtistAlbum?.setTextColor(textColor)
            miniBtnPlayPause?.setColorFilter(textColor)
            miniBtnNext?.setColorFilter(textColor)
            miniBtnPrev?.setColorFilter(textColor)
        }
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

    private fun setMainControlsVisibility(visible: Boolean) {
        val visibility = if (visible) View.VISIBLE else View.GONE
        navView.visibility = visibility
        
        val player = PlayerManager.getPlayer(this)
        if (visible) {
            updateMiniPlayerUI(player.currentMediaItem)
        } else {
            miniPlayerCard?.visibility = View.GONE
        }
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
        PlayerManager.releasePlayer()
    }
}
