package com.synctune.app

import androidx.compose.animation.*
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.application
import com.synctune.core.database.DatabaseManager
import com.synctune.core.database.SongDao
import com.synctune.core.settings.SettingsManager
import com.synctune.core.sync.SyncManager
import com.synctune.core.sync.SyncWorker
import com.synctune.core.sync.WebDavClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.text.SimpleDateFormat
import java.util.*
import javax.swing.JFileChooser

// Android Colors
val Purple200 = Color(0xFFBB86FC)
val Purple500 = Color(0xFF6200EE)
val Purple700 = Color(0xFF3700B3)
val Teal200 = Color(0xFF03DAC5)
val BackgroundColor = Color(0xFF121212)
val SurfaceColor = Color(0xFF1E1E1E)

@Composable
fun App() {
    val appDir = remember { File(System.getProperty("user.home"), ".synctune").apply { if (!exists()) mkdirs() } }
    val dbManager = remember { DatabaseManager(File(appDir, "synctune.db")) }
    val settingsManager = remember { SettingsManager(File(appDir, "settings.json")).apply { loadSettings() } }
    val songDao = remember { SongDao(dbManager) }
    val syncManager = remember { SyncManager(songDao, settingsManager) }

    var songCount by remember { mutableStateOf(syncManager.getLastSyncTime()) } // Placeholder for update logic

    // Sync state
    var syncStats by remember { mutableStateOf<SyncWorker.SyncStats?>(null) }
    var isSyncing by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) {
        if (syncManager.isAutoSyncEnabled() && syncManager.isWebDavConfigured()) {
            isSyncing = true
            syncManager.performSync("TWO_WAY", { stats -> syncStats = stats }) { finalStats ->
                isSyncing = false
                syncStats = finalStats
            }
        }
    }

    MaterialTheme(colors = darkColors(primary = Purple500, background = BackgroundColor, surface = SurfaceColor)) {
        Surface(modifier = Modifier.fillMaxSize(), color = BackgroundColor) {
            Row(Modifier.fillMaxSize()) {
                // Sidebar
                Column(Modifier.width(240.dp).fillMaxHeight().background(Color(0xFF0A0A0A)).padding(16.dp)) {
                    Text("SyncTune Sync Tool", color = Color.White, fontSize = 20.sp, fontWeight = FontWeight.Bold)
                    Spacer(Modifier.height(32.dp))
                    SyncActionsPanel(isSyncing) { type ->
                        isSyncing = true
                        syncManager.performSync(type, { stats -> syncStats = stats }) { finalStats ->
                            isSyncing = false
                            syncStats = finalStats
                        }
                    }
                    Spacer(Modifier.height(16.dp))
                    
                    val currentStats = syncStats
                    if (isSyncing || (currentStats != null && currentStats.isCompleted)) {
                        ProgressPanel(currentStats)
                    }
                }

                // Main Content
                SettingsPanel(settingsManager, syncManager)
            }
        }
    }
}

@Composable
fun SyncActionsPanel(isSyncing: Boolean, onSync: (String) -> Unit) {
    Column {
        Text("ACTIONS", color = Purple200, fontWeight = FontWeight.Bold, modifier = Modifier.padding(bottom = 8.dp))
        SyncActionButton("Upload", Icons.Default.CloudUpload, isSyncing, onClick = { onSync("UPLOAD") })
        Spacer(Modifier.height(8.dp))
        SyncActionButton("Download", Icons.Default.CloudDownload, isSyncing, onClick = { onSync("DOWNLOAD") })
        Spacer(Modifier.height(8.dp))
        SyncActionButton("Two-Way Sync", Icons.Default.Sync, isSyncing, onClick = { onSync("TWO_WAY") })
    }
}

@Composable
fun SyncActionButton(label: String, icon: androidx.compose.ui.graphics.vector.ImageVector, isSyncing: Boolean, onClick: () -> Unit) {
    Button(
        onClick = onClick, enabled = !isSyncing,
        modifier = Modifier.fillMaxWidth().height(48.dp),
        colors = ButtonDefaults.buttonColors(backgroundColor = SurfaceColor),
        shape = RoundedCornerShape(8.dp)
    ) {
        Icon(icon, null, tint = Color.White)
        Spacer(Modifier.width(12.dp))
        Text(label, color = Color.White)
    }
}

@Composable
fun ProgressPanel(stats: SyncWorker.SyncStats?) {
    val currentStats = stats ?: return
    Card(backgroundColor = SurfaceColor, shape = RoundedCornerShape(12.dp), modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp)) {
            Text(currentStats.stepMessage, color = Color.White, fontWeight = FontWeight.Bold)
            if (!currentStats.isCompleted) {
                Spacer(Modifier.height(8.dp))
                Text(currentStats.fileName, color = Color.Gray, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Spacer(Modifier.height(12.dp))
                LinearProgressIndicator(
                    progress = if (currentStats.total > 0) currentStats.current.toFloat() / currentStats.total else 0f,
                    modifier = Modifier.fillMaxWidth(), color = Purple500
                )
                Text("${currentStats.current}/${currentStats.total}", color = Color.Gray, fontSize = 12.sp, modifier = Modifier.align(Alignment.End).padding(top = 4.dp))
            } else {
                Spacer(Modifier.height(8.dp))
                Text("Result: ${currentStats.uploaded} uploaded, ${currentStats.downloaded} downloaded.", color = Color.Gray, fontSize = 14.sp)
            }
        }
    }
}

