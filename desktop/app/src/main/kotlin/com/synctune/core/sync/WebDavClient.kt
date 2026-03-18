package com.synctune.core.sync

import okhttp3.Credentials
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.File
import java.net.URLDecoder
import java.net.URLEncoder
import java.text.SimpleDateFormat
import java.util.*
import javax.xml.parsers.DocumentBuilderFactory

data class WebDavFile(
    val name: String,
    val size: Long,
    val path: String,
    val modifiedDate: Date,
    val isDirectory: Boolean
)

class WebDavClient(
    private val baseUrl: String,
    private val username: String,
    private val password: String
) {
    private val client = OkHttpClient()
    private val dateFormat = SimpleDateFormat("EEE, dd MMM yyyy HH:mm:ss z", Locale.US)
    private val isoFormat = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US).apply {
        timeZone = TimeZone.getTimeZone("UTC")
    }

    private fun authHeader(): String? {
        if (username.isBlank() && password.isBlank()) return null
        return Credentials.basic(username, password)
    }

    fun testConnection(): Result<Unit> {
        return try {
            val req = Request.Builder().url(baseUrl).apply {
                authHeader()?.let { header("Authorization", it) }
                header("Depth", "0")
                method("PROPFIND", "".toRequestBody(null))
            }.build()

            client.newCall(req).execute().use { resp ->
                if (resp.isSuccessful) Result.success(Unit)
                else Result.failure(Exception("HTTP ${resp.code}: ${resp.message}"))
            }
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    fun listFiles(): List<WebDavFile> {
        return try {
            val req = Request.Builder().url(baseUrl).apply {
                authHeader()?.let { header("Authorization", it) }
                header("Depth", "1")
                method("PROPFIND", "".toRequestBody(null))
            }.build()

            client.newCall(req).execute().use { resp ->
                if (!resp.isSuccessful) return emptyList()
                val body = resp.body?.string() ?: return emptyList()
                parsePropfindResponse(body)
            }
        } catch (e: Exception) {
            e.printStackTrace()
            emptyList()
        }
    }

    private fun parsePropfindResponse(xml: String): List<WebDavFile> {
        val files = mutableListOf<WebDavFile>()
        try {
            val factory = DocumentBuilderFactory.newInstance().apply {
                isNamespaceAware = true
            }
            val builder = factory.newDocumentBuilder()
            val doc = builder.parse(xml.byteInputStream())
            val responses = doc.getElementsByTagNameNS("*", "response")
            
            for (i in 0 until responses.getLength()) {
                val response = responses.item(i)
                val rawHref = getChildText(response, "href") ?: continue
                val href = URLDecoder.decode(rawHref, "UTF-8")
                
                val propstat = getChildElement(response, "propstat")
                val prop = propstat?.let { getChildElement(it, "prop") } ?: continue
                
                val rawDisplayName = getChildText(prop, "displayname")
                val displayName = if (rawDisplayName != null) {
                    URLDecoder.decode(rawDisplayName, "UTF-8")
                } else {
                    href.removeSuffix("/").substringAfterLast("/").ifBlank { href }
                }
                
                val contentLength = getChildText(prop, "getcontentlength")?.toLongOrNull() ?: 0L
                val lastModifiedStr = getChildText(prop, "getlastmodified")
                val lastModified = lastModifiedStr?.let { parseDate(it) } ?: Date(0)
                val resType = getChildElement(prop, "resourcetype")
                val isDir = resType?.getElementsByTagNameNS("*", "collection")?.length ?: 0 > 0
                
                // Skip the base directory itself
                val normalizedHref = href.removeSuffix("/")
                val urlPath = if (baseUrl.startsWith("http")) {
                    val path = baseUrl.substringAfter("://").substringAfter("/", "")
                    if (path.isEmpty()) "" else "/$path".removeSuffix("/")
                } else ""
                
                if (normalizedHref == urlPath || normalizedHref == urlPath.removePrefix("/")) {
                    if (i == 0) continue
                }

                files.add(WebDavFile(displayName, contentLength, href, lastModified, isDir))
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
        return files
    }

    private fun parseDate(dateStr: String): Date {
        return try { dateFormat.parse(dateStr) } catch (e: Exception) {
            try { isoFormat.parse(dateStr) } catch (e2: Exception) { Date(0) }
        }
    }

    private fun getChildText(node: org.w3c.dom.Node, tagName: String): String? {
        val elements = (node as? org.w3c.dom.Element)?.getElementsByTagNameNS("*", tagName)
        return if (elements != null && elements.length > 0) elements.item(0).textContent else null
    }

    private fun getChildElement(node: org.w3c.dom.Node, tagName: String): org.w3c.dom.Element? {
        val elements = (node as? org.w3c.dom.Element)?.getElementsByTagNameNS("*", tagName)
        return if (elements != null && elements.length > 0) elements.item(0) as? org.w3c.dom.Element else null
    }

    fun downloadFile(remoteFileName: String, target: File): Boolean {
        val encodedName = URLEncoder.encode(remoteFileName, "UTF-8").replace("+", "%20")
        val url = combine(baseUrl, encodedName)
        val req = Request.Builder().url(url).apply {
            authHeader()?.let { header("Authorization", it) }
            get()
        }.build()
        
        return try {
            client.newCall(req).execute().use { resp ->
                if (!resp.isSuccessful) return false
                val body = resp.body ?: return false
                target.parentFile?.mkdirs()
                target.outputStream().use { body.byteStream().copyTo(it) }
                true
            }
        } catch (e: Exception) { e.printStackTrace(); false }
    }

    fun uploadFile(remoteFileName: String, content: ByteArray, contentType: String = "application/json"): Boolean {
        val encodedName = URLEncoder.encode(remoteFileName, "UTF-8").replace("+", "%20")
        val url = combine(baseUrl, encodedName)
        val body = content.toRequestBody(contentType.toMediaType())
        val req = Request.Builder().url(url).apply {
            authHeader()?.let { header("Authorization", it) }
            put(body)
        }.build()
        
        return try {
            client.newCall(req).execute().use { it.isSuccessful }
        } catch (e: Exception) { e.printStackTrace(); false }
    }

    private fun combine(base: String, path: String): String {
        val b = base.removeSuffix("/")
        val p = if (path.startsWith("/")) path else "/$path"
        return b + p
    }
}
