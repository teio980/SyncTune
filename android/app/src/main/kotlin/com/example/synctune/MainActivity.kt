package com.example.synctune

import android.app.Activity
import android.content.Intent
import android.content.ActivityNotFoundException
import android.net.Uri
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileNotFoundException
import java.io.InputStream
import java.io.FileOutputStream
import java.security.MessageDigest
import java.security.KeyStore
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val channelName = "synctune/probe"
    private val pickRootRequest = 701
    private val notificationPermissionRequest = 702
    private var pendingRootResult: MethodChannel.Result? = null
    private var pendingNotificationResult: MethodChannel.Result? = null
    @Volatile private var rootBusy = false
    private val prefsName = "synctune-root"
    private val scanExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val musicExtensions = setOf("mp3", "flac", "wav", "m4a", "aac", "ogg", "opus")
    private val credentialAlias = "synctune.credentials.v1"
    private val credentialDirectoryName = "synctune-credentials"
    private val stageKeyPattern = Regex(
        "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-" +
            "[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$",
    )
    @Volatile private var engineAlive = false
    private val stageSessions = ConcurrentHashMap<String, StageSession>()
    private val readSessions = ConcurrentHashMap<String, ReadSession>()

    private data class ReadSession(
        val token: String,
        val generation: String,
        val resource: String,
        val input: InputStream,
        var nextOffset: Long = 0,
        var touchedAt: Long = System.currentTimeMillis(),
    )

    private fun closeRead(handle: String) {
        readSessions.remove(handle)?.let {
            try { it.input.close() } catch (_: Exception) {}
        }
    }

    private data class DocumentRef(val uri: Uri, val id: String, val mime: String)
    private data class StageSession(
        val token: String,
        val generation: String,
        val document: DocumentRef,
        var nextOffset: Long = 0,
    )

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        engineAlive = true
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result -> handleCall(call, result) }
    }

    private fun handleCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pickRoot" -> {
                if (pendingRootResult != null || rootBusy) {
                    result.error("busy", "A folder picker is already open.", null)
                    return
                }
                pendingRootResult = result
                rootBusy = true
                val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                    addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                    addFlags(Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
                }
                try {
                    startActivityForResult(intent, pickRootRequest)
                } catch (error: ActivityNotFoundException) {
                    pendingRootResult = null
                    rootBusy = false
                    result.error("saf_unavailable", error.message, null)
                }
            }
            "restoreRoot" -> restoreRoot(result)
            "revokeRoot" -> revokeRoot(call, result)
            "scanMusic" -> scanMusic(call, result)
            "localReadChunk" -> brokerCall(result) {
                localReadChunk(call)
            }
            "localCloseRead" -> brokerCall(result) {
                val handle = call.argument<String>("readHandle")
                    ?: throw IllegalArgumentException("missing read handle")
                val session = readSessions[handle]
                if (session != null && (session.token != call.argument<String>("token") ||
                    session.generation != call.argument<String>("generation"))) {
                    throw SecurityException("read handle scope changed")
                }
                closeRead(handle)
                mapOf("status" to "ok")
            }
            "localStageBegin" -> brokerCall(result) {
                localStageBegin(call)
            }
            "localStageWrite" -> brokerCall(result) {
                localStageWrite(call)
            }
            "localStageFinish" -> brokerCall(result) {
                localStageFinish(call)
            }
            "localOpenStagedChunk" -> brokerCall(result) {
                localOpenStagedChunk(call)
            }
            "localVerifyStaged" -> brokerCall(result) {
                localVerifyStaged(call)
            }
            "localCommitStaged" -> brokerCall(result) {
                localCommitStaged(call)
            }
            "localDelete" -> brokerCall(result) {
                localDelete(call)
            }
            "credentialSave" -> brokerCall(result) {
                credentialSave(call)
            }
            "credentialRead" -> brokerCall(result) {
                credentialRead(call)
            }
            "credentialDelete" -> brokerCall(result) {
                credentialDelete(call)
            }
            "brokerCapabilities" -> result.success(brokerCapabilities())
            "privateDatabasePath" -> result.success(
                File(filesDir, "synctune-probe.sqlite").absolutePath,
            )
            "processInfo" -> result.success(
                mapOf(
                    "pid" to android.os.Process.myPid(),
                    "appContainer" to "false",
                    "platform" to "android",
                ),
            )
            "credentialRoundTrip" -> brokerCall(result) { credentialRoundTrip() }
            "restoreFolder" -> restoreFolder(result)
            "syncNotificationStart" -> {
                val title = call.argument<String>("title") ?: "SyncTune"
                val message = call.argument<String>("message") ?: "Syncing…"
                SyncForegroundService.start(this, title, message)
                result.success(mapOf("status" to "ok"))
            }
            "syncNotificationUpdate" -> {
                val title = call.argument<String>("title") ?: "SyncTune"
                val message = call.argument<String>("message") ?: "Syncing…"
                val progress = call.argument<Int>("progress")
                val max = call.argument<Int>("max")
                val indeterminate = call.argument<Boolean>("indeterminate") ?: false
                SyncForegroundService.update(this, title, message, progress, max, indeterminate)
                result.success(mapOf("status" to "ok"))
            }
            "syncNotificationFinish" -> {
                val title = call.argument<String>("title") ?: "SyncTune"
                val message = call.argument<String>("message") ?: "Sync complete"
                val success = call.argument<Boolean>("success") ?: true
                SyncForegroundService.finish(this, title, message, success)
                result.success(mapOf("status" to "ok"))
            }
            "syncNotificationCancel" -> {
                SyncForegroundService.cancel(this)
                result.success(mapOf("status" to "ok"))
            }
            "requestNotificationPermission" -> {
                requestNotificationPermission(result)
            }
            else -> result.notImplemented()
        }
    }

    /**
     * Verifies that the active SAF tree can be reopened after process restart.
     * The marker lives only in SyncTune's reserved staging directory and is
     * uniquely named, so the probe never reads or replaces a music file.
     */
    private fun restoreFolder(result: MethodChannel.Result) {
        scanExecutor.execute {
            var failureStage = "restore-root"
            val response = try {
                restoreFolderState { stage -> failureStage = stage }
            } catch (error: Exception) {
                mapOf(
                    "status" to "failed",
                    "restartCheck" to "failed",
                    "fileIo" to "failed",
                    "phase" to failureStage,
                    "errorType" to error.javaClass.simpleName,
                )
            }
            if (!isFinishing && !isDestroyed) {
                mainHandler.post {
                    if (!isFinishing && !isDestroyed) result.success(response)
                }
            }
        }
    }

    private fun restoreFolderState(setStage: (String) -> Unit): Map<String, Any?> {
        setStage("restore-root")
        val grant = restoreRootState()
        if (grant["status"] != "ok") {
            return mapOf(
                "status" to "not-run",
                "restartCheck" to "not-run",
                "fileIo" to "not-run",
                "reason" to "no-restored-root",
            )
        }
        val token = grant["token"] as? String
            ?: throw IllegalStateException("restored SAF root token is missing")
        val generation = grant["generation"] as? String
            ?: throw IllegalStateException("restored SAF root generation is missing")
        ensureActiveRoot(token, generation)

        val rootKey = MessageDigest.getInstance("SHA-256")
            .digest("$token\n$generation".toByteArray(Charsets.UTF_8))
            .joinToString("") { byte -> "%02x".format(byte.toInt() and 0xff) }
        val preferenceKey = "folder-restore-$rootKey"
        val probePreferences = getSharedPreferences("synctune-probe", MODE_PRIVATE)
        val previousRecord = probePreferences.getString(preferenceKey, null)
        var restartCheck = "pending"
        val treeUri = Uri.parse(token)
        setStage("stage-directory")
        val directory = stageDirectory(token, generation)

        if (previousRecord != null) {
            val fields = previousRecord.split('\n', limit = 5)
            when {
                fields.size == 3 -> {
                    // Version 1 stored only the display name. Some SAF
                    // providers hide dot-directory children from queries, so
                    // migrate without claiming restart recovery if it is not
                    // discoverable. Version 2 below stores its exact URI.
                    val previousPid = fields[0].toIntOrNull()
                    if (previousPid == null ||
                        !Regex("^synctune-restore-[0-9a-fA-F-]{36}\\.probe$")
                            .matches(fields[1])) {
                        throw IllegalStateException("persisted SAF marker record is invalid")
                    }
                    if (previousPid != android.os.Process.myPid()) {
                        setStage("lookup-legacy-marker")
                        val legacy = childDocument(treeUri, directory.id, fields[1])
                        if (legacy != null) {
                            setStage("read-legacy-marker")
                            val legacyText = readSmallMarker(legacy.uri)
                            if (legacy.mime == DocumentsContract.Document.MIME_TYPE_DIR ||
                                legacyText != fields[2]) {
                                throw IllegalStateException("persisted SAF marker content changed")
                            }
                            setStage("cleanup-legacy-marker")
                            if (!DocumentsContract.deleteDocument(contentResolver, legacy.uri)) {
                                throw IllegalStateException("persisted SAF marker cleanup was not confirmed")
                            }
                            restartCheck = "ok"
                        }
                    }
                }
                fields.size == 5 && fields[0] == "2" -> {
                    val previousPid = fields[1].toIntOrNull()
                    val previousName = fields[2]
                    val markerUri = Uri.parse(fields[3])
                    if (previousPid == null ||
                        !Regex("^synctune-restore-[0-9a-fA-F-]{36}\\.probe$")
                            .matches(previousName) ||
                        !DocumentsContract.isTreeUri(markerUri) ||
                        markerUri.authority != treeUri.authority ||
                        DocumentsContract.getTreeDocumentId(markerUri) !=
                            DocumentsContract.getTreeDocumentId(treeUri)) {
                        throw IllegalStateException("persisted SAF marker URI is invalid")
                    }
                    setStage("read-previous-marker")
                    if (readSmallMarker(markerUri) != fields[4]) {
                        // Preserve a marker whose contents changed outside
                        // the probe.
                        throw IllegalStateException("persisted SAF marker content changed")
                    }
                    if (previousPid != android.os.Process.myPid()) {
                        restartCheck = "ok"
                    }
                    setStage("cleanup-previous-marker")
                    if (!DocumentsContract.deleteDocument(contentResolver, markerUri)) {
                        throw IllegalStateException("persisted SAF marker cleanup was not confirmed")
                    }
                }
                else -> throw IllegalStateException("persisted SAF marker record is invalid")
            }
            if (!probePreferences.edit().remove(preferenceKey).commit()) {
                throw IllegalStateException("persisted SAF marker state could not be cleared")
            }
        }

        setStage("create-marker")
        val markerName = "synctune-restore-${UUID.randomUUID()}.probe"
        val markerText = "synctune-saf-restore-${UUID.randomUUID()}"
        val markerUri = DocumentsContract.createDocument(
            contentResolver,
            DocumentsContract.buildDocumentUriUsingTree(treeUri, directory.id),
            "text/plain",
            markerName,
        ) ?: throw IllegalStateException("SAF provider could not create a restore marker")
        try {
            setStage("write-marker")
            contentResolver.openOutputStream(markerUri)?.use { output ->
                output.write(markerText.toByteArray(Charsets.UTF_8))
                output.flush()
            } ?: throw IllegalStateException("SAF provider could not write a restore marker")
            setStage("verify-marker")
            if (readSmallMarker(markerUri) != markerText) {
                throw IllegalStateException("SAF restore marker read-back did not match")
            }
            ensureActiveRoot(token, generation)
            setStage("persist-marker-record")
            val markerDocumentId = DocumentsContract.getDocumentId(markerUri)
            val treeScopedMarker = DocumentsContract.buildDocumentUriUsingTree(
                treeUri,
                markerDocumentId,
            )
            val record = "2\n${android.os.Process.myPid()}\n$markerName\n$treeScopedMarker\n$markerText"
            if (!probePreferences.edit().putString(preferenceKey, record).commit()) {
                throw IllegalStateException("SAF restore marker state could not be saved")
            }
        } catch (error: Exception) {
            try {
                DocumentsContract.deleteDocument(contentResolver, markerUri)
            } catch (_: Exception) {
                // Keep the primary probe failure; the unique hidden marker can
                // be inspected and cleaned by the next diagnostic run.
            }
            throw error
        }

        return mapOf(
            "status" to if (restartCheck == "ok") "ok" else "pending",
            "restartCheck" to restartCheck,
            "fileIo" to "ok",
            "token" to token,
            "generation" to generation,
            "marker" to markerName,
            "markerContent" to markerText,
            "restoredPid" to android.os.Process.myPid(),
            "path" to (grant["path"] as? String ?: ""),
        )
    }

    private fun readSmallMarker(uri: Uri): String {
        val input = contentResolver.openInputStream(uri)
            ?: throw IllegalStateException("SAF provider could not read a restore marker")
        return input.use { stream ->
            val bytes = ByteArrayOutputStream()
            val buffer = ByteArray(128)
            while (true) {
                val count = stream.read(buffer)
                if (count < 0) break
                if (bytes.size() + count > 1024) {
                    throw IllegalStateException("SAF restore marker exceeded its size limit")
                }
                bytes.write(buffer, 0, count)
            }
            bytes.toByteArray().toString(Charsets.UTF_8)
        }
    }

    private fun normalizedCredentialPart(raw: String?, label: String): String {
        val value = raw?.trim()?.map { character ->
            if (character in 'A'..'Z') {
                (character.code + 32).toChar()
            } else {
                character
            }
        }?.joinToString("")
            ?: throw IllegalArgumentException("missing credential $label")
        if (value.isEmpty() || value.length > 128) {
            throw IllegalArgumentException("invalid credential key")
        }
        if (value.any { it.code <= 31 || it.code == 127 || it in "/\\:" }) {
            throw IllegalArgumentException("invalid credential key")
        }
        return value
    }

    private fun credentialKey(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val existing = keyStore.getKey(credentialAlias, null) as? SecretKey
        if (existing != null) return existing
        val generator = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES,
            "AndroidKeyStore",
        )
        generator.init(
            KeyGenParameterSpec.Builder(
                credentialAlias,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true)
                .build(),
        )
        return generator.generateKey()
    }

    private fun credentialFile(service: String, account: String): File {
        val digest = MessageDigest.getInstance("SHA-256")
            .digest("$service\n$account".toByteArray(Charsets.UTF_8))
        val name = digest.joinToString("") { "%02x".format(it) }
        return File(File(filesDir, credentialDirectoryName), "$name.bin")
    }

    /** Encrypts the secret before it reaches the app-private credential file. */
    private fun saveCredential(service: String, account: String, secret: String) {
        val directory = File(filesDir, credentialDirectoryName)
        if (!directory.exists() && !directory.mkdirs()) {
            throw IllegalStateException("credential storage is unavailable")
        }
        val file = credentialFile(service, account)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        // Keystore owns the IV when randomized encryption is required. Passing
        // a caller IV here is rejected by AndroidKeyStore on supported API
        // levels and would weaken the key's randomized-encryption contract.
        cipher.init(Cipher.ENCRYPT_MODE, credentialKey())
        val iv = cipher.iv
        cipher.updateAAD("$service\n$account".toByteArray(Charsets.UTF_8))
        val encrypted = cipher.doFinal(secret.toByteArray(Charsets.UTF_8))
        val payload = ByteArray(iv.size + encrypted.size)
        iv.copyInto(payload, 0)
        encrypted.copyInto(payload, iv.size)
        val atomic = AtomicFile(file)
        var output: FileOutputStream? = null
        try {
            output = atomic.startWrite()
            output.write(payload)
            output.fd.sync()
            atomic.finishWrite(output)
            output = null
        } finally {
            if (output != null) atomic.failWrite(output)
        }
    }

    private fun readCredential(service: String, account: String): String? {
        val file = credentialFile(service, account)
        val payload = try {
            AtomicFile(file).openRead().use { it.readBytes() }
        } catch (_: FileNotFoundException) {
            return null
        }
        if (payload.size <= 12) throw IllegalStateException("credential record is invalid")
        val iv = payload.copyOfRange(0, 12)
        val encrypted = payload.copyOfRange(12, payload.size)
        try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, credentialKey(), GCMParameterSpec(128, iv))
            cipher.updateAAD("$service\n$account".toByteArray(Charsets.UTF_8))
            return String(cipher.doFinal(encrypted), Charsets.UTF_8)
        } catch (_: Exception) {
            // Do not expose provider or cryptographic details, and never fall
            // back to plaintext when the key or authentication tag is invalid.
            throw IllegalStateException("credential record is unavailable")
        }
    }

    private fun deleteCredential(service: String, account: String) {
        val file = credentialFile(service, account)
        val atomic = AtomicFile(file)
        atomic.delete()
        val leftovers = listOf(
            file,
            File(file.path + ".new"),
            File(file.path + ".bak"),
        )
        if (leftovers.any { it.exists() }) {
            throw IllegalStateException("credential deletion was not confirmed")
        }
    }

    private fun credentialSave(call: MethodCall): Map<String, Any?> {
        val service = normalizedCredentialPart(call.argument<String>("service"), "service")
        val account = normalizedCredentialPart(call.argument<String>("account"), "account")
        val secret = call.argument<String>("secret")
            ?: throw IllegalArgumentException("missing credential secret")
        saveCredential(service, account, secret)
        return mapOf("status" to "ok", "stored" to true)
    }

    private fun credentialRead(call: MethodCall): Map<String, Any?> {
        val service = normalizedCredentialPart(call.argument<String>("service"), "service")
        val account = normalizedCredentialPart(call.argument<String>("account"), "account")
        val secret = readCredential(service, account)
        return if (secret == null) {
            mapOf("status" to "ok", "found" to false)
        } else {
            // The secret is returned only to the authenticated Flutter engine;
            // it is never placed in logs, evidence, or an error message.
            mapOf("status" to "ok", "found" to true, "secret" to secret)
        }
    }

    private fun credentialDelete(call: MethodCall): Map<String, Any?> {
        val service = normalizedCredentialPart(call.argument<String>("service"), "service")
        val account = normalizedCredentialPart(call.argument<String>("account"), "account")
        deleteCredential(service, account)
        return mapOf("status" to "ok", "deleted" to true)
    }

    private fun credentialRoundTrip(): Map<String, Any?> {
        val service = "synctune.probe"
        val account = "probe-user"
        val secret = "synctune-probe-secret"
        val previous = readCredential(service, account)
        val restart = when {
            previous == null -> "pending"
            previous == secret -> "ok"
            else -> "failed"
        }
        saveCredential(service, account, secret)
        val found = readCredential(service, account) == secret
        return mapOf(
            "status" to if (found) "ok" else "failed",
            "restartCheck" to restart,
            "storage" to "android_keystore_aes_gcm_app_private",
        )
    }

    private fun brokerCapabilities(): Map<String, Any?> = mapOf(
        "status" to "ok",
        "platform" to "android",
        "credentials" to "android_keystore_aes_gcm_app_private",
        "staging" to "persistent_after_finish_root_scoped",
        "atomicCreate" to "verified_create_recovery",
        "conditionalReplace" to "verified_backup_replace",
        "conditionalDelete" to "verified_backup_delete",
        "temporaryPermission" to "not_verifiable",
    )

    private fun treeFlags(uri: Uri): Int? {
        val parent = DocumentsContract.buildDocumentUriUsingTree(
            uri,
            DocumentsContract.getTreeDocumentId(uri),
        )
        val flags = contentResolver.query(
            parent,
            arrayOf(DocumentsContract.Document.COLUMN_FLAGS),
            null,
            null,
            null,
        )?.use { cursor ->
            if (!cursor.moveToFirst()) return null
            cursor.getInt(0)
        } ?: return null
        return flags
    }

    private fun validateTreeUri(uri: Uri): Boolean {
        val parent = DocumentsContract.buildDocumentUriUsingTree(
            uri,
            DocumentsContract.getTreeDocumentId(uri),
        )
        val flags = treeFlags(uri) ?: return false
        if (flags and DocumentsContract.Document.FLAG_DIR_SUPPORTS_CREATE == 0) {
            return false
        }
        val name = "synctune_root_probe_${UUID.randomUUID()}.txt"
        val created = DocumentsContract.createDocument(
            contentResolver, parent, "text/plain", name,
        ) ?: return false
        return try {
            val expected = "synctune-root-${UUID.randomUUID()}"
            contentResolver.openOutputStream(created)?.use {
                it.write(expected.toByteArray())
            } ?: return false
            val actual = contentResolver.openInputStream(created)?.use {
                it.readBytes().toString(Charsets.UTF_8)
            }
            actual == expected
        } finally {
            if (!DocumentsContract.deleteDocument(contentResolver, created)) {
                throw IllegalStateException("SAF provider did not confirm probe cleanup")
            }
        }
    }

    private fun restoreRoot(result: MethodChannel.Result) {
        scanExecutor.execute {
            val response = restoreRootState()
            if (!isFinishing && !isDestroyed) {
                mainHandler.post {
                    if (!isFinishing && !isDestroyed) result.success(response)
                }
            }
        }
    }

    private fun revokeRoot(call: MethodCall, result: MethodChannel.Result) {
        val token = call.argument<String>("token")
        val generation = call.argument<String>("generation")
        if (token.isNullOrBlank() || generation.isNullOrBlank()) {
            result.error("root_identity", "The active root identity is missing.", null)
            return
        }
        if (rootBusy) {
            result.error("busy", "A folder picker is already open.", null)
            return
        }
        scanExecutor.execute {
            try {
                val response = revokeRootState(token, generation)
                postToLiveEngine { result.success(response) }
            } catch (error: Exception) {
                postToLiveEngine {
                    result.error("revoke_failed", error.message ?: error.toString(), null)
                }
            }
        }
    }

    private fun revokeRootState(token: String, generation: String): Map<String, Any?> {
        val prefs = getSharedPreferences(prefsName, MODE_PRIVATE)
        if (prefs.getString("token", null) != token ||
            prefs.getString("generation", null) != generation) {
            return mapOf("status" to "stale", "persisted" to "unchanged",
                "temporary" to "not_verifiable")
        }
        // Invalidate the generation before releasing provider state. Any
        // operation that reaches the broker afterwards is rejected, including
        // an operation already holding a document URI.
        if (!prefs.edit().clear().commit()) {
            throw IllegalStateException("Unable to clear the active root record")
        }
        stageSessions.entries.removeIf {
            it.value.token == token && it.value.generation == generation
        }
        readSessions.entries.filter {
            it.value.token == token && it.value.generation == generation
        }.forEach { closeRead(it.key) }
        val uri = Uri.parse(token)
        var releaseFailed = false
        contentResolver.persistedUriPermissions.filter { it.uri == uri }.forEach { permission ->
            var flags = 0
            if (permission.isReadPermission) flags = flags or Intent.FLAG_GRANT_READ_URI_PERMISSION
            if (permission.isWritePermission) flags = flags or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            if (flags != 0) {
                try {
                    contentResolver.releasePersistableUriPermission(uri, flags)
                } catch (_: Exception) {
                    releaseFailed = true
                }
            }
        }
        val remains = contentResolver.persistedUriPermissions.any { it.uri == uri }
        return mapOf(
            "status" to if (!releaseFailed && !remains) "ok" else "needs_rescan",
            "persisted" to when {
                remains -> "present"
                releaseFailed -> "unknown"
                else -> "revoked"
            },
            // Android does not expose a reliable query for transient grants.
            // Never claim that a temporary URI grant was revoked.
            "temporary" to "not_verifiable",
            "generation" to generation,
        )
    }

    private fun restoreRootState(): Map<String, Any> {
        val prefs = getSharedPreferences(prefsName, MODE_PRIVATE)
        val token = prefs.getString("token", null)
        val path = prefs.getString("path", null)
        val generation = prefs.getString("generation", null)
        if (token == null || path == null || generation == null) {
            return mapOf("status" to "none")
        }
        try {
            val uri = Uri.parse(token)
            val persisted = contentResolver.persistedUriPermissions.any {
                it.uri == uri && it.isReadPermission && it.isWritePermission
            }
            val flags = treeFlags(uri)
            if (!persisted || flags == null ||
                flags and DocumentsContract.Document.FLAG_DIR_SUPPORTS_CREATE == 0) {
                if (!prefs.edit().clear().commit()) {
                    return mapOf("status" to "failed")
                }
                return mapOf("status" to "revoked")
            }
            if (!reconcilePersistedRoots(uri)) {
                // Keep no active product root when the platform refuses to
                // release a stale grant. Continuing would leave a second
                // authorization active while the UI reports one root.
                if (!prefs.edit().clear().commit()) {
                    return mapOf("status" to "failed")
                }
                return mapOf("status" to "revoked")
            }
            return mapOf("status" to "ok", "token" to token,
                "path" to path, "generation" to generation)
        } catch (error: Exception) {
            return mapOf("status" to "failed",
                "error" to (error.message ?: error.toString()))
        }
    }

    private fun reconcilePersistedRoots(keep: Uri): Boolean {
        var failed = false
        contentResolver.persistedUriPermissions.toList().forEach { permission ->
            if (permission.uri == keep) return@forEach
            var flags = 0
            if (permission.isReadPermission) flags = flags or Intent.FLAG_GRANT_READ_URI_PERMISSION
            if (permission.isWritePermission) flags = flags or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            if (flags == 0) return@forEach
            try {
                contentResolver.releasePersistableUriPermission(permission.uri, flags)
            } catch (_: Exception) {
                failed = true
            }
        }
        return !failed && contentResolver.persistedUriPermissions.none { it.uri != keep }
    }

    private fun scanMusic(call: MethodCall, result: MethodChannel.Result) {
        val token = call.argument<String>("token")
        val generation = call.argument<String>("generation")
        if (token.isNullOrBlank() || generation.isNullOrBlank()) {
            result.error("root_identity", "The active root identity is missing.", null)
            return
        }
        scanExecutor.execute {
            try {
                val response = scanMusicTree(token, generation)
                postToLiveEngine {
                    result.success(response)
                }
            } catch (error: SecurityException) {
                postToLiveEngine {
                    result.error("root_revoked", error.message ?: "The root grant is unavailable.", null)
                }
            } catch (error: Exception) {
                postToLiveEngine {
                    result.error("scan_failed", error.message ?: error.toString(), null)
                }
            }
        }
    }

    /**
     * The broker protocol deliberately carries only a root token, generation,
     * and normalized relative path. It never accepts a filesystem path from
     * Dart. Bytes are bounded chunks so a provider cannot force a whole file
     * into the Flutter heap.
     */
    private fun brokerIdentity(call: MethodCall): Pair<String, String> {
        val token = call.argument<String>("token")
            ?: throw IllegalArgumentException("missing root token")
        val generation = call.argument<String>("generation")
            ?: throw IllegalArgumentException("missing root generation")
        ensureActiveRoot(token, generation)
        return token to generation
    }

    private fun normalizedSegments(raw: String): List<String> {
        if (raw.isEmpty() || raw.startsWith('/') || raw.contains('\\') ||
            Regex("^[A-Za-z]:").containsMatchIn(raw) || raw.contains('\u0000')) {
            throw IllegalArgumentException("path must be a canonical relative path")
        }
        val segments = raw.split('/')
        val reserved = setOf(
            "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5",
            "COM6", "COM7", "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4",
            "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
        )
        for (segment in segments) {
            val basename = segment.substringBefore('.').uppercase()
            if (segment.isEmpty() || segment == "." || segment == ".." ||
                segment.endsWith('.') || segment.endsWith(' ') || segment.contains(':') ||
                segment.any { it.code in 0..31 || it in "<>\"|?*" } ||
                basename in reserved || segment == ".synctune" || segment == ".synctune-local") {
                throw IllegalArgumentException("invalid relative path segment")
            }
        }
        return segments
    }

    private fun childDocument(treeUri: Uri, parentId: String, name: String): DocumentRef? {
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, parentId)
        contentResolver.query(
            children,
            arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE,
            ),
            null,
            null,
            null,
        )?.use { cursor ->
            val idIndex = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
            val nameIndex = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
            val mimeIndex = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_MIME_TYPE)
            while (cursor.moveToNext()) {
                if (idIndex < 0 || nameIndex < 0 || mimeIndex < 0) break
                if (cursor.getString(nameIndex) == name) {
                    val id = cursor.getString(idIndex)
                    val mime = cursor.getString(mimeIndex) ?: ""
                    return DocumentRef(
                        DocumentsContract.buildDocumentUriUsingTree(treeUri, id), id, mime,
                    )
                }
            }
        }
        return null
    }

    private fun resolveDocument(
        token: String,
        generation: String,
        path: String,
    ): DocumentRef? {
        ensureActiveRoot(token, generation)
        val treeUri = Uri.parse(token)
        var id = DocumentsContract.getTreeDocumentId(treeUri)
        var current: DocumentRef? = null
        for (segment in normalizedSegments(path)) {
            current = childDocument(treeUri, id, segment) ?: return null
            if (current.mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                id = current.id
            } else if (segment != normalizedSegments(path).last()) {
                return null
            }
        }
        ensureActiveRoot(token, generation)
        return current
    }

    private fun resolveParent(
        token: String,
        generation: String,
        path: String,
    ): Pair<Uri, String> {
        val segments = normalizedSegments(path)
        if (segments.size < 1) throw IllegalArgumentException("missing path")
        val treeUri = Uri.parse(token)
        var id = DocumentsContract.getTreeDocumentId(treeUri)
        for (segment in segments.dropLast(1)) {
            val child = childDocument(treeUri, id, segment)
                ?: throw IllegalStateException("parent directory is missing")
            if (child.mime != DocumentsContract.Document.MIME_TYPE_DIR) {
                throw IllegalStateException("parent is not a directory")
            }
            id = child.id
        }
        ensureActiveRoot(token, generation)
        return DocumentsContract.buildDocumentUriUsingTree(treeUri, id) to segments.last()
    }

    private fun stageDirectory(token: String, generation: String): DocumentRef {
        val treeUri = Uri.parse(token)
        val rootId = DocumentsContract.getTreeDocumentId(treeUri)
        val existing = childDocument(treeUri, rootId, ".synctune-local")
        if (existing != null) {
            if (existing.mime != DocumentsContract.Document.MIME_TYPE_DIR) {
                throw IllegalStateException(".synctune-local is not a directory")
            }
            return existing
        }
        val root = DocumentsContract.buildDocumentUriUsingTree(treeUri, rootId)
        val created = DocumentsContract.createDocument(
            contentResolver,
            root,
            DocumentsContract.Document.MIME_TYPE_DIR,
            ".synctune-local",
        ) ?: throw IllegalStateException("provider cannot create staging directory")
        return DocumentRef(created, DocumentsContract.getDocumentId(created),
            DocumentsContract.Document.MIME_TYPE_DIR)
    }

    private fun stageDocument(
        token: String,
        generation: String,
        key: String,
    ): DocumentRef {
        if (!stageKeyPattern.matches(key)) {
            throw IllegalArgumentException("invalid staging handle")
        }
        val directory = stageDirectory(token, generation)
        val found = childDocument(Uri.parse(token), directory.id, "$key.part")
            ?: throw IllegalStateException("staged object is missing")
        if (found.mime == DocumentsContract.Document.MIME_TYPE_DIR) {
            throw IllegalStateException("staged object is a directory")
        }
        return found
    }

    private fun readChunk(
        call: MethodCall, token: String, generation: String, resource: String,
        resolve: () -> DocumentRef,
    ): Map<String, Any?> {
        val offset = call.argument<Number>("offset")?.toLong() ?: 0L
        val maxBytes = call.argument<Number>("maxBytes")?.toInt() ?: 64 * 1024
        require(offset >= 0) { "offset must be non-negative" }
        require(maxBytes in 1..(1024 * 1024)) { "chunk size is out of range" }
        val now = System.currentTimeMillis()
        readSessions.entries.filter {
            it.value.token != token || it.value.generation != generation ||
                now - it.value.touchedAt > 60_000
        }.forEach { closeRead(it.key) }
        val providedHandle = call.argument<String>("readHandle")
        val handle = providedHandle ?: UUID.randomUUID().toString()
        val session = if (providedHandle == null) {
            require(offset == 0L) { "a new read must start at zero" }
            if (readSessions.size >= 16) throw IllegalStateException("too many open reads")
            val document = resolve()
            if (document.mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                throw IllegalStateException("path is a directory")
            }
            val input = contentResolver.openInputStream(document.uri)
                ?: throw IllegalStateException("provider cannot open file")
            ReadSession(token, generation, resource, input).also { readSessions[handle] = it }
        } else {
            readSessions[handle] ?: throw IllegalStateException("read session expired")
        }
        try {
            if (session.token != token || session.generation != generation ||
                session.resource != resource || session.nextOffset != offset) {
                throw SecurityException("read session scope or offset changed")
            }
            val stream = session.input
            val buffer = ByteArray(maxBytes)
            var total = 0
            var reachedEof = false
            while (total < maxBytes) {
                val count = stream.read(buffer, total, maxBytes - total)
                if (count < 0) {
                    reachedEof = true
                    break
                }
                if (count == 0) {
                    // InputStream permits a short read, but a zero-length
                    // read is not evidence of EOF. Probe one byte so cloud
                    // SAF providers cannot truncate a chunk at a transient
                    // short read.
                    val probe = stream.read()
                    if (probe < 0) {
                        reachedEof = true
                        break
                    }
                    buffer[total++] = probe.toByte()
                } else {
                    total += count
                }
            }
            val bytes = buffer.copyOf(total)
            session.nextOffset += total
            session.touchedAt = now
            ensureActiveRoot(token, generation)
            if (reachedEof) closeRead(handle)
            return mapOf("status" to "ok", "bytes" to bytes, "offset" to offset,
                "nextOffset" to session.nextOffset, "eof" to reachedEof, "readHandle" to handle)
        } catch (error: Exception) {
            closeRead(handle)
            throw error
        }
    }

    private fun localReadChunk(call: MethodCall): Map<String, Any?> {
        val (token, generation) = brokerIdentity(call)
        val path = call.argument<String>("path") ?: throw IllegalArgumentException("missing path")
        normalizedSegments(path)
        return readChunk(call, token, generation, "file:$path") {
            resolveDocument(token, generation, path) ?: throw IllegalStateException("file not found")
        }
    }

    private fun localStageBegin(call: MethodCall): Map<String, Any?> {
        val (token, generation) = brokerIdentity(call)
        val path = call.argument<String>("path") ?: throw IllegalArgumentException("missing path")
        normalizedSegments(path)
        val directory = stageDirectory(token, generation)
        ensureActiveRoot(token, generation)
        val key = UUID.randomUUID().toString()
        val uri = DocumentsContract.createDocument(
            contentResolver, DocumentsContract.buildDocumentUriUsingTree(Uri.parse(token), directory.id),
            "application/octet-stream", "$key.part",
        ) ?: throw IllegalStateException("provider cannot create staging object")
        val document = DocumentRef(uri, DocumentsContract.getDocumentId(uri),
            "application/octet-stream")
        stageSessions[key] = StageSession(token, generation, document)
        return mapOf("status" to "ok", "key" to key, "length" to 0L)
    }

    private fun localStageWrite(call: MethodCall): Map<String, Any?> {
        val (token, generation) = brokerIdentity(call)
        val key = call.argument<String>("key") ?: throw IllegalArgumentException("missing staging handle")
        val offset = call.argument<Number>("offset")?.toLong() ?: 0L
        val bytes = call.argument<ByteArray>("bytes")
            ?: throw IllegalArgumentException("missing chunk bytes")
        if (bytes.size > 1024 * 1024) throw IllegalArgumentException("chunk is too large")
        val session = stageSessions[key] ?: throw IllegalStateException("staging session is not open")
        if (session.token != token || session.generation != generation || session.nextOffset != offset) {
            throw SecurityException("staging root generation changed")
        }
        contentResolver.openOutputStream(session.document.uri, "wa")?.use { output ->
            output.write(bytes)
        } ?: throw IllegalStateException("provider cannot write staging object")
        ensureActiveRoot(token, generation)
        session.nextOffset += bytes.size
        return mapOf("status" to "ok", "nextOffset" to session.nextOffset)
    }

    private fun sha256Document(document: DocumentRef): Pair<String, Long> {
        val digest = MessageDigest.getInstance("SHA-256")
        var length = 0L
        val input = contentResolver.openInputStream(document.uri)
            ?: throw IllegalStateException("provider cannot open staged object")
        input.use { stream ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val count = stream.read(buffer)
                if (count < 0) break
                if (count == 0) {
                    val probe = stream.read()
                    if (probe < 0) break
                    digest.update(probe.toByte())
                    length++
                } else {
                    digest.update(buffer, 0, count)
                    length += count
                }
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) } to length
    }

    private fun localStageFinish(call: MethodCall): Map<String, Any?> {
        val (token, generation) = brokerIdentity(call)
        val key = call.argument<String>("key") ?: throw IllegalArgumentException("missing staging handle")
        val expected = call.argument<String>("expectedSha256")?.lowercase()
            ?: throw IllegalArgumentException("missing staging hash")
        if (!Regex("^[0-9a-f]{64}$").matches(expected)) {
            throw IllegalArgumentException("invalid staging hash")
        }
        val session = stageSessions[key] ?: throw IllegalStateException("staging session is not open")
        if (session.token != token || session.generation != generation) {
            throw SecurityException("staging root generation changed")
        }
        val (actual, length) = sha256Document(session.document)
        ensureActiveRoot(token, generation)
        if (length != session.nextOffset) {
            throw IllegalStateException("staging length does not match acknowledged writes")
        }
        stageSessions.remove(key)
        if (actual != expected) throw IllegalStateException("staging hash mismatch")
        return mapOf("status" to "ok", "key" to key, "sha256" to actual, "length" to length)
    }

    private fun localOpenStagedChunk(call: MethodCall): Map<String, Any?> {
        val (token, generation) = brokerIdentity(call)
        val key = call.argument<String>("key") ?: throw IllegalArgumentException("missing staging handle")
        return readChunk(call, token, generation, "stage:$key") {
            stageDocument(token, generation, key)
        }
    }

    private fun localVerifyStaged(call: MethodCall): Map<String, Any?> {
        val (token, generation) = brokerIdentity(call)
        val key = call.argument<String>("key") ?: throw IllegalArgumentException("missing staging handle")
        val expected = call.argument<String>("expectedSha256")?.lowercase()
            ?: throw IllegalArgumentException("missing staging hash")
        val expectedLength = call.argument<Number>("expectedLength")?.toLong()
            ?: throw IllegalArgumentException("missing staging length")
        if (!Regex("^[0-9a-f]{64}$").matches(expected) || expectedLength < 0) {
            throw IllegalArgumentException("invalid staging verification values")
        }
        val (actual, length) = sha256Document(stageDocument(token, generation, key))
        ensureActiveRoot(token, generation)
        return mapOf("status" to "ok", "valid" to (actual == expected && length == expectedLength),
            "sha256" to actual, "length" to length)
    }

    private fun backupDocument(
        token: String,
        generation: String,
        key: String,
    ): DocumentRef? {
        if (!stageKeyPattern.matches(key)) {
            throw IllegalArgumentException("invalid staging handle")
        }
        val directory = stageDirectory(token, generation)
        return childDocument(Uri.parse(token), directory.id, "$key.backup")
    }

    private fun createNamedDocument(
        token: String,
        generation: String,
        parent: Uri,
        parentId: String,
        name: String,
        mime: String,
    ): DocumentRef {
        val created = DocumentsContract.createDocument(
            contentResolver,
            parent,
            mime,
            name,
        ) ?: throw IllegalStateException("provider cannot create $name")
        val createdRef = DocumentRef(
            created,
            DocumentsContract.getDocumentId(created),
            mime,
        )
        val confirmed = childDocument(Uri.parse(token), parentId, name)
        if (confirmed == null || confirmed.id != createdRef.id) {
            try {
                DocumentsContract.deleteDocument(contentResolver, created)
            } catch (_: Exception) {
                // Leave the provider's unexpected name for a later rescan.
            }
            throw IllegalStateException("provider did not preserve requested filename")
        }
        ensureActiveRoot(token, generation)
        return confirmed
    }

    private fun copyDocumentBytes(source: DocumentRef, target: DocumentRef) {
        val input = contentResolver.openInputStream(source.uri)
            ?: throw IllegalStateException("provider cannot read source object")
        val output = contentResolver.openOutputStream(target.uri, "w")
            ?: throw IllegalStateException("provider cannot write destination object")
        input.use { sourceStream ->
            output.use { destination ->
                val buffer = ByteArray(64 * 1024)
                while (true) {
                    val count = sourceStream.read(buffer)
                    if (count < 0) break
                    if (count == 0) continue
                    destination.write(buffer, 0, count)
                }
                destination.flush()
            }
        }
    }

    private fun mimeForPath(path: String): String = when {
        path.endsWith(".mp3", ignoreCase = true) -> "audio/mpeg"
        path.endsWith(".flac", ignoreCase = true) -> "audio/flac"
        path.endsWith(".wav", ignoreCase = true) -> "audio/wav"
        path.endsWith(".m4a", ignoreCase = true) -> "audio/mp4"
        path.endsWith(".aac", ignoreCase = true) -> "audio/aac"
        path.endsWith(".ogg", ignoreCase = true) -> "audio/ogg"
        path.endsWith(".opus", ignoreCase = true) -> "audio/opus"
        else -> "application/octet-stream"
    }

    private fun publishDocument(
        token: String,
        generation: String,
        source: DocumentRef,
        path: String,
    ): DocumentRef {
        val (parent, name) = resolveParent(token, generation, path)
        val parentId = DocumentsContract.getDocumentId(parent)
        val target = createNamedDocument(
            token,
            generation,
            parent,
            parentId,
            name,
            mimeForPath(path),
        )
        try {
            copyDocumentBytes(source, target)
            ensureActiveRoot(token, generation)
            return target
        } catch (error: Exception) {
            try {
                DocumentsContract.deleteDocument(contentResolver, target.uri)
            } catch (_: Exception) {
                // Preserve the error and leave the staged evidence for recovery.
            }
            throw error
        }
    }

    private fun recoverMoveMarker(
        token: String,
        generation: String,
        key: String,
        expectedHash: String,
        path: String,
    ): DocumentRef? {
        val directory = stageDirectory(token, generation)
        val treeUri = Uri.parse(token)
        val stageParent = DocumentsContract.buildDocumentUriUsingTree(treeUri, directory.id)
        val stagedMove = childDocument(treeUri, directory.id, "$key.move")
        val sourceParent = resolveParent(token, generation, path).first
        val sourceMove = childDocument(
            treeUri,
            DocumentsContract.getDocumentId(sourceParent),
            "$key.move",
        )
        val marker = stagedMove ?: sourceMove ?: return null
        val moved = if (stagedMove != null) marker.uri else DocumentsContract.moveDocument(
            contentResolver, marker.uri, sourceParent, stageParent,
        ) ?: throw IllegalStateException("provider cannot resume recovery move")
        val renamed = DocumentsContract.renameDocument(
            contentResolver, moved, "$key.backup",
        ) ?: throw IllegalStateException("provider cannot finish recovery backup naming")
        val recovered = childDocument(treeUri, directory.id, "$key.backup")
            ?: throw IllegalStateException("provider did not expose the recovered backup")
        if (DocumentsContract.getDocumentId(renamed) != recovered.id) {
            throw IllegalStateException("provider returned an unexpected recovery backup")
        }
        ensureActiveRoot(token, generation)
        val (hash, _) = sha256Document(recovered)
        if (hash != expectedHash) {
            restoreBackup(token, generation, key, path)
            throw IllegalStateException("recoverable backup hash verification failed")
        }
        return recovered
    }

    private fun ensureBackup(
        token: String,
        generation: String,
        source: DocumentRef,
        key: String,
        expectedHash: String,
        sourceParent: Uri,
        path: String,
    ): DocumentRef {
        val existing = backupDocument(token, generation, key)
        if (existing != null) {
            val (hash, _) = sha256Document(existing)
            if (hash != expectedHash) {
                throw IllegalStateException("recoverable backup content changed")
            }
            return existing
        }
        val recoveredMarker = recoverMoveMarker(token, generation, key, expectedHash, path)
        if (recoveredMarker != null) return recoveredMarker
        val directory = stageDirectory(token, generation)
        val stageParent = DocumentsContract.buildDocumentUriUsingTree(
            Uri.parse(token),
            directory.id,
        )
        // Persist the operation key in the provider-visible name before the
        // move. A process exit between move and rename can then be resumed
        // without guessing from a basename shared by another directory.
        val marked = DocumentsContract.renameDocument(
            contentResolver,
            source.uri,
            "$key.move",
        ) ?: throw IllegalStateException(
            "provider cannot persist the recovery move record",
        )
        ensureActiveRoot(token, generation)
        val moved = DocumentsContract.moveDocument(
            contentResolver,
            marked,
            sourceParent,
            stageParent,
        ) ?: throw IllegalStateException(
            "provider cannot move the verified original into recovery storage",
        )
        val renamed = DocumentsContract.renameDocument(
            contentResolver,
            moved,
            "$key.backup",
        ) ?: throw IllegalStateException(
            "provider cannot name the recovery backup",
        )
        val backup = childDocument(Uri.parse(token), directory.id, "$key.backup")
            ?: throw IllegalStateException("provider did not expose the recovery backup")
        if (DocumentsContract.getDocumentId(renamed) != backup.id) {
            throw IllegalStateException("provider returned an unexpected recovery backup")
        }
        ensureActiveRoot(token, generation)
        val (hash, _) = sha256Document(backup)
        if (hash != expectedHash) {
            restoreBackup(token, generation, key, path)
            throw IllegalStateException("recoverable backup hash verification failed")
        }
        return backup
    }

    private fun restoreBackup(
        token: String,
        generation: String,
        key: String,
        path: String,
    ) {
        val backup = backupDocument(token, generation, key)
            ?: throw IllegalStateException("recoverable backup is missing")
        val directory = stageDirectory(token, generation)
        val stageParent = DocumentsContract.buildDocumentUriUsingTree(
            Uri.parse(token),
            directory.id,
        )
        val (parent, name) = resolveParent(token, generation, path)
        val existing = resolveDocument(token, generation, path)
        val restoreName = if (existing == null) {
            name
        } else {
            "$name.synctune-recovery-$key"
        }
        val moved = DocumentsContract.moveDocument(
            contentResolver,
            backup.uri,
            stageParent,
            parent,
        ) ?: throw IllegalStateException("provider cannot restore the recovery backup")
        val renamed = DocumentsContract.renameDocument(contentResolver, moved, restoreName)
            ?: throw IllegalStateException("provider cannot restore the original filename")
        val restored = childDocument(
            Uri.parse(token),
            DocumentsContract.getDocumentId(parent),
            restoreName,
        ) ?: throw IllegalStateException("provider did not expose the restored file")
        if (DocumentsContract.getDocumentId(renamed) != restored.id) {
            throw IllegalStateException("provider returned an unexpected restored file")
        }
        ensureActiveRoot(token, generation)
    }

    private fun finishLocalCommit(
        token: String,
        generation: String,
        staged: DocumentRef,
        path: String,
        expectedHash: String,
        expectedLength: Long,
    ): DocumentRef {
        val published = publishDocument(token, generation, staged, path)
        val (actual, length) = sha256Document(published)
        ensureActiveRoot(token, generation)
        if (actual != expectedHash || length != expectedLength) {
            // Keep the published bytes visible for reconciliation. They may
            // have changed after publication; deleting unknown content would
            // turn a recoverable conflict into data loss.
            throw IllegalStateException("published content verification failed")
        }
        return published
    }

    private fun localCommitStaged(call: MethodCall): Map<String, Any?> {
        val (token, generation) = brokerIdentity(call)
        val path = call.argument<String>("path") ?: throw IllegalArgumentException("missing path")
        val key = call.argument<String>("key") ?: throw IllegalArgumentException("missing staging handle")
        val condition = call.argument<Map<*, *>>("condition")
            ?: throw IllegalArgumentException("missing local condition")
        val document = stageDocument(token, generation, key)
        val entry = call.argument<Map<*, *>>("entry")
            ?: throw IllegalArgumentException("missing source entry")
        val expectedHash = entry["sha256"]?.toString()?.lowercase()
            ?: throw IllegalArgumentException("missing source hash")
        val expectedLength = (entry["size"] as? Number)?.toLong()
            ?: throw IllegalArgumentException("missing source length")
        val (stagedHash, stagedLength) = sha256Document(document)
        ensureActiveRoot(token, generation)
        if (stagedHash != expectedHash || stagedLength != expectedLength) {
            throw IllegalStateException("staging bytes do not match source metadata")
        }
        val existing = resolveDocument(token, generation, path)
        ensureActiveRoot(token, generation)
        val conditionType = condition["type"]?.toString()
        if (conditionType == "createOnly") {
            if (existing != null) {
                val (actual, length) = sha256Document(existing)
                if (actual != stagedHash || length != stagedLength) {
                    throw SecurityException("local create-only precondition failed")
                }
                return mapOf("status" to "ok", "path" to path, "sha256" to actual,
                    "length" to length, "mode" to "verified_create_recovery")
            }
            finishLocalCommit(token, generation, document, path, expectedHash, expectedLength)
        } else if (conditionType == "matchSha256") {
            val match = condition["sha256"]?.toString()?.lowercase()
            if (existing == null || match == null || !Regex("^[0-9a-f]{64}$").matches(match)) {
                if (existing == null && match != null && Regex("^[0-9a-f]{64}$").matches(match)) {
                    val recovered = recoverMoveMarker(token, generation, key, match, path)
                    if (recovered != null) {
                        finishLocalCommit(token, generation, document, path, expectedHash, expectedLength)
                        return mapOf("status" to "ok", "path" to path,
                            "sha256" to expectedHash, "length" to expectedLength,
                            "mode" to "verified_backup_replace")
                    }
                }
                throw SecurityException("local hash precondition failed")
            }
            val (actual, _) = sha256Document(existing)
            ensureActiveRoot(token, generation)
            if (actual == stagedHash) {
                return mapOf("status" to "ok", "path" to path, "sha256" to actual,
                    "length" to stagedLength, "mode" to "already_committed")
            }
            if (actual != match) throw SecurityException("local hash precondition failed")
            val priorBackup = backupDocument(token, generation, key)
            if (priorBackup != null) {
                throw SecurityException("recovery backup and target both exist; rescan required")
            }
            val (sourceParent, _) = resolveParent(token, generation, path)
            ensureBackup(token, generation, existing, key, match, sourceParent, path)
            try {
                finishLocalCommit(token, generation, document, path, expectedHash, expectedLength)
            } catch (error: Exception) {
                if (resolveDocument(token, generation, path) == null) {
                    restoreBackup(token, generation, key, path)
                }
                throw error
            }
        } else {
            throw IllegalArgumentException("unsupported local condition")
        }
        return mapOf("status" to "ok", "path" to path, "sha256" to stagedHash,
            "length" to stagedLength, "mode" to "verified_backup_replace")
    }

    private fun localDelete(call: MethodCall): Map<String, Any?> {
        val (token, generation) = brokerIdentity(call)
        val path = call.argument<String>("path") ?: throw IllegalArgumentException("missing path")
        val condition = call.argument<Map<*, *>>("condition")
            ?: throw IllegalArgumentException("missing local condition")
        if (condition["type"]?.toString() != "matchSha256") {
            throw IllegalArgumentException("local delete requires a hash condition")
        }
        val expected = condition["sha256"]?.toString()?.lowercase()
            ?: throw IllegalArgumentException("missing local delete hash")
        val backupKey = call.argument<String>("backupKey")
            ?: throw IllegalArgumentException("missing local delete backup handle")
        if (!stageKeyPattern.matches(backupKey)) {
            throw IllegalArgumentException("invalid local delete backup handle")
        }
        val priorBackup = backupDocument(token, generation, backupKey)
        val document = resolveDocument(token, generation, path)
        if (document == null) {
            if (priorBackup != null) {
                val (backupHash, _) = sha256Document(priorBackup)
                if (backupHash == expected) {
                    return mapOf("status" to "ok", "path" to path,
                        "sha256" to expected, "mode" to "already_deleted_recovery")
                }
            }
            val recovered = recoverMoveMarker(token, generation, backupKey, expected, path)
            if (recovered != null) {
                return mapOf("status" to "ok", "path" to path,
                    "sha256" to expected, "mode" to "already_deleted_recovery")
            }
            throw SecurityException("local delete target missing; rescan required")
        }
        if (priorBackup != null) {
            throw SecurityException("recovery backup and target both exist; rescan required")
        }
        val (actual, _) = sha256Document(document)
        ensureActiveRoot(token, generation)
        if (actual != expected) throw SecurityException("local delete precondition failed")
        val (sourceParent, _) = resolveParent(token, generation, path)
        ensureBackup(token, generation, document, backupKey, expected, sourceParent, path)
        val current = resolveDocument(token, generation, path)
        if (current != null) {
            throw SecurityException("provider did not move the verified delete target")
        }
        ensureActiveRoot(token, generation)
        return mapOf("status" to "ok", "path" to path,
            "sha256" to expected, "mode" to "verified_backup_delete")
    }

    private fun postToLiveEngine(action: () -> Unit) {
        if (!engineAlive || isFinishing || isDestroyed) return
        mainHandler.post {
            if (engineAlive && !isFinishing && !isDestroyed) action()
        }
    }

    private fun brokerCall(
        result: MethodChannel.Result,
        operation: () -> Map<String, Any?>,
    ) {
        scanExecutor.execute {
            try {
                val response = operation()
                postToLiveEngine { result.success(response) }
            } catch (error: SecurityException) {
                postToLiveEngine {
                    result.error("root_revoked", error.message ?: "The root grant is unavailable.", null)
                }
            } catch (error: IllegalArgumentException) {
                postToLiveEngine {
                    result.error("invalid_argument", error.message ?: "Invalid broker argument.", null)
                }
            } catch (error: Exception) {
                postToLiveEngine {
                    result.error("broker_error", error.message ?: error.toString(), null)
                }
            }
        }
    }

    private fun scanMusicTree(token: String, generation: String): Map<String, Any> {
        val prefs = getSharedPreferences(prefsName, MODE_PRIVATE)
        if (prefs.getString("token", null) != token ||
            prefs.getString("generation", null) != generation) {
            throw SecurityException("The authorized root generation changed.")
        }
        val uri = Uri.parse(token)
        val persisted = contentResolver.persistedUriPermissions.any {
            it.uri == uri && it.isReadPermission && it.isWritePermission
        }
        val flags = treeFlags(uri)
        if (!persisted || flags == null ||
            flags and DocumentsContract.Document.FLAG_DIR_SUPPORTS_CREATE == 0) {
            throw SecurityException("The authorized root grant is revoked.")
        }
        val items = mutableListOf<Map<String, Any>>()
        val complete = booleanArrayOf(true)
        scanDocument(uri, DocumentsContract.getTreeDocumentId(uri), "", items, complete, 0,
            token, generation)
        if (prefs.getString("token", null) != token ||
            prefs.getString("generation", null) != generation ||
            contentResolver.persistedUriPermissions.none {
                it.uri == uri && it.isReadPermission && it.isWritePermission
            }) {
            throw SecurityException("The authorized root generation changed during scan.")
        }
        return mapOf(
            "status" to "ok",
            "generation" to generation,
            "complete" to complete[0],
            "items" to items,
        )
    }

    private fun scanDocument(
        treeUri: Uri,
        documentId: String,
        relativeDirectory: String,
        items: MutableList<Map<String, Any>>,
        complete: BooleanArray,
        depth: Int,
        token: String,
        generation: String,
    ) {
        if (depth > 64 || items.size >= 10_000) {
            complete[0] = false
            return
        }
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, documentId)
        contentResolver.query(
            children,
            arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE,
                DocumentsContract.Document.COLUMN_SIZE,
            ),
            null,
            null,
            null,
        )?.use { cursor ->
            val idIndex = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
            val nameIndex = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
            val mimeIndex = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_MIME_TYPE)
            val sizeIndex = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_SIZE)
            while (cursor.moveToNext()) {
                ensureActiveRoot(token, generation)
                if (items.size >= 10_000) {
                    complete[0] = false
                    return@use
                }
                val childId = cursor.getString(idIndex)
                val name = cursor.getString(nameIndex) ?: continue
                if (name == ".synctune" || name == ".synctune-local") continue
                if (name.isEmpty() || name == "." || name == ".." ||
                    name.contains('/') || name.contains('\\')) {
                    complete[0] = false
                    continue
                }
                val relative = if (relativeDirectory.isEmpty()) {
                    name
                } else {
                    "$relativeDirectory/$name"
                }
                try {
                    // Apply the same canonical segment policy to provider
                    // results that broker reads and writes use. A provider
                    // can expose names containing ADS/device aliases or
                    // control characters even when the host filesystem would
                    // normally reject them.
                    normalizedSegments(relative)
                } catch (_: IllegalArgumentException) {
                    complete[0] = false
                    continue
                }
                val mime = cursor.getString(mimeIndex)
                if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                    scanDocument(treeUri, childId, relative, items, complete, depth + 1,
                        token, generation)
                    continue
                }
                val dot = name.lastIndexOf('.')
                if (dot <= 0 || dot == name.lastIndex) continue
                val extension = name.substring(dot + 1).lowercase()
                if (extension !in musicExtensions) continue
                if (sizeIndex < 0 || cursor.isNull(sizeIndex)) {
                    complete[0] = false
                    continue
                }
                val size = if (!cursor.isNull(sizeIndex)) {
                    cursor.getLong(sizeIndex)
                } else {
                    complete[0] = false
                    continue
                }
                if (size < 0) {
                    complete[0] = false
                    continue
                }
                items += mapOf(
                    "relativePath" to relative,
                    "size" to size,
                    "extension" to extension,
                )
            }
        } ?: throw IllegalStateException("The provider did not return directory entries.")
    }

    private fun ensureActiveRoot(token: String, generation: String) {
        if (!engineAlive || isFinishing || isDestroyed) {
            throw SecurityException("The Flutter engine is no longer alive.")
        }
        val prefs = getSharedPreferences(prefsName, MODE_PRIVATE)
        if (prefs.getString("token", null) != token ||
            prefs.getString("generation", null) != generation) {
            throw SecurityException("The authorized root generation changed.")
        }
        val uri = Uri.parse(token)
        if (contentResolver.persistedUriPermissions.none {
                it.uri == uri && it.isReadPermission && it.isWritePermission
            }) {
            throw SecurityException("The authorized root grant is revoked.")
        }
    }

    @Deprecated("Deprecated in Android API Activity", ReplaceWith("super.onActivityResult(requestCode, resultCode, data)"))
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != pickRootRequest) return
        val result = pendingRootResult
        pendingRootResult = null
        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            rootBusy = false
            result?.success(mapOf("status" to "cancelled"))
            return
        }
        val uri: Uri = data.data!!
        val hadPersistedGrant = contentResolver.persistedUriPermissions.any {
            it.uri == uri && it.isReadPermission && it.isWritePermission
        }
        val grantFlags = data.flags and
            (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        if (grantFlags != (Intent.FLAG_GRANT_READ_URI_PERMISSION or
                Intent.FLAG_GRANT_WRITE_URI_PERMISSION)) {
            rootBusy = false
            result?.error("saf_permission", "The provider did not return read/write access.", null)
            return
        }
        scanExecutor.execute {
            var retained = false
            try {
                contentResolver.takePersistableUriPermission(uri, grantFlags)
                // A provider may return the currently authorized root again.
                // Do not release that grant if validation or reconciliation
                // fails; doing so would destroy the still-valid old root.
                retained = !hadPersistedGrant
                if (!validateTreeUri(uri)) {
                    throw SecurityException("Selected root does not support read/write operations.")
                }
                val generation = UUID.randomUUID().toString()
                val prefs = getSharedPreferences(prefsName, MODE_PRIVATE)
                if (!prefs.edit().putString("token", uri.toString())
                        .putString("path", uri.toString())
                        .putString("generation", generation).commit()) {
                    throw IllegalStateException("Unable to persist selected root.")
                }
                var reconciliationFailed = false
                contentResolver.persistedUriPermissions.toList().forEach { permission ->
                    if (permission.uri != uri) {
                        try {
                            contentResolver.releasePersistableUriPermission(
                                permission.uri,
                                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
                            )
                        } catch (_: SecurityException) {
                            reconciliationFailed = true
                        }
                    }
                }
                if (contentResolver.persistedUriPermissions.any { it.uri != uri } ||
                    reconciliationFailed) {
                    // Re-selecting the current URI must not clear the only
                    // active record when a provider transiently refuses to
                    // reconcile another stale grant. A different URI is
                    // stopped and left for explicit recovery.
                    if (!hadPersistedGrant) prefs.edit().clear().commit()
                    throw SecurityException("Unable to revoke previous folder grants.")
                }
                val response = mapOf<String, Any>(
                    "status" to "ok",
                    "token" to uri.toString(),
                    "path" to uri.toString(),
                    "generation" to generation,
                )
                mainHandler.post {
                    rootBusy = false
                    if (!isFinishing && !isDestroyed) result?.success(response)
                }
            } catch (error: Exception) {
                if (retained) {
                    try {
                        contentResolver.releasePersistableUriPermission(
                            uri,
                            Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
                        )
                    } catch (_: Exception) {
                    }
                }
                mainHandler.post {
                    rootBusy = false
                    if (!isFinishing && !isDestroyed) {
                        result?.error("saf_permission", error.message, null)
                    }
                }
            }
        }
    }

    private fun requestNotificationPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED) {
                result.success(mapOf("status" to "granted"))
            } else {
                pendingNotificationResult = result
                requestPermissions(
                    arrayOf(android.Manifest.permission.POST_NOTIFICATIONS),
                    notificationPermissionRequest,
                )
            }
        } else {
            result.success(mapOf("status" to "granted"))
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == notificationPermissionRequest) {
            val granted = grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
            pendingNotificationResult?.success(
                mapOf("status" to if (granted) "granted" else "denied")
            )
            pendingNotificationResult = null
        }
    }

    override fun onDestroy() {
        engineAlive = false
        readSessions.keys.toList().forEach { closeRead(it) }
        pendingRootResult?.let {
            try {
                it.error("activity_destroyed", "Folder picker activity was closed.", null)
            } catch (_: Exception) {
            }
        }
        pendingRootResult = null
        pendingNotificationResult = null
        rootBusy = false
        scanExecutor.shutdownNow()
        super.onDestroy()
    }
}