@Composable
fun SettingsPanel(settingsManager: SettingsManager, syncManager: SyncManager) {
    var url by remember { mutableStateOf(settingsManager.getWebDav().first) }
    var user by remember { mutableStateOf(settingsManager.getWebDav().second) }
    var pass by remember { mutableStateOf(settingsManager.getWebDav().third) }
    
    val scope = rememberCoroutineScope()
    val snackbarHostState = remember { SnackbarHostState() }
    var isTesting by remember { mutableStateOf(false) }
    var testSuccess by remember { mutableStateOf(false) }

    Box(Modifier.fillMaxSize()) {
        Column(Modifier.verticalScroll(rememberScrollState()).padding(24.dp)) {
            Text("Configuration", fontSize = 28.sp, fontWeight = FontWeight.Bold, color = Color.White)
            
            // WebDAV Card
            Spacer(Modifier.height(24.dp))
            Text("WebDAV Server", color = Purple200, fontWeight = FontWeight.Bold)
            Card(backgroundColor = SurfaceColor, shape = RoundedCornerShape(12.dp), modifier = Modifier.fillMaxWidth().padding(top = 8.dp)) {
                Column(Modifier.padding(16.dp)) {
                    OutlinedTextField(value = url, onValueChange = { url = it; testSuccess = false }, label = { Text("URL") }, modifier = Modifier.fillMaxWidth())
                    Spacer(Modifier.height(12.dp))
                    OutlinedTextField(value = user, onValueChange = { user = it; testSuccess = false }, label = { Text("Username") }, modifier = Modifier.fillMaxWidth())
                    Spacer(Modifier.height(12.dp))
                    OutlinedTextField(value = pass, onValueChange = { pass = it; testSuccess = false }, label = { Text("Password") }, modifier = Modifier.fillMaxWidth())
                    Spacer(Modifier.height(16.dp))
                    Row(Modifier.fillMaxWidth()) {
                        Button(onClick = {
                            scope.launch {
                                isTesting = true
                                val result = withContext(Dispatchers.IO) { WebDavClient(url, user, pass).testConnection() }
                                isTesting = false
                                if (result.isSuccess) {
                                    testSuccess = true
                                    snackbarHostState.showSnackbar("Connection successful!")
                                } else {
                                    snackbarHostState.showSnackbar("Failed: ${result.exceptionOrNull()?.message}")
                                }
                            }
                        }, enabled = !isTesting, modifier = Modifier.weight(1f).height(48.dp)) {
                            if (isTesting) CircularProgressIndicator(Modifier.size(24.dp)) else Text("Test")
                        }
                        Spacer(Modifier.width(12.dp))
                        Button(onClick = { settingsManager.setWebDav(url, user, pass) }, enabled = testSuccess, modifier = Modifier.weight(1f).height(48.dp)) { Text("Save") }
                    }
                }
            }

            // Folders Card
            Spacer(Modifier.height(32.dp))
            Text("Local Music Directories", color = Purple200, fontWeight = FontWeight.Bold)
            Card(backgroundColor = SurfaceColor, shape = RoundedCornerShape(12.dp), modifier = Modifier.fillMaxWidth().padding(top = 8.dp)) {
                Column(Modifier.padding(16.dp)) {
                    settingsManager.getMusicFolders().forEach {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Default.Folder, null, tint = Color.Gray, modifier = Modifier.size(20.dp))
                            Spacer(Modifier.width(12.dp))
                            Text(it, color = Color.White, modifier = Modifier.weight(1f))
                            IconButton(onClick = { settingsManager.removeMusicFolder(it) }) {
                                Icon(Icons.Default.Delete, null, tint = Color.Gray)
                            }
                        }
                        Divider(color = BackgroundColor)
                    }
                    Spacer(Modifier.height(8.dp))
                    Button(onClick = {
                        JFileChooser().apply { fileSelectionMode = JFileChooser.DIRECTORIES_ONLY }
                            .takeIf { it.showOpenDialog(null) == JFileChooser.APPROVE_OPTION }?.selectedFile?.absolutePath?.let {
                                settingsManager.addMusicFolder(it)
                            }
                    }, modifier = Modifier.fillMaxWidth()) { Text("Add Directory") }
                }
            }
            
            // Auto Sync Switch
            Spacer(Modifier.height(24.dp))
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.clickable { settingsManager.setAutoSyncEnabled(!settingsManager.isAutoSyncEnabled()) }.padding(vertical = 8.dp)
            ) {
                Text("Automatic Sync on Start", color = Color.White, modifier = Modifier.weight(1f))
                Switch(checked = settingsManager.isAutoSyncEnabled(), onCheckedChange = null)
            }
        }

        SnackbarHost(hostState = snackbarHostState, modifier = Modifier.align(Alignment.BottomCenter).padding(16.dp))
    }
}

fun main() = application {
    Window(
        onCloseRequest = ::exitApplication,
        title = "SyncTune Sync Tool",
        state = androidx.compose.ui.window.rememberWindowState(width = 800.dp, height = 600.dp)
    ) {
        Surface(color = BackgroundColor) {
            App()
        }
    }
}
