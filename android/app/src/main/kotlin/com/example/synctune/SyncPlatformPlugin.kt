package com.example.synctune

import android.Manifest
import android.app.Activity
import android.app.Application
import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ResultReceiver
import android.provider.DocumentsContract
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream
import java.security.KeyStore
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class SyncPlatformPlugin(private val application: SyncTuneApplication) :
    FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware,
    PluginRegistry.ActivityResultListener, PluginRegistry.RequestPermissionsResultListener {

    private val context: Context = application.applicationContext
    private val resolver: ContentResolver = context.contentResolver
    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newFixedThreadPool(2)
    private val reads = ConcurrentHashMap<String, ReadSession>()
    private val cancellations = ConcurrentHashMap<String, AtomicBoolean>()
    private val stageOffsets = ConcurrentHashMap<String, Long>()
    private var channel: MethodChannel? = null
    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var folderResult: MethodChannel.Result? = null
    private var foregroundStartResult: MethodChannel.Result? = null

    private data class RootScope(val tree: Uri, val generation: String)
    private data class DocumentRef(val uri: Uri, val id: String, val name: String,
        val mime: String, val size: Long, val modifiedMs: Long)
    private data class ReadSession(val scope: RootScope, val stream: InputStream,
        var offset: Long = 0)

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
        application.platformChannel = channel
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        application.platformChannel = null
        reads.keys.toList().forEach(::closeRead)
        io.shutdownNow()
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        activity = binding.activity
        binding.addActivityResultListener(this)
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() = detachActivity()
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)
    override fun onDetachedFromActivity() = detachActivity()

    private fun detachActivity() {
        activityBinding?.removeActivityResultListener(this)
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
        activity = null
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != PICK_FOLDER) return false
        val reply = folderResult ?: return true
        folderResult = null
        if (resultCode != Activity.RESULT_OK) {
            reply.success(null)
            return true
        }
        val uri = data?.data
        if (uri == null) {
            reply.error("folder_picker", "The document picker returned no folder.", null)
            return true
        }
        try {
            val flags = data.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or
                Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            resolver.takePersistableUriPermission(uri, flags)
            val prefs = context.getSharedPreferences(ROOT_PREFS, Context.MODE_PRIVATE)
            val generation = prefs.getString(rootKey(uri), null) ?: UUID.randomUUID().toString()
            val scope = RootScope(uri, generation)
            validateRoot(scope)
            if (!prefs.edit().putString(rootKey(uri), scope.generation).commit()) {
                throw IllegalStateException("Could not save the selected folder permission.")
            }
            reply.success(mapOf(
                "locator" to uri.toString(),
                "stableId" to uri.toString(),
                "generation" to scope.generation,
            ))
        } catch (error: Exception) {
            reply.error("folder_access", error.message ?: "Could not access this folder.", null)
        }
        return true
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>,
        grantResults: IntArray): Boolean {
        if (requestCode != REQUEST_NOTIFICATIONS) return false
        val reply = foregroundStartResult
        foregroundStartResult = null
        if (reply == null) return true
        if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
            startForegroundService(reply)
        } else {
            reply.error("notifications_denied", "Allow SyncTune notifications to run a background sync.", null)
        }
        return true
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "stateDatabasePath" -> result.success(File(context.filesDir,
                "synctune-state-v2.sqlite").absolutePath)
            "pickFolder" -> pickFolder(result)
            "commitFolder" -> commitFolder(call, result)
            "credentialRead" -> credentialRead(call, result)
            "credentialExists" -> credentialExists(call, result)
            "credentialWrite" -> credentialWrite(call, result)
            "credentialDelete" -> credentialDelete(call, result)
            "foregroundStart" -> foregroundStart(result)
            "foregroundUpdate" -> foregroundUpdate(call, result)
            "foregroundFinish" -> foregroundFinish(call, result)
            "allowWindowClose" -> result.notImplemented()
            "safCancelRequest" -> {
                call.argument<String>("requestId")?.let { cancellations[it]?.set(true) }
                result.success(null)
            }
            "safReadClose" -> {
                val handle = call.argument<String>("readHandle")
                if (handle != null) closeRead(handle)
                result.success(null)
            }
            else -> if (call.method.startsWith("saf")) dispatchSaf(call, result)
            else result.notImplemented()
        }
    }

    private fun pickFolder(result: MethodChannel.Result) {
        val host = activity
        if (host == null) {
            result.error("activity_unavailable", "Open SyncTune before choosing a folder.", null)
            return
        }
        if (folderResult != null) {
            result.error("picker_busy", "A folder picker is already open.", null)
            return
        }
        folderResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
        }
        try {
            host.startActivityForResult(intent, PICK_FOLDER)
        } catch (error: Exception) {
            folderResult = null
            result.error("folder_picker", error.message, null)
        }
    }

    private fun commitFolder(call: MethodCall, result: MethodChannel.Result) {
        val old = call.argument<String>("oldRoot")
        val next = call.argument<String>("newRoot")
        if (old != null && old != next) {
            try {
                val uri = Uri.parse(old)
                resolver.releasePersistableUriPermission(uri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                context.getSharedPreferences(ROOT_PREFS, Context.MODE_PRIVATE)
                    .edit().remove(rootKey(uri)).apply()
            } catch (error: SecurityException) {
                result.error("folder_release", error.message, null)
                return
            }
        }
        result.success(null)
    }

    private fun foregroundStart(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            val host = activity
            if (host == null) {
                result.error("activity_unavailable", "Open SyncTune before starting a background sync.", null)
                return
            }
            if (foregroundStartResult != null) {
                result.error("foreground_start_busy", "A background task is already starting.", null)
                return
            }
            foregroundStartResult = result
            try {
                host.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST_NOTIFICATIONS)
            } catch (error: Exception) {
                foregroundStartResult = null
                result.error("notifications_permission", error.message, null)
            }
            return
        }
        startForegroundService(result)
    }

    private fun startForegroundService(result: MethodChannel.Result) {
        val notifications = context.getSystemService(Context.NOTIFICATION_SERVICE)
            as android.app.NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N && !notifications.areNotificationsEnabled()) {
            result.error("notifications_disabled", "Enable SyncTune notifications to run a background sync.", null)
            return
        }
        val reply = object : ResultReceiver(main) {
            override fun onReceiveResult(code: Int, data: Bundle?) {
                if (code == RESULT_STARTED) result.success(null)
                else result.error("foreground_start", data?.getString("error")
                    ?: "The Android sync service did not start.", null)
            }
        }
        try {
            SyncForegroundService.start(context, reply)
        } catch (error: Exception) {
            result.error("foreground_start", error.message ?: error.javaClass.simpleName, null)
        }
    }

    private fun foregroundUpdate(call: MethodCall, result: MethodChannel.Result) {
        try {
            if (!SyncForegroundService.isRunning) {
                result.error("foreground_stopped", "Android stopped the foreground sync task.", null)
                return
            }
            SyncForegroundService.update(context,
                call.argument<String>("phase") ?: "Syncing",
                call.argument<String>("currentFile") ?: "",
                call.argument<Number>("filesDone")?.toInt() ?: 0,
                call.argument<Number>("fileCount")?.toInt() ?: 0)
            result.success(null)
        } catch (error: Exception) {
            result.error("foreground_update", error.message, null)
        }
    }

    private fun foregroundFinish(call: MethodCall, result: MethodChannel.Result) {
        try {
            if (SyncForegroundService.isRunning) {
                val success = call.argument<Boolean>("success") ?: false
                val cancelled = call.argument<Boolean>("cancelled") ?: false
                val message = if (success) "Sync complete" else if (cancelled) "Sync paused; start again to recover" else "Sync stopped"
        SyncForegroundService.finish(context, message)
            }
            result.success(null)
        } catch (error: Exception) {
            result.error("foreground_finish", error.message, null)
        }
    }

    private fun credentialRead(call: MethodCall, result: MethodChannel.Result) {
        try {
            val identity = requiredString(call, "identity")
            val encrypted = context.getSharedPreferences(CREDENTIAL_PREFS, Context.MODE_PRIVATE)
                .getString(credentialKey(identity), null)
            if (encrypted == null) {
                result.success("")
                return
            }
            val parts = encrypted.split(':', limit = 2)
            if (parts.size != 2) throw IllegalStateException("Stored credential is invalid.")
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(128, Base64.decode(parts[0], Base64.NO_WRAP)))
            result.success(String(cipher.doFinal(Base64.decode(parts[1], Base64.NO_WRAP)), Charsets.UTF_8))
        } catch (error: Exception) {
            result.error("credential_read", error.message ?: "Could not read the saved password.", null)
        }
    }

    private fun credentialExists(call: MethodCall, result: MethodChannel.Result) {
        try {
            val identity = requiredString(call, "identity")
            val exists = context.getSharedPreferences(CREDENTIAL_PREFS, Context.MODE_PRIVATE)
                .contains(credentialKey(identity))
            result.success(exists)
        } catch (error: Exception) {
            result.error("credential_status", error.message ?: "Could not inspect the saved password.", null)
        }
    }

    private fun credentialWrite(call: MethodCall, result: MethodChannel.Result) {
        try {
            val identity = requiredString(call, "identity")
            val secret = requiredString(call, "secret")
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, secretKey())
            val encrypted = "${Base64.encodeToString(cipher.iv, Base64.NO_WRAP)}:" +
                Base64.encodeToString(cipher.doFinal(secret.toByteArray(Charsets.UTF_8)), Base64.NO_WRAP)
            if (!context.getSharedPreferences(CREDENTIAL_PREFS, Context.MODE_PRIVATE)
                    .edit().putString(credentialKey(identity), encrypted).commit()) {
                throw IllegalStateException("Could not save the password in secure storage.")
            }
            result.success(null)
        } catch (error: Exception) {
            result.error("credential_write", error.message ?: "Could not save the password.", null)
        }
    }

    private fun credentialDelete(call: MethodCall, result: MethodChannel.Result) {
        try {
            val identity = requiredString(call, "identity")
            context.getSharedPreferences(CREDENTIAL_PREFS, Context.MODE_PRIVATE)
                .edit().remove(credentialKey(identity)).commit()
            result.success(null)
        } catch (error: Exception) {
            result.error("credential_delete", error.message, null)
        }
    }

    private fun secretKey(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val alias = "synctune.webdav.password.v2"
        val existing = store.getKey(alias, null) as? SecretKey
        if (existing != null) return existing
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(KeyGenParameterSpec.Builder(alias,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setRandomizedEncryptionRequired(true).build())
        return generator.generateKey()
    }

    private fun credentialKey(identity: String): String = "identity-" + hex(sha256(identity.toByteArray()))

    private fun dispatchSaf(call: MethodCall, reply: MethodChannel.Result) {
        val requestId = call.argument<String>("requestId")
        val cancelled = if (requestId == null) null else cancellations.computeIfAbsent(requestId) { AtomicBoolean(false) }
        io.execute {
            try {
                val response = handleSaf(call, cancelled)
                main.post { reply.success(response) }
            } catch (error: Exception) {
                main.post {
                    reply.error("saf_${call.method.lowercase()}", error.message ?: error.javaClass.simpleName, null)
                }
            } finally {
                if (requestId != null) cancellations.remove(requestId, cancelled)
            }
        }
    }

    private fun handleSaf(call: MethodCall, cancellation: AtomicBoolean?): Any? {
        val scope = scope(call)
        return when (call.method) {
            "safScan" -> scan(scope, requiredString(call, "requestId"), cancellation!!)
            "safListMusic" -> listMusic(scope)
            "safDeleteMusic" -> deleteMusic(scope, call)
            "safStat" -> {
                val path = requiredString(call, "path")
                val file = resolve(scope, path)
                if (file == null) mapOf("exists" to false)
                else if (file.mime == DIR) throw IllegalStateException("The selected path is a folder.")
                else mapOf("exists" to true, "modifiedMs" to file.modifiedMs, "size" to file.size)
            }
            "safReadOpen" -> openRead(scope, requiredString(call, "path"))
            "safStageReadOpen" -> openStageRead(scope, requiredString(call, "operationId"))
            "safReadChunk" -> readChunk(scope, call)
            "safStageBegin" -> stageBegin(scope, requiredString(call, "operationId"), cancellation!!)
            "safStageWrite" -> stageWrite(scope, call, cancellation!!)
            "safStageFinish" -> stageFinish(scope, call, cancellation!!)
            "safStageHash" -> hashArtifact(scope, requiredString(call, "operationId"), ".part", cancellation!!)
            "safBackupHash" -> hashArtifact(scope, requiredString(call, "operationId"), ".backup", cancellation!!)
            "safCommit" -> commit(scope, call, cancellation!!)
            "safCanResumeCommit" -> canResumeCommit(scope, call, cancellation!!)
            "safDeleteVerified" -> deleteVerified(scope, call, cancellation!!)
            "safRestore" -> restore(scope, call, cancellation!!)
            "safCleanupOperation" -> cleanup(scope, call, cancellation!!)
            else -> throw IllegalArgumentException("Unsupported SAF operation ${call.method}.")
        }
    }

    private fun scope(call: MethodCall): RootScope {
        val root = requiredString(call, "root")
        val generation = requiredString(call, "generation")
        val uri = Uri.parse(root)
        val saved = context.getSharedPreferences(ROOT_PREFS, Context.MODE_PRIVATE)
            .getString(rootKey(uri), null)
        if (saved != generation) throw SecurityException("The selected folder authorization changed. Select the folder again.")
        val persisted = resolver.persistedUriPermissions.any {
            it.uri == uri && it.isReadPermission && it.isWritePermission
        }
        if (!persisted) throw SecurityException("Access to the selected folder was revoked. Select it again.")
        return RootScope(uri, generation)
    }

    private fun validateRoot(scope: RootScope) {
        if (!DocumentsContract.isTreeUri(scope.tree)) throw SecurityException("The selected URI is not a document tree.")
        val permissions = resolver.persistedUriPermissions.any {
            it.uri == scope.tree && it.isReadPermission && it.isWritePermission
        }
        if (!permissions) throw SecurityException("The folder permission was not persisted.")
        val root = rootDocument(scope)
        if (root.mime != DIR) throw SecurityException("The selected item is not a folder.")
        if (DocumentsContract.Document.FLAG_DIR_SUPPORTS_CREATE and flags(scope, root) == 0) {
            throw SecurityException("The folder does not permit creating music files.")
        }
    }

    private fun flags(scope: RootScope, document: DocumentRef): Int {
        val uri = DocumentsContract.buildDocumentUriUsingTree(scope.tree, document.id)
        resolver.query(uri, arrayOf(DocumentsContract.Document.COLUMN_FLAGS), null, null, null)
            ?.use { if (it.moveToFirst()) return it.getInt(0) }
        return 0
    }

    private fun scan(scope: RootScope, requestId: String, cancelled: AtomicBoolean): Map<String, Any?> {
        val results = ArrayList<Map<String, Any?>>()
        val occupiedPaths = ArrayList<Map<String, Any?>>()
        val root = rootDocument(scope)
        val pending = ArrayDeque<Pair<DocumentRef, String>>()
        pending.add(root to "")
        val visited = HashSet<String>()
        while (pending.isNotEmpty()) {
            checkCancelled(cancelled)
            val (directory, prefix) = pending.removeLast()
            if (!visited.add(directory.id)) throw IllegalStateException("The document provider returned a directory cycle.")
            for (child in children(scope, directory)) {
                checkCancelled(cancelled)
                if (child.name.equals(".synctune", true) ||
                    child.name.equals(".synctune-local", true) ||
                    child.name.equals(".synctune-local-v2", true)) continue
                val path = if (prefix.isEmpty()) child.name else "$prefix/${child.name}"
                occupiedPaths.add(mapOf("path" to path, "isDirectory" to (child.mime == DIR)))
                if (child.mime == DIR) {
                    pending.add(child to path)
                } else if (child.name.substringAfterLast('.', "").lowercase() in MUSIC_EXTENSIONS) {
                    val (hash, length) = hashDocument(child, cancelled)
                    results.add(mapOf("path" to path, "sha256" to hash,
                        "size" to length, "modifiedMs" to child.modifiedMs))
                }
            }
        }
        return mapOf("requestId" to requestId, "files" to results,
            "occupiedPaths" to occupiedPaths)
    }

    private fun listMusic(scope: RootScope): Map<String, Any> {
        val tracks = ArrayList<Map<String, Any>>()
        val pending = ArrayDeque<Pair<DocumentRef, String>>()
        pending.add(rootDocument(scope) to "")
        val visited = HashSet<String>()
        while (pending.isNotEmpty()) {
            val (directory, prefix) = pending.removeLast()
            if (!visited.add(directory.id)) throw IllegalStateException("The document provider returned a directory cycle.")
            for (child in children(scope, directory)) {
                if (child.name.equals(".synctune", true) ||
                    child.name.equals(".synctune-local", true) ||
                    child.name.equals(".synctune-local-v2", true)) continue
                val path = if (prefix.isEmpty()) child.name else "$prefix/${child.name}"
                if (child.mime == DIR) {
                    pending.add(child to path)
                } else if (child.name.substringAfterLast('.', "").lowercase() in MUSIC_EXTENSIONS) {
                    normalizedSegments(path)
                    tracks.add(mapOf(
                        "path" to path,
                        "size" to child.size,
                        "modifiedMs" to child.modifiedMs,
                    ))
                }
            }
        }
        tracks.sortBy { it["path"] as String }
        return mapOf("tracks" to tracks)
    }

    private fun deleteMusic(scope: RootScope, call: MethodCall): Map<String, Any> {
        val path = requiredString(call, "path")
        val parts = normalizedSegments(path)
        val internal = parts.any { it.equals(".synctune", true) ||
            it.equals(".synctune-local", true) ||
            it.equals(".synctune-local-v2", true) }
        if (internal || parts.last().substringAfterLast('.', "").lowercase() !in MUSIC_EXTENSIONS) {
            throw IllegalArgumentException("Only music files in the selected folder can be deleted.")
        }
        val expectedSize = call.argument<Number>("expectedSize")?.toLong()
            ?: throw IllegalArgumentException("Missing expectedSize.")
        val expectedModifiedMs = call.argument<Number>("expectedModifiedMs")?.toLong()
            ?: throw IllegalArgumentException("Missing expectedModifiedMs.")
        val target = resolve(scope, path)
            ?: throw IllegalStateException("The selected music file no longer exists.")
        if (target.mime == DIR) throw IllegalStateException("The selected path is a folder.")
        if (target.size != expectedSize || target.modifiedMs != expectedModifiedMs) {
            throw IllegalStateException("The selected music file changed; refresh the list.")
        }
        deleteDocument(target)
        if (resolve(scope, path) != null) throw IllegalStateException("The SAF provider did not confirm deletion.")
        return mapOf("deleted" to true)
    }

    private fun openRead(scope: RootScope, path: String): Map<String, Any> {
        val ref = resolve(scope, path) ?: throw IllegalStateException("File not found: $path")
        if (ref.mime == DIR) throw IllegalStateException("The selected path is a folder.")
        return openStream(scope, ref)
    }

    private fun openStageRead(scope: RootScope, operationId: String): Map<String, Any> {
        val ref = artifact(scope, operationId, ".part")
            ?: throw IllegalStateException("The staged file is missing.")
        return openStream(scope, ref)
    }

    private fun openStream(scope: RootScope, ref: DocumentRef): Map<String, Any> {
        val stream = resolver.openInputStream(ref.uri)
            ?: throw IllegalStateException("The document provider cannot read this file.")
        val handle = UUID.randomUUID().toString()
        reads[handle] = ReadSession(scope, stream)
        return mapOf("readHandle" to handle)
    }

    private fun readChunk(scope: RootScope, call: MethodCall): Map<String, Any> {
        val handle = requiredString(call, "readHandle")
        val session = reads[handle] ?: throw IllegalStateException("The SAF read session is closed.")
        if (session.scope.tree != scope.tree || session.scope.generation != scope.generation) {
            closeRead(handle)
            throw SecurityException("The SAF folder authorization changed during a read.")
        }
        val size = (call.argument<Number>("maxBytes")?.toInt() ?: DEFAULT_CHUNK).coerceIn(1, MAX_CHUNK)
        val buffer = ByteArray(size)
        var count = 0
        var eof = false
        while (count < size) {
            val read = session.stream.read(buffer, count, size - count)
            if (read < 0) { eof = true; break }
            if (read == 0) {
                val next = session.stream.read()
                if (next < 0) { eof = true; break }
                buffer[count++] = next.toByte()
            } else count += read
        }
        session.offset += count
        if (eof) closeRead(handle)
        return mapOf("bytes" to buffer.copyOf(count), "eof" to eof, "offset" to session.offset)
    }

    private fun closeRead(handle: String) {
        reads.remove(handle)?.let { try { it.stream.close() } catch (_: Exception) {} }
    }

    private fun stageBegin(scope: RootScope, operationId: String,
        cancelled: AtomicBoolean): Map<String, Any> {
        validateOperationId(operationId)
        val directory = internalDirectory(scope, create = true)
            ?: throw IllegalStateException("SyncTune's recovery folder could not be created.")
        val name = "$operationId.part"
        val ref = findChild(scope, directory, name) ?: createDocument(scope, directory, name, BINARY)
        if (ref.mime == DIR) throw IllegalStateException("The stage path is a folder.")
        val length = exactDocumentLength(ref, cancelled)
        stageOffsets[stageOffsetKey(scope, operationId)] = length
        return mapOf("operationId" to operationId, "length" to length)
    }

    private fun stageWrite(scope: RootScope, call: MethodCall,
        cancelled: AtomicBoolean): Map<String, Any> {
        val id = requiredString(call, "operationId")
        validateOperationId(id)
        val offset = (call.argument<Number>("offset")?.toLong() ?: -1L)
        val bytes = call.argument<ByteArray>("bytes") ?: throw IllegalArgumentException("Missing stage bytes.")
        if (bytes.size > MAX_CHUNK) throw IllegalArgumentException("The stage chunk is too large.")
        checkCancelled(cancelled)
        val ref = artifact(scope, id, ".part") ?: throw IllegalStateException("The stage was not opened.")
        val key = stageOffsetKey(scope, id)
        val length = stageOffsets[key] ?: throw IllegalStateException("The SAF stage was not opened for this transfer.")
        if (length != offset) throw IllegalStateException("The SAF stage offset changed.")
        resolver.openOutputStream(ref.uri, "wa")?.use { output ->
            output.write(bytes)
            output.flush()
        } ?: throw IllegalStateException("The document provider cannot write a stage.")
        checkCancelled(cancelled)
        val next = length + bytes.size
        stageOffsets[key] = next
        return mapOf("nextOffset" to next)
    }

    private fun stageFinish(scope: RootScope, call: MethodCall, cancelled: AtomicBoolean): Map<String, Any> {
        val id = requiredString(call, "operationId")
        val expected = validHash(requiredString(call, "expectedSha256"))
        val ref = artifact(scope, id, ".part") ?: throw IllegalStateException("The staged file is missing.")
        val (actual, length) = hashDocument(ref, cancelled)
        if (actual != expected) throw IllegalStateException("SAF staged data failed SHA-256 verification.")
        stageOffsets.remove(stageOffsetKey(scope, id))
        return mapOf("sha256" to actual, "length" to length)
    }

    private fun hashArtifact(scope: RootScope, operationId: String, suffix: String,
        cancelled: AtomicBoolean): Map<String, Any?> {
        validateOperationId(operationId)
        val ref = artifact(scope, operationId, suffix) ?: return mapOf("sha256" to null)
        val (hash, length) = hashDocument(ref, cancelled)
        return mapOf("sha256" to hash, "length" to length)
    }

    private fun commit(scope: RootScope, call: MethodCall, cancelled: AtomicBoolean): Map<String, Any> {
        val path = requiredString(call, "path")
        val id = requiredString(call, "operationId")
        val expected = validHash(requiredString(call, "expectedSha256"))
        val previous = optionalHash(call.argument<String>("previousSha256"))
        val stage = artifact(scope, id, ".part") ?: throw IllegalStateException("The staged file is missing.")
        if (hashDocument(stage, cancelled).first != expected) throw IllegalStateException("The SAF stage changed before commit.")
        val backup = artifact(scope, id, ".backup")
        val prefs = context.getSharedPreferences(ROOT_PREFS, Context.MODE_PRIVATE)
        val markerKey = publishKey(scope, id)
        val marker = prefs.getString(markerKey, null)
        val markerParts = marker?.split('\n')
        if (marker != null && (markerParts?.size != 3 || markerParts[0] != path || markerParts[1] != expected)) {
            throw IllegalStateException("The SAF operation marker does not match the pending path.")
        }
        val target = resolve(scope, path)
        val current = target?.let { hashDocument(it, cancelled).first }
        if (current == expected) {
            if (backup != null && hashDocument(backup, cancelled).first != previous) {
                throw IllegalStateException("The SAF recovery copy contains unknown data.")
            }
            if (marker != null && !prefs.edit().remove(markerKey).commit()) {
                throw IllegalStateException("Could not finalize the SAF operation marker.")
            }
            return mapOf("sha256" to expected)
        }
        val backupHash = backup?.let { hashDocument(it, cancelled).first }
        val movedBackup = current == null && previous != null && backupHash == previous
        if (marker == null && current != previous && !movedBackup) {
            throw IllegalStateException("The local file changed after scanning; start a new sync.")
        }
        if (marker != null) {
            val markedId = markerParts!![2]
            if (target != null && markedId != "pending" && target.id != markedId) {
                throw IllegalStateException("A different document replaced the interrupted SAF publication.")
            }
            if (target != null && !isPrefixDocument(stage, target, cancelled)) {
                throw IllegalStateException("The interrupted SAF publication contains unknown data and was kept.")
            }
            if (target == null && markedId != "pending") {
                throw IllegalStateException("The interrupted SAF publication was removed externally.")
            }
        }
        if (marker == null) {
            if (previous == null && backup != null) throw IllegalStateException("An unknown SAF backup occupies the operation path.")
            if (target != null && !movedBackup) {
                val confirmed = preserveDocument(scope, target, id, previous!!, cancelled)
                if (confirmed != previous) throw IllegalStateException("The previous local file was not safely backed up.")
                val stillThere = resolve(scope, path)
                    ?: throw IllegalStateException("The previous local file disappeared before replacement.")
                if (hashDocument(stillThere, cancelled).first != previous) {
                    throw IllegalStateException("The previous local file changed before replacement.")
                }
                deleteDocument(stillThere)
                if (resolve(scope, path) != null) throw IllegalStateException("The previous local file could not be removed safely.")
            } else if (previous != null && !movedBackup) {
                throw IllegalStateException("The prior local file disappeared before backup.")
            }
            if (!prefs.edit().putString(markerKey, "$path\n$expected\npending").commit()) {
                throw IllegalStateException("Could not record the SAF publication before creating its target.")
            }
        }
        checkCancelled(cancelled)
        var published = resolve(scope, path)
        if (published == null) {
            val parent = resolveParent(scope, path, create = true)
            val leaf = path.substringAfterLast('/')
            published = createDocument(scope, parent, leaf, mimeFor(leaf))
            if (!prefs.edit().putString(markerKey, "$path\n$expected\n${published.id}").commit()) {
                throw IllegalStateException("Could not save the SAF publication identity; recovery data was kept.")
            }
        } else if (marker == null) {
            throw IllegalStateException("A different local file occupies the target path.")
        }
        copyDocument(scope, stage, published, expected, cancelled)
        if (hashDocument(published, cancelled).first != expected) {
            throw IllegalStateException("The published local file failed SHA-256 verification; recovery copy was kept.")
        }
        if (!prefs.edit().remove(markerKey).commit()) {
            throw IllegalStateException("Could not clear the completed SAF publication marker.")
        }
        return mapOf("sha256" to expected)
    }

    private fun canResumeCommit(scope: RootScope, call: MethodCall,
        cancelled: AtomicBoolean): Map<String, Any> {
        val path = requiredString(call, "path")
        val id = requiredString(call, "operationId")
        val expected = validHash(requiredString(call, "expectedSha256"))
        val previous = optionalHash(call.argument<String>("previousSha256"))
        validateOperationId(id)
        val stage = artifact(scope, id, ".part") ?: return mapOf("recoverable" to false)
        if (hashDocument(stage, cancelled).first != expected) return mapOf("recoverable" to false)
        val backup = artifact(scope, id, ".backup")
        if (previous != null && (backup == null || hashDocument(backup, cancelled).first != previous)) {
            return mapOf("recoverable" to false)
        }
        if (previous == null && backup != null) return mapOf("recoverable" to false)
        val target = resolve(scope, path)
        if (target == null) {
            val marker = context.getSharedPreferences(ROOT_PREFS, Context.MODE_PRIVATE)
                .getString(publishKey(scope, id), null)
            return mapOf("recoverable" to (marker == "$path\n$expected\npending"))
        }
        if (hashDocument(target, cancelled).first == expected) return mapOf("recoverable" to true)
        val marker = context.getSharedPreferences(ROOT_PREFS, Context.MODE_PRIVATE)
            .getString(publishKey(scope, id), null) ?: return mapOf("recoverable" to false)
        val parts = marker.split('\n')
        if (parts.size != 3 || parts[0] != path || parts[1] != expected ||
            (parts[2] != "pending" && parts[2] != target.id)) return mapOf("recoverable" to false)
        if (previous != null) {
            val backup = artifact(scope, id, ".backup") ?: return mapOf("recoverable" to false)
            if (hashDocument(backup, cancelled).first != previous) return mapOf("recoverable" to false)
        }
        return mapOf("recoverable" to isPrefixDocument(stage, target, cancelled))
    }

    private fun deleteVerified(scope: RootScope, call: MethodCall, cancelled: AtomicBoolean): Map<String, Any> {
        val path = requiredString(call, "path")
        val id = requiredString(call, "operationId")
        val expected = validHash(requiredString(call, "expectedSha256"))
        val target = resolve(scope, path)
        val backup = artifact(scope, id, ".backup")
        if (target == null) {
            if (backup != null && hashDocument(backup, cancelled).first == expected) return mapOf("deleted" to true)
            throw IllegalStateException("The local delete target disappeared before backup was confirmed.")
        }
        if (hashDocument(target, cancelled).first != expected) throw IllegalStateException("The local file changed before deletion.")
        val copied = preserveDocument(scope, target, id, expected, cancelled)
        if (copied != expected) throw IllegalStateException("The local recovery copy failed verification.")
        val current = resolve(scope, path) ?: return mapOf("deleted" to true)
        if (hashDocument(current, cancelled).first != expected) throw IllegalStateException("The local file changed before deletion.")
        deleteDocument(current)
        if (resolve(scope, path) != null) throw IllegalStateException("The SAF provider did not confirm deletion.")
        return mapOf("deleted" to true)
    }

    private fun restore(scope: RootScope, call: MethodCall, cancelled: AtomicBoolean): Map<String, Any> {
        val path = requiredString(call, "path")
        val id = requiredString(call, "operationId")
        val expected = validHash(requiredString(call, "expectedSha256"))
        val backup = artifact(scope, id, ".backup") ?: return mapOf("restored" to false)
        if (hashDocument(backup, cancelled).first != expected) throw IllegalStateException("The SAF recovery copy contains unknown data.")
        val target = resolve(scope, path)
        if (target != null) {
            if (hashDocument(target, cancelled).first == expected) return mapOf("restored" to true)
            throw IllegalStateException("A different local file occupies the recovery path.")
        }
        val parent = resolveParent(scope, path, create = true)
        val restored = createDocument(scope, parent, path.substringAfterLast('/'), mimeFor(path))
        copyDocument(scope, backup, restored, expected, cancelled)
        if (hashDocument(restored, cancelled).first != expected) throw IllegalStateException("The restored file failed verification.")
        return mapOf("restored" to true)
    }

    private fun cleanup(scope: RootScope, call: MethodCall, cancelled: AtomicBoolean): Map<String, Any> {
        val id = requiredString(call, "operationId")
        validateOperationId(id)
        val stageHash = optionalHash(call.argument<String>("stageSha256"))
        val backupHash = optionalHash(call.argument<String>("backupSha256"))
        for ((suffix, expected) in listOf(".part" to stageHash, ".backup" to backupHash)) {
            checkCancelled(cancelled)
            val file = artifact(scope, id, suffix) ?: continue
            if (expected == null || hashDocument(file, cancelled).first != expected) {
                throw IllegalStateException("Unknown SAF recovery data remains and was kept.")
            }
            deleteDocument(file)
        }
        val markerKey = publishKey(scope, id)
        val marker = context.getSharedPreferences(ROOT_PREFS, Context.MODE_PRIVATE)
            .getString(markerKey, null)
        if (marker != null) {
            val fields = marker.split('\n')
            if (fields.size != 3 || stageHash == null || fields[1] != stageHash) {
                throw IllegalStateException("Unknown SAF publication recovery data remains and was kept.")
            }
            val target = resolve(scope, fields[0])
            if (target == null || hashDocument(target, cancelled).first != stageHash) {
                throw IllegalStateException("The SAF publication marker does not match the completed file.")
            }
            if (!context.getSharedPreferences(ROOT_PREFS, Context.MODE_PRIVATE)
                    .edit().remove(markerKey).commit()) {
                throw IllegalStateException("Could not clear the completed SAF publication marker.")
            }
        }
        stageOffsets.remove(stageOffsetKey(scope, id))
        return mapOf("cleaned" to true)
    }

    private fun preserveDocument(scope: RootScope, source: DocumentRef, operationId: String,
        expectedHash: String, cancelled: AtomicBoolean): String {
        validateOperationId(operationId)
        val name = "$operationId.backup"
        val internal = internalDirectory(scope, create = true)
            ?: throw IllegalStateException("SyncTune's recovery folder could not be created.")
        val existing = findChild(scope, internal, name)
        if (existing != null) {
            val liveHash = hashDocument(source, cancelled).first
            if (liveHash != expectedHash) throw IllegalStateException("The local source changed while backing it up.")
            if (hashDocument(existing, cancelled).first != expectedHash) {
                if (!isPrefixDocument(source, existing, cancelled)) {
                    throw IllegalStateException("An unknown SAF backup was kept.")
                }
                copyDocument(scope, source, existing, expectedHash, cancelled)
            }
            if (hashDocument(existing, cancelled).first != expectedHash) {
                throw IllegalStateException("The interrupted SAF backup could not be completed.")
            }
            return expectedHash
        }
        val backup = createDocument(scope, internal, name, BINARY)
        copyDocument(scope, source, backup, expectedHash, cancelled)
        if (hashDocument(backup, cancelled).first != expectedHash) {
            throw IllegalStateException("The SAF backup failed verification; both copies were kept.")
        }
        return expectedHash
    }

    private fun copyDocument(scope: RootScope, source: DocumentRef, destination: DocumentRef,
        expectedHash: String, cancelled: AtomicBoolean) {
        if (!isPrefixDocument(source, destination, cancelled)) {
            throw IllegalStateException("The existing SAF destination is not a source prefix; it was kept.")
        }
        val input = resolver.openInputStream(source.uri)
            ?: throw IllegalStateException("The provider cannot read a recovery source.")
        val output = resolver.openOutputStream(destination.uri, "w")
            ?: throw IllegalStateException("The provider cannot write a recovery destination.")
        input.use { from -> output.use { to ->
            val buffer = ByteArray(DEFAULT_CHUNK)
            while (true) {
                checkCancelled(cancelled)
                val count = from.read(buffer)
                if (count < 0) break
                if (count == 0) continue
                to.write(buffer, 0, count)
                to.flush()
            }
        } }
        if (hashDocument(destination, cancelled).first != expectedHash) {
            throw IllegalStateException("The copied SAF document failed SHA-256 verification.")
        }
    }

    private fun isPrefixDocument(source: DocumentRef, destination: DocumentRef,
        cancelled: AtomicBoolean): Boolean {
        val input = resolver.openInputStream(source.uri)
            ?: throw IllegalStateException("The SAF source cannot be read.")
        val prefix = resolver.openInputStream(destination.uri)
            ?: throw IllegalStateException("The interrupted SAF destination cannot be read.")
        input.use { sourceStream -> prefix.use { prefixStream ->
            val a = ByteArray(DEFAULT_CHUNK)
            val b = ByteArray(DEFAULT_CHUNK)
            while (true) {
                checkCancelled(cancelled)
                var prefixCount = prefixStream.read(b)
                if (prefixCount < 0) return true
                if (prefixCount == 0) {
                    val next = prefixStream.read()
                    if (next < 0) return true
                    b[0] = next.toByte()
                    prefixCount = 1
                }
                var consumed = 0
                while (consumed < prefixCount) {
                    val sourceCount = sourceStream.read(a, consumed, prefixCount - consumed)
                    if (sourceCount < 0) return false
                    if (sourceCount == 0) continue
                    for (index in 0 until sourceCount) {
                        if (a[index + consumed] != b[index + consumed]) return false
                    }
                    consumed += sourceCount
                }
            }
        } }
    }

    private fun hashDocument(ref: DocumentRef, cancelled: AtomicBoolean): Pair<String, Long> {
        val digest = MessageDigest.getInstance("SHA-256")
        var length = 0L
        val input = resolver.openInputStream(ref.uri)
            ?: throw IllegalStateException("The provider cannot read ${ref.name}.")
        input.use { stream ->
            val buffer = ByteArray(DEFAULT_CHUNK)
            while (true) {
                checkCancelled(cancelled)
                val count = stream.read(buffer)
                if (count < 0) break
                if (count == 0) continue
                digest.update(buffer, 0, count)
                length += count
            }
        }
        return hex(digest.digest()) to length
    }

    private fun resolve(scope: RootScope, relative: String): DocumentRef? {
        val pieces = normalizedSegments(relative)
        var parent = rootDocument(scope)
        for (segment in pieces.dropLast(1)) {
            val child = findChild(scope, parent, segment) ?: return null
            if (child.mime != DIR) throw IllegalStateException("A file blocks folder path $segment.")
            parent = child
        }
        return findChild(scope, parent, pieces.last())
    }

    private fun resolveParent(scope: RootScope, relative: String, create: Boolean): DocumentRef {
        val pieces = normalizedSegments(relative)
        var parent = rootDocument(scope)
        for (segment in pieces.dropLast(1)) {
            var child = findChild(scope, parent, segment)
            if (child == null && create) child = createDocument(scope, parent, segment, DIR)
            if (child == null) throw IllegalStateException("A parent folder is missing: $segment")
            if (child.mime != DIR) throw IllegalStateException("A file blocks folder path $segment.")
            parent = child
        }
        return parent
    }

    private fun normalizedSegments(path: String): List<String> {
        if (path.isEmpty() || path.startsWith('/') || path.contains('\\') || path.contains('\u0000')) {
            throw IllegalArgumentException("Invalid relative file path.")
        }
        val parts = path.split('/')
        if (parts.any { it.isEmpty() || it == "." || it == ".." || it.contains(':') || it.endsWith('.') || it.endsWith(' ') }) {
            throw IllegalArgumentException("Unsupported file path segment.")
        }
        return parts
    }

    private fun rootDocument(scope: RootScope): DocumentRef {
        val id = DocumentsContract.getTreeDocumentId(scope.tree)
        return readDocument(DocumentsContract.buildDocumentUriUsingTree(scope.tree, id))
    }

    private fun children(scope: RootScope, parent: DocumentRef): List<DocumentRef> {
        val uri = DocumentsContract.buildChildDocumentsUriUsingTree(scope.tree, parent.id)
        val projection = arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED)
        val output = ArrayList<DocumentRef>()
        resolver.query(uri, projection, null, null, null)?.use { cursor ->
            while (cursor.moveToNext()) {
                val id = cursor.getString(0)
                    ?: throw IllegalStateException("A listed document has no ID.")
                val name = cursor.getString(1)
                    ?: throw IllegalStateException("A listed document has no name.")
                val mime = cursor.getString(2)
                    ?: throw IllegalStateException("A listed document has no type.")
                val size = if (cursor.isNull(3)) -1L else cursor.getLong(3)
                val modified = if (cursor.isNull(4)) 0L else cursor.getLong(4)
                output.add(DocumentRef(DocumentsContract.buildDocumentUriUsingTree(scope.tree, id),
                    id, name, mime, size, modified))
            }
        } ?: throw IllegalStateException("The provider did not list folder ${parent.name}.")
        return output
    }

    private fun findChild(scope: RootScope, parent: DocumentRef, name: String): DocumentRef? {
        val found = children(scope, parent).filter { it.name == name }
        if (found.size > 1) throw IllegalStateException("The provider returned duplicate names for $name.")
        return found.firstOrNull()
    }

    private fun createDocument(scope: RootScope, parent: DocumentRef, name: String, mime: String): DocumentRef {
        val child = findChild(scope, parent, name)
        if (child != null) throw IllegalStateException("A document already exists at $name.")
        val uri = DocumentsContract.createDocument(resolver,
            DocumentsContract.buildDocumentUriUsingTree(scope.tree, parent.id), mime, name)
            ?: throw IllegalStateException("The provider could not create $name.")
        return readDocument(uri)
    }

    private fun readDocument(uri: Uri): DocumentRef {
        val projection = arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED)
        resolver.query(uri, projection, null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val id = cursor.getString(0) ?: throw IllegalStateException("A document has no ID.")
                val name = cursor.getString(1)
                    ?: throw IllegalStateException("A document has no name.")
                val mime = cursor.getString(2)
                    ?: throw IllegalStateException("A document has no type.")
                val size = if (cursor.isNull(3)) -1L else cursor.getLong(3)
                val modified = if (cursor.isNull(4)) 0L else cursor.getLong(4)
                return DocumentRef(uri, id, name, mime, size, modified)
            }
        } ?: throw IllegalStateException("The provider could not inspect a document.")
        throw IllegalStateException("A document disappeared.")
    }

    private fun internalDirectory(scope: RootScope, create: Boolean): DocumentRef? {
        val root = rootDocument(scope)
        val directory = optionalRecoveryFolder(
            create = create,
            find = { findChild(scope, root, ".synctune-local-v2") },
            createFolder = { createDocument(scope, root, ".synctune-local-v2", DIR) },
            isFolder = { it.mime == DIR },
            label = "SyncTune's recovery item",
        ) ?: return null
        val sync = optionalRecoveryFolder(
            create = create,
            find = { findChild(scope, directory, "sync") },
            createFolder = { createDocument(scope, directory, "sync", DIR) },
            isFolder = { it.mime == DIR },
            label = "SyncTune's operation item",
        ) ?: return null
        return sync
    }

    private fun artifact(scope: RootScope, operationId: String, suffix: String): DocumentRef? {
        validateOperationId(operationId)
        val internal = internalDirectory(scope, create = false) ?: return null
        return findChild(scope, internal, "$operationId$suffix")
    }

    private fun exactDocumentLength(ref: DocumentRef, cancelled: AtomicBoolean): Long {
        val input = resolver.openInputStream(ref.uri)
            ?: throw IllegalStateException("The provider cannot read the existing SAF stage.")
        input.use { stream ->
            val buffer = ByteArray(DEFAULT_CHUNK)
            var length = 0L
            while (true) {
                checkCancelled(cancelled)
                val count = stream.read(buffer)
                if (count < 0) return length
                if (count == 0) continue
                length += count
            }
        }
    }

    private fun stageOffsetKey(scope: RootScope, operationId: String): String =
        "${rootKey(scope.tree)}:${scope.generation}:$operationId"

    private fun deleteDocument(document: DocumentRef) {
        if (!DocumentsContract.deleteDocument(resolver, document.uri)) {
            throw IllegalStateException("The provider did not confirm deletion of ${document.name}.")
        }
    }

    private fun checkCancelled(cancelled: AtomicBoolean?) {
        if (cancelled?.get() == true) throw InterruptedException("The operation was cancelled at a file-safe point.")
    }

    private fun requiredString(call: MethodCall, key: String): String =
        call.argument<String>(key)?.takeIf { it.isNotEmpty() }
            ?: throw IllegalArgumentException("Missing $key.")

    private fun validHash(value: String): String = value.lowercase().also {
        if (!Regex("^[0-9a-f]{64}$").matches(it)) throw IllegalArgumentException("Invalid SHA-256 value.")
    }

    private fun optionalHash(value: String?): String? = value?.let(::validHash)

    private fun validateOperationId(value: String) {
        if (!Regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$").matches(value)) {
            throw IllegalArgumentException("Invalid operation ID.")
        }
    }

    private fun rootKey(uri: Uri): String = "root-" + hex(sha256(uri.toString().toByteArray()))
    private fun publishKey(scope: RootScope, operationId: String): String =
        "publish-${rootKey(scope.tree)}-${scope.generation}-$operationId"
    private fun sha256(value: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(value)
    private fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it) }

    private fun mimeFor(name: String): String = when (name.substringAfterLast('.', "").lowercase()) {
        "mp3" -> "audio/mpeg"
        "flac" -> "audio/flac"
        "wav" -> "audio/wav"
        "m4a" -> "audio/mp4"
        "aac" -> "audio/aac"
        "ogg", "opus" -> "audio/ogg"
        else -> BINARY
    }

    companion object {
        private const val CHANNEL = "synctune/sync_platform"
        private const val PICK_FOLDER = 708
        private const val REQUEST_NOTIFICATIONS = 709
        private const val ROOT_PREFS = "synctune_roots_v2"
        private const val CREDENTIAL_PREFS = "synctune_credentials_v2"
        private const val DIR = DocumentsContract.Document.MIME_TYPE_DIR
        private const val BINARY = "application/octet-stream"
        private const val DEFAULT_CHUNK = 64 * 1024
        private const val MAX_CHUNK = 256 * 1024
        private const val RESULT_STARTED = 1
        private val MUSIC_EXTENSIONS = setOf("mp3", "flac", "wav", "m4a", "aac", "ogg", "opus")
    }
}

internal fun <T : Any> optionalRecoveryFolder(
    create: Boolean,
    find: () -> T?,
    createFolder: () -> T,
    isFolder: (T) -> Boolean,
    label: String,
): T? {
    var folder = find()
    if (folder == null && create) folder = createFolder()
    if (folder == null) return null
    if (!isFolder(folder)) throw IllegalStateException("$label is not a folder.")
    return folder
}
