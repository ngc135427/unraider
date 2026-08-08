package com.ngc.unraider

import android.content.Context
import android.content.ContentUris
import android.app.Activity
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.util.Base64
import android.util.Log
import android.util.Size
import com.hierynomus.msdtyp.AccessMask
import com.hierynomus.msfscc.FileAttributes
import com.hierynomus.mssmb2.SMB2CreateDisposition
import com.hierynomus.mssmb2.SMB2CreateOptions
import com.hierynomus.mssmb2.SMB2ShareAccess
import com.hierynomus.smbj.SMBClient
import com.hierynomus.smbj.SmbConfig
import com.hierynomus.smbj.auth.AuthenticationContext
import com.hierynomus.smbj.connection.Connection
import com.hierynomus.smbj.share.DiskShare
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileWriter
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.text.SimpleDateFormat
import java.util.Date
import java.util.EnumSet
import java.util.Locale
import java.util.UUID
import java.util.concurrent.TimeUnit
import java.security.MessageDigest
import kotlin.system.exitProcess

class MainActivity : AudioServiceActivity() {
    companion object {
        private const val LOG_TAG = "UnraiderLog"
        private const val DELETE_MEDIA_REQUEST = 8427
        @Volatile private var uncaughtHandlerInstalled = false
    }

    private val smbCacheLock = Any()
    private var cachedSmbKey: String? = null
    private var cachedSmbClient: SMBClient? = null
    private var cachedSmbConnection: Connection? = null
    private var cachedSmbShare: DiskShare? = null
    private var pendingDeleteResult: MethodChannel.Result? = null
    private var pendingDeleteUris: List<Uri> = emptyList()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        installUncaughtHandler()

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "unraider/login_preferences"
        ).setMethodCallHandler { call, result ->
            val preferences = getSharedPreferences("login_preferences", Context.MODE_PRIVATE)

            when (call.method) {
                "load" -> {
                    result.success(
                        mapOf(
                            "rememberMe" to preferences.getBoolean("rememberMe", false),
                            "domain" to preferences.getString("domain", ""),
                            "username" to preferences.getString("username", "root"),
                            "password" to preferences.getString("password", ""),
                            "useHttps" to preferences.getBoolean("useHttps", false),
                        )
                    )
                }
                "save" -> {
                    val rememberMe = call.argument<Boolean>("rememberMe") ?: false
                    val editor = preferences.edit().putBoolean("rememberMe", rememberMe)

                    if (rememberMe) {
                        editor
                            .putString("domain", call.argument<String>("domain") ?: "")
                            .putString("username", call.argument<String>("username") ?: "root")
                            .putString("password", call.argument<String>("password") ?: "")
                            .putBoolean("useHttps", call.argument<Boolean>("useHttps") ?: false)
                    } else {
                        editor
                            .remove("domain")
                            .remove("username")
                            .remove("password")
                            .remove("useHttps")
                    }

                    editor.apply()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "unraider/album_preferences"
        ).setMethodCallHandler { call, result ->
            val preferences = getSharedPreferences("album_preferences", Context.MODE_PRIVATE)

            when (call.method) {
                "load" -> {
                    val deviceId = preferences.getString("deviceId", null)
                        ?.takeIf { it.isNotBlank() }
                        ?: UUID.randomUUID().toString().also { generated ->
                            preferences.edit().putString("deviceId", generated).apply()
                        }
                    result.success(
                        mapOf(
                            "targetDir" to preferences.getString("targetDir", "/mnt/user/photos/mobile"),
                            "sourceId" to preferences.getString("sourceId", ""),
                            "sourceIds" to preferences.getStringSet("sourceIds", emptySet())?.toList(),
                            "sourceName" to preferences.getString("sourceName", "本机所有照片"),
                            "autoBackup" to preferences.getBoolean("autoBackup", true),
                            "initialBackupMode" to preferences.getString("initialBackupMode", "all"),
                            "deviceId" to deviceId,
                            "deviceName" to preferences.getString("deviceName", Build.MODEL)!!,
                            "wifiOnly" to preferences.getBoolean("wifiOnly", true),
                            "chargingOnly" to preferences.getBoolean("chargingOnly", false),
                            "transferConcurrency" to preferences.getInt("transferConcurrency", 2),
                        )
                    )
                }
                "save" -> {
                    preferences.edit()
                        .putBoolean("autoBackup", call.argument<Boolean>("autoBackup") ?: true)
                        .putString("targetDir", call.argument<String>("targetDir") ?: "/mnt/user/photos/mobile")
                        .putString("sourceId", call.argument<String>("sourceId") ?: "")
                        .putStringSet(
                            "sourceIds",
                            call.argument<List<String>>("sourceIds")?.toSet() ?: emptySet()
                        )
                        .putString("sourceName", call.argument<String>("sourceName") ?: "本机所有照片")
                        .putString("initialBackupMode", call.argument<String>("initialBackupMode") ?: "all")
                        .putString("deviceId", call.argument<String>("deviceId") ?: "")
                        .putString("deviceName", call.argument<String>("deviceName") ?: Build.MODEL)
                        .putBoolean("wifiOnly", call.argument<Boolean>("wifiOnly") ?: true)
                        .putBoolean("chargingOnly", call.argument<Boolean>("chargingOnly") ?: false)
                        .putInt("transferConcurrency", call.argument<Int>("transferConcurrency") ?: 2)
                        .apply()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "unraider/video_stream_preferences"
        ).setMethodCallHandler { call, result ->
            val preferences = getSharedPreferences("video_stream_preferences", Context.MODE_PRIVATE)
            val legacy = getSharedPreferences("login_preferences", Context.MODE_PRIVATE)

            when (call.method) {
                "load" -> {
                    val hasCurrentConfig = preferences.contains("webDavUrl") ||
                        preferences.contains("apiToken")
                    val webDavUrl = if (hasCurrentConfig) {
                        preferences.getString("webDavUrl", "") ?: ""
                    } else {
                        legacy.getString("webDavUrl", "") ?: ""
                    }
                    val apiToken = if (hasCurrentConfig) {
                        preferences.getString("apiToken", "") ?: ""
                    } else {
                        legacy.getString("webDavToken", "") ?: ""
                    }
                    val pathPrefix = if (hasCurrentConfig) {
                        preferences.getString("unraidPathPrefix", "/mnt/user") ?: "/mnt/user"
                    } else {
                        legacy.getString("webDavPathPrefix", "/mnt/user") ?: "/mnt/user"
                    }
                    result.success(
                        mapOf(
                            "enabled" to if (hasCurrentConfig) {
                                preferences.getBoolean("enabled", false)
                            } else {
                                webDavUrl.isNotBlank() && apiToken.isNotBlank()
                            },
                            "webDavUrl" to webDavUrl,
                            "unraidPathPrefix" to pathPrefix,
                            "apiToken" to apiToken,
                        )
                    )
                }
                "save" -> {
                    preferences.edit()
                        .putBoolean("enabled", call.argument<Boolean>("enabled") ?: false)
                        .putString("webDavUrl", call.argument<String>("webDavUrl") ?: "")
                        .putString("unraidPathPrefix", call.argument<String>("unraidPathPrefix") ?: "/mnt/user")
                        .putString("apiToken", call.argument<String>("apiToken") ?: "")
                        .apply()
                    legacy.edit()
                        .remove("webDavUrl")
                        .remove("webDavPathPrefix")
                        .remove("webDavToken")
                        .apply()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "unraider/local_media"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "listMedia" -> {
                    val limit = call.argument<Int>("limit") ?: 0
                    val bucketId = call.argument<String>("bucketId")
                    val modifiedAfterMs = call.argument<Number>("modifiedAfterMs")?.toLong()
                    result.success(listMedia(limit, bucketId, modifiedAfterMs))
                }
                "listImages" -> {
                    val limit = call.argument<Int>("limit") ?: 0
                    val bucketId = call.argument<String>("bucketId")
                    val modifiedAfterMs = call.argument<Number>("modifiedAfterMs")?.toLong()
                    result.success(listMedia(limit, bucketId, modifiedAfterMs))
                }
                "listBuckets" -> result.success(listBuckets())
                "loadThumbnail" -> {
                    val uri = call.argument<String>("uri")
                    val size = call.argument<Int>("size") ?: 320
                    if (uri.isNullOrBlank()) {
                        result.success(null)
                    } else {
                        result.success(loadThumbnail(uri, size))
                    }
                }
                "readChunk" -> {
                    val uri = call.argument<String>("uri")
                    val offset = (call.argument<Number>("offset") ?: 0).toLong()
                    val length = call.argument<Int>("length") ?: 0
                    if (uri.isNullOrBlank() || length <= 0) {
                        result.success(ByteArray(0))
                    } else {
                        Thread {
                            try {
                                val bytes = readChunk(uri, offset, length)
                                runOnUiThread { result.success(bytes) }
                            } catch (error: Exception) {
                                runOnUiThread {
                                    result.error(
                                        "read_chunk_failed",
                                        error.message ?: "读取本机媒体失败",
                                        null
                                    )
                                }
                            }
                        }.start()
                    }
                }
                "readBytes" -> {
                    val uri = call.argument<String>("uri")
                    if (uri.isNullOrBlank()) {
                        result.success(ByteArray(0))
                    } else {
                        Thread {
                            try {
                                val bytes = readBytes(uri)
                                runOnUiThread { result.success(bytes) }
                            } catch (error: Exception) {
                                runOnUiThread {
                                    result.error(
                                        "read_bytes_failed",
                                        error.message ?: "读取本机媒体失败",
                                        null
                                    )
                                }
                            }
                        }.start()
                    }
                }
                "sha256" -> {
                    val uri = call.argument<String>("uri").orEmpty()
                    if (uri.isBlank()) {
                        result.error("invalid_arguments", "媒体 URI 为空", null)
                    } else {
                        Thread {
                            try {
                                val hash = sha256(uri)
                                runOnUiThread { result.success(hash) }
                            } catch (error: Exception) {
                                runOnUiThread {
                                    result.error("hash_failed", error.message ?: "计算哈希失败", null)
                                }
                            }
                        }.start()
                    }
                }
                "deleteMedia" -> {
                    val uris = call.argument<List<String>>("uris")
                        ?.mapNotNull { value -> value.takeIf { it.isNotBlank() }?.let(Uri::parse) }
                        ?.distinct()
                        .orEmpty()
                    if (uris.isEmpty()) {
                        result.success(mapOf("requested" to 0, "deleted" to 0))
                    } else if (pendingDeleteResult != null) {
                        result.error("delete_in_progress", "已有删除确认正在进行", null)
                    } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        pendingDeleteResult = result
                        pendingDeleteUris = uris
                        val request = MediaStore.createDeleteRequest(contentResolver, uris)
                        try {
                            startIntentSenderForResult(
                                request.intentSender,
                                DELETE_MEDIA_REQUEST,
                                null,
                                0,
                                0,
                                0,
                            )
                        } catch (error: Exception) {
                            pendingDeleteResult = null
                            pendingDeleteUris = emptyList()
                            result.error("delete_request_failed", error.message, null)
                        }
                    } else {
                        Thread {
                            var deleted = 0
                            uris.forEach { uri -> deleted += contentResolver.delete(uri, null, null) }
                            runOnUiThread {
                                result.success(mapOf("requested" to uris.size, "deleted" to deleted))
                            }
                        }.start()
                    }
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "unraider/remote_file"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "readSmbFile" -> {
                    val host = call.argument<String>("host").orEmpty()
                    val username = call.argument<String>("username").orEmpty()
                    val password = call.argument<String>("password").orEmpty()
                    val share = call.argument<String>("share").orEmpty()
                    val relativePath = call.argument<String>("relativePath").orEmpty()

                    if (host.isBlank() || share.isBlank() || relativePath.isBlank()) {
                        result.error("invalid_arguments", "SMB 参数不完整", null)
                    } else {
                        Thread {
                            try {
                                val bytes = readSmbFileBytes(
                                    host = host,
                                    username = username,
                                    password = password,
                                    shareName = share,
                                    relativePath = relativePath,
                                )
                                runOnUiThread { result.success(bytes) }
                            } catch (error: Exception) {
                                appendLogLine(
                                    "${timestamp()} smb_read_error host=$host share=$share " +
                                        "path=$relativePath ${Log.getStackTraceString(error)}"
                                )
                                runOnUiThread {
                                    result.error(
                                        "smb_read_failed",
                                        error.message ?: "SMB 读取失败",
                                        null
                                    )
                                }
                            }
                        }.start()
                    }
                }
                "readSmbFileRange" -> {
                    val host = call.argument<String>("host").orEmpty()
                    val username = call.argument<String>("username").orEmpty()
                    val password = call.argument<String>("password").orEmpty()
                    val share = call.argument<String>("share").orEmpty()
                    val relativePath = call.argument<String>("relativePath").orEmpty()
                    val offset = (call.argument<Number>("offset") ?: 0).toLong()
                    val length = call.argument<Int>("length") ?: 0

                    if (host.isBlank() || share.isBlank() || relativePath.isBlank() || length <= 0) {
                        result.error("invalid_arguments", "SMB range 参数不完整", null)
                    } else {
                        Thread {
                            try {
                                val bytes = readSmbFileRangeBytes(
                                    host = host,
                                    username = username,
                                    password = password,
                                    shareName = share,
                                    relativePath = relativePath,
                                    offset = offset,
                                    length = length,
                                )
                                runOnUiThread { result.success(bytes) }
                            } catch (error: Exception) {
                                appendLogLine(
                                    "${timestamp()} smb_range_error host=$host share=$share " +
                                        "path=$relativePath offset=$offset length=$length " +
                                        Log.getStackTraceString(error)
                                )
                                runOnUiThread {
                                    result.error(
                                        "smb_range_failed",
                                        error.message ?: "SMB range 读取失败",
                                        null
                                    )
                                }
                            }
                        }.start()
                    }
                }
                "uploadLocalMedia" -> {
                    val transport = call.argument<String>("transport").orEmpty()
                    val sourceUri = call.argument<String>("sourceUri").orEmpty()
                    val expectedSize = (call.argument<Number>("expectedSize") ?: -1).toLong()
                    if (sourceUri.isBlank() || expectedSize < 0) {
                        result.error("invalid_arguments", "媒体上传参数不完整", null)
                    } else {
                        Thread {
                            try {
                                val response = when (transport.lowercase(Locale.ROOT)) {
                                    "webdav" -> uploadLocalMediaWebDav(
                                        sourceUri = sourceUri,
                                        targetUrl = call.argument<String>("webDavUrl").orEmpty(),
                                        token = call.argument<String>("webDavToken").orEmpty(),
                                        expectedSize = expectedSize,
                                        modifiedMs = (call.argument<Number>("modifiedMs") ?: 0).toLong(),
                                    )
                                    "smb" -> uploadLocalMediaSmb(
                                        sourceUri = sourceUri,
                                        host = call.argument<String>("host").orEmpty(),
                                        username = call.argument<String>("username").orEmpty(),
                                        password = call.argument<String>("password").orEmpty(),
                                        shareName = call.argument<String>("share").orEmpty(),
                                        relativePath = call.argument<String>("relativePath").orEmpty(),
                                        expectedSize = expectedSize,
                                        modifiedMs = (call.argument<Number>("modifiedMs") ?: 0).toLong(),
                                    )
                                    else -> throw IllegalArgumentException("不支持的上传渠道：$transport")
                                }
                                runOnUiThread { result.success(response) }
                            } catch (error: Exception) {
                                appendLogLine(
                                    "${timestamp()} album_native_upload_error transport=$transport " +
                                        Log.getStackTraceString(error)
                                )
                                runOnUiThread {
                                    result.error(
                                        "native_upload_failed",
                                        error.message ?: "原生媒体上传失败",
                                        null,
                                    )
                                }
                            }
                        }.start()
                    }
                }
                "generateRemoteThumbnail" -> {
                    val path = call.argument<String>("relativePath").orEmpty()
                    val isVideo = call.argument<Boolean>("isVideo") == true
                    val extent = (call.argument<Int>("extent") ?: 480).coerceIn(128, 1280)
                    Thread {
                        try {
                            val bytes = generateRemoteThumbnail(
                                host = call.argument<String>("host").orEmpty(),
                                username = call.argument<String>("username").orEmpty(),
                                password = call.argument<String>("password").orEmpty(),
                                shareName = call.argument<String>("share").orEmpty(),
                                relativePath = path,
                                webDavUrl = call.argument<String>("webDavUrl").orEmpty(),
                                webDavToken = call.argument<String>("webDavToken").orEmpty(),
                                isVideo = isVideo,
                                extent = extent,
                            )
                            runOnUiThread { result.success(bytes) }
                        } catch (error: Exception) {
                            appendLogLine(
                                "${timestamp()} remote_thumbnail_error path=$path " +
                                    Log.getStackTraceString(error)
                            )
                            runOnUiThread {
                                result.error(
                                    "thumbnail_failed",
                                    error.message ?: "生成远端缩略图失败",
                                    null,
                                )
                            }
                        }
                    }.start()
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "unraider/album_background"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "configure" -> {
                    @Suppress("UNCHECKED_CAST")
                    val values = call.arguments as? Map<String, Any?> ?: emptyMap()
                    AlbumBackgroundScheduler.configure(applicationContext, values)
                    result.success(null)
                }
                "runNow" -> {
                    AlbumBackgroundScheduler.runNow(applicationContext, focused = true)
                    result.success(null)
                }
                "cancel" -> {
                    AlbumBackgroundScheduler.cancelFocused(applicationContext)
                    result.success(null)
                }
                "status" -> result.success(AlbumBackgroundScheduler.status(applicationContext))
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "unraider/app_log"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "path" -> result.success(logFile().absolutePath)
                "append" -> {
                    val line = call.argument<String>("line") ?: ""
                    appendLogLine(line)
                    result.success(null)
                }
                "appendBatch" -> {
                    @Suppress("UNCHECKED_CAST")
                    val lines = call.argument<List<String>>("lines") ?: emptyList()
                    appendLogLines(lines)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        resetCachedSmbConnection()
        super.onDestroy()
    }

    private fun installUncaughtHandler() {
        if (uncaughtHandlerInstalled) return
        uncaughtHandlerInstalled = true
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            appendLogLine(
                "${timestamp()} native_uncaught thread=${thread.name} " +
                    Log.getStackTraceString(throwable)
            )
            if (previous != null) {
                previous.uncaughtException(thread, throwable)
            } else {
                exitProcess(10)
            }
        }
    }

    private fun appendLogLine(line: String) {
        if (line.isBlank()) return
        appendLogLines(listOf(line))
    }

    private fun appendLogLines(lines: List<String>) {
        val filtered = lines.filter { it.isNotBlank() }
        if (filtered.isEmpty()) return
        for (line in filtered) {
            Log.i(LOG_TAG, line)
        }
        try {
            FileWriter(logFile(), true).use { writer ->
                for (line in filtered) {
                    writer.append(line).append('\n')
                }
            }
        } catch (error: Exception) {
            Log.e(LOG_TAG, "failed to write log file", error)
        }
    }

    private fun logFile(): File {
        val baseDir = getExternalFilesDir(null) ?: filesDir
        val logsDir = File(baseDir, "logs")
        if (!logsDir.exists()) {
            logsDir.mkdirs()
        }
        return File(logsDir, "unraider.log")
    }

    private fun timestamp(): String {
        return SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSSZ", Locale.US).format(Date())
    }

    private fun listMedia(
        limit: Int,
        bucketId: String?,
        modifiedAfterMs: Long? = null
    ): List<Map<String, Any?>> {
        val items = mutableListOf<Map<String, Any?>>()
        queryMedia(false, limit, bucketId, modifiedAfterMs, items)
        if (limit <= 0 || items.size < limit) {
            queryMedia(true, limit, bucketId, modifiedAfterMs, items)
        }
        return items.sortedByDescending { (it["dateModifiedMs"] as? Long) ?: 0L }
    }

    private fun queryMedia(
        videos: Boolean,
        limit: Int,
        bucketId: String?,
        modifiedAfterMs: Long?,
        items: MutableList<Map<String, Any?>>
    ) {
        val collection = if (videos) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL)
            } else {
                MediaStore.Video.Media.EXTERNAL_CONTENT_URI
            }
        } else {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL)
            } else {
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI
            }
        }
        val projection = mutableListOf(
            MediaStore.MediaColumns._ID,
            MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.BUCKET_ID,
            MediaStore.MediaColumns.BUCKET_DISPLAY_NAME,
            MediaStore.MediaColumns.MIME_TYPE,
            MediaStore.MediaColumns.DATE_ADDED,
            MediaStore.MediaColumns.DATE_MODIFIED,
            MediaStore.MediaColumns.SIZE,
            MediaStore.MediaColumns.WIDTH,
            MediaStore.MediaColumns.HEIGHT,
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            projection.add(MediaStore.MediaColumns.RELATIVE_PATH)
        } else {
            @Suppress("DEPRECATION")
            projection.add(MediaStore.MediaColumns.DATA)
        }
        if (videos) {
            projection.add(MediaStore.Video.Media.DATE_TAKEN)
            projection.add(MediaStore.Video.Media.DURATION)
        } else {
            projection.add(MediaStore.Images.Media.DATE_TAKEN)
            projection.add(MediaStore.Images.Media.ORIENTATION)
        }

        val selectionParts = mutableListOf<String>()
        val selectionValues = mutableListOf<String>()
        if (!bucketId.isNullOrBlank()) {
            selectionParts.add("${MediaStore.MediaColumns.BUCKET_ID}=?")
            selectionValues.add(bucketId)
        }
        if (modifiedAfterMs != null && modifiedAfterMs > 0) {
            selectionParts.add("${MediaStore.MediaColumns.DATE_MODIFIED}>=?")
            selectionValues.add((modifiedAfterMs / 1000L).toString())
        }
        val selection = selectionParts.takeIf { it.isNotEmpty() }?.joinToString(" AND ")
        val selectionArgs = selectionValues.takeIf { it.isNotEmpty() }?.toTypedArray()
        val sortOrder = "${MediaStore.MediaColumns.DATE_MODIFIED} DESC"

        contentResolver.query(collection, projection.toTypedArray(), selection, selectionArgs, sortOrder)?.use { cursor ->
            val idColumn = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
            val nameColumn = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DISPLAY_NAME)
            val bucketIdColumn = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.BUCKET_ID)
            val bucketNameColumn = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.BUCKET_DISPLAY_NAME)
            val mimeColumn = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.MIME_TYPE)
            val dateAddedColumn = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_ADDED)
            val dateColumn = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_MODIFIED)
            val sizeColumn = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.SIZE)
            val widthColumn = cursor.getColumnIndex(MediaStore.MediaColumns.WIDTH)
            val heightColumn = cursor.getColumnIndex(MediaStore.MediaColumns.HEIGHT)
            val relativePathColumn = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                cursor.getColumnIndex(MediaStore.MediaColumns.RELATIVE_PATH)
            } else {
                @Suppress("DEPRECATION")
                cursor.getColumnIndex(MediaStore.MediaColumns.DATA)
            }
            val captureTimeColumn = cursor.getColumnIndex(
                if (videos) MediaStore.Video.Media.DATE_TAKEN else MediaStore.Images.Media.DATE_TAKEN
            )
            val durationColumn = if (videos) {
                cursor.getColumnIndex(MediaStore.Video.Media.DURATION)
            } else {
                -1
            }
            val orientationColumn = if (videos) {
                -1
            } else {
                cursor.getColumnIndex(MediaStore.Images.Media.ORIENTATION)
            }
            while (cursor.moveToNext()) {
                val id = cursor.getLong(idColumn)
                val uri = ContentUris.withAppendedId(collection, id)
                val name = cursor.getString(nameColumn).orEmpty()
                val volumeName = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    MediaStore.getVolumeName(uri)
                } else {
                    "external"
                }
                val relativePath = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    cursor.getString(relativePathColumn).orEmpty()
                } else {
                    legacyRelativePath(cursor.getString(relativePathColumn), name)
                }
                val addedMs = cursor.getLong(dateAddedColumn) * 1000L
                val modifiedMs = cursor.getLong(dateColumn) * 1000
                items.add(
                    mapOf(
                        "id" to "$volumeName:${if (videos) "video" else "image"}:$id",
                        "mediaStoreId" to id.toString(),
                        "uri" to uri.toString(),
                        "name" to name,
                        "bucketId" to cursor.getString(bucketIdColumn).orEmpty(),
                        "bucketName" to cursor.getString(bucketNameColumn).orEmpty(),
                        "volumeName" to volumeName,
                        "relativePath" to relativePath,
                        "mimeType" to cursor.getString(mimeColumn).orEmpty(),
                        "dateAddedMs" to addedMs,
                        "dateModifiedMs" to modifiedMs,
                        "captureTimeMs" to if (captureTimeColumn >= 0) cursor.getLong(captureTimeColumn) else 0L,
                        "sizeBytes" to cursor.getLong(sizeColumn),
                        "isVideo" to videos,
                        "width" to if (widthColumn >= 0) cursor.getInt(widthColumn) else 0,
                        "height" to if (heightColumn >= 0) cursor.getInt(heightColumn) else 0,
                        "durationMs" to if (durationColumn >= 0) cursor.getLong(durationColumn) else 0L,
                        "orientation" to if (orientationColumn >= 0) cursor.getInt(orientationColumn) else 0,
                    )
                )
                if (limit > 0 && items.size >= limit) break
            }
        }
    }

    private fun listBuckets(): List<Map<String, Any?>> {
        val buckets = linkedMapOf<String, MutableMap<String, Any?>>()
        for (item in listMedia(0, null, null)) {
            val id = item["bucketId"]?.toString() ?: continue
            val name = item["bucketName"]?.toString() ?: "本机相册"
            val existing = buckets.getOrPut(id) {
                mutableMapOf(
                    "id" to id,
                    "name" to name,
                    "count" to 0,
                    "volumeName" to (item["volumeName"]?.toString() ?: "external"),
                    "relativePath" to (item["relativePath"]?.toString() ?: ""),
                )
            }
            existing["count"] = (existing["count"] as Int) + 1
        }
        return buckets.values.sortedByDescending { it["count"] as Int }
    }

    private fun legacyRelativePath(fullPath: String?, displayName: String): String {
        val normalized = fullPath.orEmpty().replace('\\', '/')
        val withoutName = if (displayName.isNotBlank() && normalized.endsWith("/$displayName")) {
            normalized.removeSuffix(displayName)
        } else {
            normalized.substringBeforeLast('/', "") + "/"
        }
        val knownPrefixes = listOf(
            "/storage/emulated/0/",
            "/storage/self/primary/",
            "/sdcard/",
        )
        val relative = knownPrefixes.firstNotNullOfOrNull { prefix ->
            withoutName.takeIf { it.startsWith(prefix, ignoreCase = true) }
                ?.removePrefix(prefix)
        } ?: withoutName.trimStart('/')
        return if (relative.isBlank()) "" else relative.trim('/') + "/"
    }

    private fun loadThumbnail(uriText: String, size: Int): ByteArray? {
        return try {
            val uri = Uri.parse(uriText)
            val bitmap = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                contentResolver.loadThumbnail(uri, Size(size, size), null)
            } else if (uri.toString().contains("/video/")) {
                val id = uri.lastPathSegment?.toLongOrNull() ?: return null
                MediaStore.Video.Thumbnails.getThumbnail(
                    contentResolver,
                    id,
                    MediaStore.Video.Thumbnails.MINI_KIND,
                    null
                )
            } else {
                val id = uri.lastPathSegment?.toLongOrNull() ?: return null
                MediaStore.Images.Thumbnails.getThumbnail(
                    contentResolver,
                    id,
                    MediaStore.Images.Thumbnails.MINI_KIND,
                    null
                )
            }
            ByteArrayOutputStream().use { stream ->
                bitmap.compress(Bitmap.CompressFormat.JPEG, 82, stream)
                stream.toByteArray()
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun readChunk(uriText: String, offset: Long, length: Int): ByteArray {
        if (length <= 0) return ByteArray(0)
        val uri = Uri.parse(uriText)
        // Prefer AssetFileDescriptor + FileChannel so large album uploads can
        // seek instead of slowly skipping through the whole stream.
        try {
            contentResolver.openAssetFileDescriptor(uri, "r")?.use { afd ->
                val channel = afd.createInputStream().channel
                channel.position(offset.coerceAtLeast(0L))
                val buffer = java.nio.ByteBuffer.allocate(length)
                while (buffer.hasRemaining()) {
                    val read = channel.read(buffer)
                    if (read <= 0) break
                }
                val total = buffer.position()
                return if (total == length) buffer.array() else buffer.array().copyOf(total)
            }
        } catch (error: Exception) {
            appendLogLine(
                "${timestamp()} local_media_read_chunk_afd_error uri=$uriText " +
                    "offset=$offset length=$length ${error.message}"
            )
        }

        return try {
            contentResolver.openInputStream(uri).use { input ->
                if (input == null) {
                    throw IllegalStateException("无法打开媒体流")
                }
                var remainingSkip = offset
                while (remainingSkip > 0) {
                    val skipped = input.skip(remainingSkip)
                    if (skipped <= 0) {
                        // Some ContentProviders return 0 from skip(); fall back
                        // to draining bytes so album sync can still progress.
                        val drain = ByteArray(minOf(remainingSkip, 64L * 1024L).toInt())
                        val read = input.read(drain)
                        if (read <= 0) break
                        remainingSkip -= read.toLong()
                    } else {
                        remainingSkip -= skipped
                    }
                }
                if (remainingSkip > 0) {
                    return ByteArray(0)
                }
                val buffer = ByteArray(length)
                var total = 0
                while (total < length) {
                    val read = input.read(buffer, total, length - total)
                    if (read <= 0) break
                    total += read
                }
                if (total == buffer.size) buffer else buffer.copyOf(total)
            } ?: ByteArray(0)
        } catch (error: Exception) {
            appendLogLine(
                "${timestamp()} local_media_read_chunk_error uri=$uriText " +
                    "offset=$offset length=$length ${Log.getStackTraceString(error)}"
            )
            throw error
        }
    }

    private fun readBytes(uriText: String): ByteArray {
        contentResolver.openInputStream(Uri.parse(uriText)).use { input ->
            if (input == null) {
                throw IllegalStateException("无法打开媒体文件")
            }
            return input.readBytes()
        }
    }

    private fun readSmbFileBytes(
        host: String,
        username: String,
        password: String,
        shareName: String,
        relativePath: String
    ): ByteArray {
        val smbPath = relativePath
            .replace('/', '\\')
            .trim { it == '\\' || it == '/' }
        if (smbPath.isBlank()) {
            throw IllegalArgumentException("SMB 文件路径为空")
        }

        val config = SmbConfig.builder()
            .withTimeout(30, TimeUnit.SECONDS)
            .withSoTimeout(30, TimeUnit.SECONDS)
            .build()

        if (username.isBlank()) {
            throw IllegalArgumentException("SMB 用户名为空")
        }
        val auth = AuthenticationContext(username, password.toCharArray(), null)
        return readSmbFileBytesWithAuth(config, host, auth, shareName, smbPath)
    }

    private fun readSmbFileBytesWithAuth(
        config: SmbConfig,
        host: String,
        auth: AuthenticationContext,
        shareName: String,
        smbPath: String
    ): ByteArray {
        SMBClient(config).use { client ->
            client.connect(host).use { connection ->
                val session = connection.authenticate(auth)
                (session.connectShare(shareName) as DiskShare).use { share ->
                    share.openFile(
                        smbPath,
                        EnumSet.of(AccessMask.GENERIC_READ),
                        EnumSet.noneOf(FileAttributes::class.java),
                        SMB2ShareAccess.ALL,
                        SMB2CreateDisposition.FILE_OPEN,
                        EnumSet.of(SMB2CreateOptions.FILE_NON_DIRECTORY_FILE)
                    ).use { remoteFile ->
                        remoteFile.inputStream.use { input ->
                            return input.readBytes()
                        }
                    }
                }
            }
        }
    }

    private fun readSmbFileRangeBytes(
        host: String,
        username: String,
        password: String,
        shareName: String,
        relativePath: String,
        offset: Long,
        length: Int
    ): ByteArray {
        val smbPath = relativePath
            .replace('/', '\\')
            .trim { it == '\\' || it == '/' }
        if (smbPath.isBlank()) {
            throw IllegalArgumentException("SMB 文件路径为空")
        }
        if (offset < 0 || length <= 0) {
            return ByteArray(0)
        }

        val config = SmbConfig.builder()
            .withTimeout(30, TimeUnit.SECONDS)
            .withSoTimeout(30, TimeUnit.SECONDS)
            .build()

        if (username.isBlank()) {
            throw IllegalArgumentException("SMB 用户名为空")
        }
        val auth = AuthenticationContext(username, password.toCharArray(), null)
        return readSmbFileRangeWithAuth(
            config = config,
            host = host,
            auth = auth,
            shareName = shareName,
            smbPath = smbPath,
            offset = offset,
            length = length,
            cacheKey = "$host\u0000$username\u0000${password.hashCode()}\u0000$shareName",
        )
    }

    private fun readSmbFileRangeWithAuth(
        config: SmbConfig,
        host: String,
        auth: AuthenticationContext,
        shareName: String,
        smbPath: String,
        offset: Long,
        length: Int,
        cacheKey: String,
    ): ByteArray {
        var lastError: Exception? = null
        repeat(2) { attempt ->
            try {
                synchronized(smbCacheLock) {
                    val share = getCachedSmbShare(
                        config = config,
                        host = host,
                        auth = auth,
                        shareName = shareName,
                        cacheKey = cacheKey,
                    )
                    share.openFile(
                        smbPath,
                        EnumSet.of(AccessMask.GENERIC_READ),
                        EnumSet.noneOf(FileAttributes::class.java),
                        SMB2ShareAccess.ALL,
                        SMB2CreateDisposition.FILE_OPEN,
                        EnumSet.of(SMB2CreateOptions.FILE_NON_DIRECTORY_FILE)
                    ).use { remoteFile ->
                        val buffer = ByteArray(length)
                        var totalRead = 0
                        while (totalRead < length) {
                            // Keep each protocol read below the common SMB max-read
                            // size while reusing one authenticated connection.
                            val requestLength = minOf(length - totalRead, 512 * 1024)
                            val read = remoteFile.read(
                                buffer,
                                offset + totalRead,
                                totalRead,
                                requestLength,
                            )
                            if (read <= 0) break
                            totalRead += read
                        }
                        if (totalRead <= 0) {
                            return ByteArray(0)
                        }
                        return if (totalRead == buffer.size) buffer else buffer.copyOf(totalRead)
                    }
                }
            } catch (error: Exception) {
                lastError = error
                resetCachedSmbConnection()
                if (attempt == 1) throw error
            }
        }
        throw lastError ?: IllegalStateException("SMB range 读取失败")
    }

    private fun sha256(uriText: String): String {
        val digest = MessageDigest.getInstance("SHA-256")
        contentResolver.openInputStream(Uri.parse(uriText)).use { input ->
            requireNotNull(input) { "无法打开媒体文件" }
            val buffer = ByteArray(1024 * 1024)
            while (true) {
                val read = input.read(buffer)
                if (read <= 0) break
                digest.update(buffer, 0, read)
            }
        }
        return digest.digest().joinToString("") { byte -> "%02x".format(byte) }
    }

    private fun mediaExists(uri: Uri): Boolean = try {
        contentResolver.query(uri, arrayOf(MediaStore.MediaColumns._ID), null, null, null)
            ?.use { it.moveToFirst() } == true
    } catch (_: Exception) {
        false
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == DELETE_MEDIA_REQUEST) {
            val result = pendingDeleteResult
            val uris = pendingDeleteUris
            pendingDeleteResult = null
            pendingDeleteUris = emptyList()
            if (result != null) {
                if (resultCode == Activity.RESULT_OK) {
                    Thread {
                        val remaining = uris.count(::mediaExists)
                        runOnUiThread {
                            result.success(
                                mapOf(
                                    "requested" to uris.size,
                                    "deleted" to uris.size - remaining,
                                    "cancelled" to false,
                                )
                            )
                        }
                    }.start()
                } else {
                    result.success(
                        mapOf("requested" to uris.size, "deleted" to 0, "cancelled" to true)
                    )
                }
            }
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    private fun uploadLocalMediaSmb(
        sourceUri: String,
        host: String,
        username: String,
        password: String,
        shareName: String,
        relativePath: String,
        expectedSize: Long,
        modifiedMs: Long,
    ): Map<String, Any?> {
        require(host.isNotBlank() && username.isNotBlank() && shareName.isNotBlank()) {
            "SMB 参数不完整"
        }
        val finalPath = relativePath.replace('/', '\\').trim('\\', '/')
        require(finalPath.isNotBlank() && !finalPath.split('\\').any { it == ".." }) {
            "SMB 目标路径无效"
        }
        val tempPath = "$finalPath.part-${UUID.randomUUID()}"
        val started = System.nanoTime()
        val config = SmbConfig.builder()
            .withTimeout(30, TimeUnit.SECONDS)
            .withSoTimeout(60, TimeUnit.SECONDS)
            .build()
        val auth = AuthenticationContext(username, password.toCharArray(), null)
        val connectStarted = System.nanoTime()
        val share = synchronized(smbCacheLock) {
            getCachedSmbShare(
                config = config,
                host = host,
                auth = auth,
                shareName = shareName,
                cacheKey = "$host\u0000$username\u0000${password.hashCode()}\u0000$shareName",
            )
        }
        val connectMs = elapsedMs(connectStarted)
        val prepareStarted = System.nanoTime()
        ensureSmbDirectories(share, finalPath.substringBeforeLast('\\', ""))
        if (share.fileExists(finalPath)) {
            val existing = share.getFileInformation(finalPath).standardInformation.endOfFile
            if (existing == expectedSize) {
                return uploadResult(
                    transport = "smb",
                    remoteSize = existing,
                    modifiedMs = modifiedMs,
                    started = started,
                    connectMs = connectMs,
                    prepareMs = elapsedMs(prepareStarted),
                )
            }
            throw IllegalStateException("目标文件已存在且大小不同")
        }
        val prepareMs = elapsedMs(prepareStarted)
        val uploadStarted = System.nanoTime()
        try {
            share.openFile(
                tempPath,
                EnumSet.of(AccessMask.GENERIC_WRITE, AccessMask.GENERIC_READ),
                EnumSet.noneOf(FileAttributes::class.java),
                SMB2ShareAccess.ALL,
                SMB2CreateDisposition.FILE_OVERWRITE_IF,
                EnumSet.of(SMB2CreateOptions.FILE_NON_DIRECTORY_FILE),
            ).use { remoteFile ->
                contentResolver.openInputStream(Uri.parse(sourceUri)).use { input ->
                    requireNotNull(input) { "无法打开本机媒体" }
                    remoteFile.outputStream.use { output -> input.copyTo(output, 1024 * 1024) }
                }
            }
            val uploadMs = elapsedMs(uploadStarted)
            val verifyStarted = System.nanoTime()
            val remoteSize = share.getFileInformation(tempPath).standardInformation.endOfFile
            if (remoteSize != expectedSize) {
                throw IllegalStateException("SMB 上传大小校验失败：期望 $expectedSize，实际 $remoteSize")
            }
            val verifyMs = elapsedMs(verifyStarted)
            val commitStarted = System.nanoTime()
            share.openFile(
                tempPath,
                EnumSet.of(AccessMask.DELETE),
                EnumSet.noneOf(FileAttributes::class.java),
                SMB2ShareAccess.ALL,
                SMB2CreateDisposition.FILE_OPEN,
                EnumSet.of(SMB2CreateOptions.FILE_NON_DIRECTORY_FILE),
            ).use { it.rename(finalPath) }
            val commitMs = elapsedMs(commitStarted)
            return uploadResult(
                transport = "smb",
                remoteSize = remoteSize,
                modifiedMs = modifiedMs,
                started = started,
                connectMs = connectMs,
                prepareMs = prepareMs,
                uploadMs = uploadMs,
                verifyMs = verifyMs,
                commitMs = commitMs,
            )
        } catch (error: Exception) {
            try {
                if (share.fileExists(tempPath)) share.rm(tempPath)
            } catch (_: Exception) {
                // A stale unique .part file is safe and can be removed later.
            }
            throw error
        }
    }

    private fun generateRemoteThumbnail(
        host: String,
        username: String,
        password: String,
        shareName: String,
        relativePath: String,
        webDavUrl: String,
        webDavToken: String,
        isVideo: Boolean,
        extent: Int,
    ): ByteArray? {
        fun openSource(): InputStream {
            if (webDavUrl.isNotBlank() && webDavToken.isNotBlank()) {
                val connection = openWebDav(URL(webDavUrl), "GET", webDavToken)
                val code = connection.responseCode
                if (code !in 200..299) {
                    connection.disconnect()
                    throw IllegalStateException("WebDAV 缩略图源返回 HTTP $code")
                }
                return connection.inputStream
            }
            require(host.isNotBlank() && shareName.isNotBlank() && relativePath.isNotBlank()) {
                "远端缩略图参数不完整"
            }
            val config = SmbConfig.builder()
                .withTimeout(30, TimeUnit.SECONDS)
                .withSoTimeout(60, TimeUnit.SECONDS)
                .build()
            val auth = AuthenticationContext(username, password.toCharArray(), null)
            val share = synchronized(smbCacheLock) {
                getCachedSmbShare(
                    config = config,
                    host = host,
                    auth = auth,
                    shareName = shareName,
                    cacheKey = "$host\u0000$username\u0000${password.hashCode()}\u0000$shareName",
                )
            }
            val remote = share.openFile(
                relativePath.replace('/', '\\').trim('\\', '/'),
                EnumSet.of(AccessMask.GENERIC_READ),
                EnumSet.noneOf(FileAttributes::class.java),
                SMB2ShareAccess.ALL,
                SMB2CreateDisposition.FILE_OPEN,
                EnumSet.of(SMB2CreateOptions.FILE_NON_DIRECTORY_FILE),
            )
            return object : InputStream() {
                private val delegate = remote.inputStream
                override fun read(): Int = delegate.read()
                override fun read(buffer: ByteArray, offset: Int, length: Int): Int =
                    delegate.read(buffer, offset, length)
                override fun close() {
                    try { delegate.close() } finally { remote.close() }
                }
            }
        }

        val bitmap = if (isVideo) {
            val temp = File.createTempFile("unraider-preview-", ".video", cacheDir)
            try {
                openSource().use { input -> temp.outputStream().use { input.copyTo(it, 1024 * 1024) } }
                val retriever = MediaMetadataRetriever()
                try {
                    retriever.setDataSource(temp.absolutePath)
                    retriever.getFrameAtTime(0, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                } finally {
                    retriever.release()
                }
            } finally {
                temp.delete()
            }
        } else {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            openSource().use { BitmapFactory.decodeStream(it, null, bounds) }
            var sample = 1
            while (bounds.outWidth / sample > extent * 2 || bounds.outHeight / sample > extent * 2) {
                sample *= 2
            }
            val options = BitmapFactory.Options().apply { inSampleSize = sample }
            openSource().use { BitmapFactory.decodeStream(it, null, options) }
        } ?: return null
        val scaled = scaleBitmap(bitmap, extent)
        return try {
            ByteArrayOutputStream().use { stream ->
                scaled.compress(Bitmap.CompressFormat.JPEG, 82, stream)
                stream.toByteArray()
            }
        } finally {
            if (scaled !== bitmap) scaled.recycle()
            bitmap.recycle()
        }
    }

    private fun scaleBitmap(bitmap: Bitmap, extent: Int): Bitmap {
        val largest = maxOf(bitmap.width, bitmap.height)
        if (largest <= extent) return bitmap
        val scale = extent.toFloat() / largest.toFloat()
        return Bitmap.createScaledBitmap(
            bitmap,
            maxOf(1, (bitmap.width * scale).toInt()),
            maxOf(1, (bitmap.height * scale).toInt()),
            true,
        )
    }

    private fun ensureSmbDirectories(share: DiskShare, directory: String) {
        if (directory.isBlank()) return
        var current = ""
        directory.split('\\').filter { it.isNotBlank() }.forEach { part ->
            current = if (current.isEmpty()) part else "$current\\$part"
            if (!share.folderExists(current)) share.mkdir(current)
        }
    }

    private fun uploadLocalMediaWebDav(
        sourceUri: String,
        targetUrl: String,
        token: String,
        expectedSize: Long,
        modifiedMs: Long,
    ): Map<String, Any?> {
        require(targetUrl.isNotBlank() && token.isNotBlank()) { "WebDAV 参数不完整" }
        val finalUrl = URL(targetUrl)
        val tempUrl = URL("$targetUrl.part-${UUID.randomUUID()}")
        val started = System.nanoTime()
        val prepareStarted = System.nanoTime()
        ensureWebDavDirectories(finalUrl, token)
        val existing = webDavHead(finalUrl, token)
        if (existing.first in 200..299) {
            if (existing.second == expectedSize) {
                return uploadResult(
                    transport = "webDav",
                    remoteSize = expectedSize,
                    modifiedMs = modifiedMs,
                    started = started,
                    prepareMs = elapsedMs(prepareStarted),
                    etag = existing.third,
                )
            }
            throw IllegalStateException("目标文件已存在且大小不同")
        }
        val prepareMs = elapsedMs(prepareStarted)
        val uploadStarted = System.nanoTime()
        try {
            val connection = openWebDav(tempUrl, "PUT", token)
            connection.doOutput = true
            connection.setFixedLengthStreamingMode(expectedSize)
            connection.setRequestProperty("Content-Type", "application/octet-stream")
            contentResolver.openInputStream(Uri.parse(sourceUri)).use { input ->
                requireNotNull(input) { "无法打开本机媒体" }
                connection.outputStream.use { output -> input.copyTo(output, 1024 * 1024) }
            }
            val uploadCode = connection.responseCode
            connection.disconnect()
            if (uploadCode !in 200..299) {
                throw IllegalStateException("WebDAV PUT 返回 HTTP $uploadCode")
            }
            val uploadMs = elapsedMs(uploadStarted)
            val verifyStarted = System.nanoTime()
            val head = webDavHead(tempUrl, token)
            if (head.first !in 200..299 || head.second != expectedSize) {
                throw IllegalStateException(
                    "WebDAV 上传大小校验失败：期望 $expectedSize，实际 ${head.second}",
                )
            }
            val verifyMs = elapsedMs(verifyStarted)
            val commitStarted = System.nanoTime()
            val move = openWebDav(tempUrl, "MOVE", token)
            move.setRequestProperty("Destination", finalUrl.toString())
            move.setRequestProperty("Overwrite", "F")
            val moveCode = move.responseCode
            move.disconnect()
            if (moveCode !in 200..299) {
                throw IllegalStateException("WebDAV 不支持安全 MOVE（HTTP $moveCode）")
            }
            val commitMs = elapsedMs(commitStarted)
            val committed = webDavHead(finalUrl, token)
            if (committed.second != expectedSize) {
                throw IllegalStateException("WebDAV 提交后校验失败")
            }
            return uploadResult(
                transport = "webDav",
                remoteSize = expectedSize,
                modifiedMs = modifiedMs,
                started = started,
                prepareMs = prepareMs,
                uploadMs = uploadMs,
                verifyMs = verifyMs,
                commitMs = commitMs,
                etag = committed.third,
            )
        } catch (error: Exception) {
            try {
                val delete = openWebDav(tempUrl, "DELETE", token)
                delete.responseCode
                delete.disconnect()
            } catch (_: Exception) {
                // A stale unique .part resource is safe and can be removed later.
            }
            throw error
        }
    }

    private fun ensureWebDavDirectories(target: URL, token: String) {
        val segments = target.path.split('/').filter { it.isNotBlank() }
        if (segments.size <= 1) return
        var path = ""
        segments.dropLast(1).forEach { segment ->
            path += "/$segment"
            val url = URL(target.protocol, target.host, target.port, path)
            val head = webDavHead(url, token)
            if (head.first == HttpURLConnection.HTTP_NOT_FOUND) {
                val mkdir = openWebDav(url, "MKCOL", token)
                val code = mkdir.responseCode
                mkdir.disconnect()
                if (code !in 200..299 && code != HttpURLConnection.HTTP_CONFLICT) {
                    throw IllegalStateException("WebDAV 创建目录失败（HTTP $code）")
                }
            }
        }
    }

    private fun webDavHead(url: URL, token: String): Triple<Int, Long, String?> {
        val connection = openWebDav(url, "HEAD", token)
        val code = connection.responseCode
        val length = connection.getHeaderFieldLong("Content-Length", -1L)
        val etag = connection.getHeaderField("ETag")
        connection.disconnect()
        return Triple(code, length, etag)
    }

    private fun openWebDav(url: URL, method: String, token: String): HttpURLConnection {
        return (url.openConnection() as HttpURLConnection).apply {
            requestMethod = method
            connectTimeout = 20_000
            readTimeout = 60_000
            useCaches = false
            setRequestProperty("Authorization", webDavAuthorization(token))
            setRequestProperty("Accept-Encoding", "identity")
        }
    }

    private fun webDavAuthorization(token: String): String {
        val encoded = Base64.encodeToString("unraider:$token".toByteArray(), Base64.NO_WRAP)
        return "Basic $encoded"
    }

    private fun elapsedMs(started: Long): Long =
        TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started)

    private fun uploadResult(
        transport: String,
        remoteSize: Long,
        modifiedMs: Long,
        started: Long,
        connectMs: Long = 0,
        prepareMs: Long = 0,
        uploadMs: Long = 0,
        verifyMs: Long = 0,
        commitMs: Long = 0,
        etag: String? = null,
    ): Map<String, Any?> = mapOf(
        "transport" to transport,
        "remoteSize" to remoteSize,
        "remoteModifiedMs" to modifiedMs,
        "etag" to etag,
        "elapsedMs" to elapsedMs(started),
        "connectMs" to connectMs,
        "prepareMs" to prepareMs,
        "uploadMs" to uploadMs,
        "verifyMs" to verifyMs,
        "commitMs" to commitMs,
    )

    private fun getCachedSmbShare(
        config: SmbConfig,
        host: String,
        auth: AuthenticationContext,
        shareName: String,
        cacheKey: String,
    ): DiskShare {
        val existing = cachedSmbShare
        if (cachedSmbKey == cacheKey && existing != null) {
            return existing
        }
        resetCachedSmbConnectionLocked()

        val client = SMBClient(config)
        try {
            val connection = client.connect(host)
            val session = connection.authenticate(auth)
            val share = session.connectShare(shareName) as DiskShare
            cachedSmbKey = cacheKey
            cachedSmbClient = client
            cachedSmbConnection = connection
            cachedSmbShare = share
            return share
        } catch (error: Exception) {
            try {
                client.close()
            } catch (_: Exception) {
                // Preserve the original connection error.
            }
            throw error
        }
    }

    private fun resetCachedSmbConnection() {
        synchronized(smbCacheLock) {
            resetCachedSmbConnectionLocked()
        }
    }

    private fun resetCachedSmbConnectionLocked() {
        try {
            cachedSmbShare?.close()
        } catch (_: Exception) {
            // Best-effort transport cleanup.
        }
        try {
            cachedSmbConnection?.close()
        } catch (_: Exception) {
            // Best-effort transport cleanup.
        }
        try {
            cachedSmbClient?.close()
        } catch (_: Exception) {
            // Best-effort transport cleanup.
        }
        cachedSmbShare = null
        cachedSmbConnection = null
        cachedSmbClient = null
        cachedSmbKey = null
    }
}
