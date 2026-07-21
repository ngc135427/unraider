package com.ngc.unraider

import android.content.Context
import android.content.ContentUris
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
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
import com.hierynomus.smbj.share.DiskShare
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileWriter
import java.text.SimpleDateFormat
import java.util.Date
import java.util.EnumSet
import java.util.Locale
import java.util.concurrent.TimeUnit
import kotlin.system.exitProcess

class MainActivity : FlutterActivity() {
    companion object {
        private const val LOG_TAG = "UnraiderLog"
        @Volatile private var uncaughtHandlerInstalled = false
    }

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
                    result.success(
                        mapOf(
                            "targetDir" to preferences.getString("targetDir", "/mnt/user/photos/mobile"),
                            "sourceId" to preferences.getString("sourceId", ""),
                            "sourceIds" to preferences.getStringSet("sourceIds", emptySet())?.toList(),
                            "sourceName" to preferences.getString("sourceName", "本机所有照片"),
                            "autoBackup" to preferences.getBoolean("autoBackup", true),
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
                    result.success(listMedia(limit, bucketId))
                }
                "listImages" -> {
                    val limit = call.argument<Int>("limit") ?: 0
                    val bucketId = call.argument<String>("bucketId")
                    result.success(listMedia(limit, bucketId))
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
                else -> result.notImplemented()
            }
        }
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
        Log.i(LOG_TAG, line)
        try {
            FileWriter(logFile(), true).use { writer ->
                writer.append(line).append('\n')
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

    private fun listMedia(limit: Int, bucketId: String?): List<Map<String, Any?>> {
        val items = mutableListOf<Map<String, Any?>>()
        queryMedia(false, limit, bucketId, items)
        if (limit <= 0 || items.size < limit) {
            queryMedia(true, limit, bucketId, items)
        }
        return items.sortedByDescending { (it["dateModifiedMs"] as? Long) ?: 0L }
    }

    private fun queryMedia(
        videos: Boolean,
        limit: Int,
        bucketId: String?,
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
        val projection = arrayOf(
            MediaStore.MediaColumns._ID,
            MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.BUCKET_ID,
            MediaStore.MediaColumns.BUCKET_DISPLAY_NAME,
            MediaStore.MediaColumns.DATE_MODIFIED,
            MediaStore.MediaColumns.SIZE,
        )
        val selection = if (!bucketId.isNullOrBlank()) "${MediaStore.MediaColumns.BUCKET_ID}=?" else null
        val selectionArgs = if (!bucketId.isNullOrBlank()) arrayOf(bucketId) else null
        val sortOrder = "${MediaStore.MediaColumns.DATE_MODIFIED} DESC"

        contentResolver.query(collection, projection, selection, selectionArgs, sortOrder)?.use { cursor ->
            val idColumn = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
            val nameColumn = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DISPLAY_NAME)
            val bucketIdColumn = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.BUCKET_ID)
            val bucketNameColumn = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.BUCKET_DISPLAY_NAME)
            val dateColumn = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_MODIFIED)
            val sizeColumn = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.SIZE)
            while (cursor.moveToNext()) {
                val id = cursor.getLong(idColumn)
                val uri = ContentUris.withAppendedId(collection, id)
                val modifiedMs = cursor.getLong(dateColumn) * 1000
                items.add(
                    mapOf(
                        "id" to (if (videos) "video:" else "image:") + id.toString(),
                        "uri" to uri.toString(),
                        "name" to cursor.getString(nameColumn),
                        "bucketId" to cursor.getString(bucketIdColumn),
                        "bucketName" to cursor.getString(bucketNameColumn),
                        "dateModifiedMs" to modifiedMs,
                        "sizeBytes" to cursor.getLong(sizeColumn),
                        "isVideo" to videos,
                    )
                )
                if (limit > 0 && items.size >= limit) break
            }
        }
    }

    private fun listBuckets(): List<Map<String, Any?>> {
        val buckets = linkedMapOf<String, MutableMap<String, Any?>>()
        for (item in listMedia(0, null)) {
            val id = item["bucketId"]?.toString() ?: continue
            val name = item["bucketName"]?.toString() ?: "本机相册"
            val existing = buckets.getOrPut(id) {
                mutableMapOf("id" to id, "name" to name, "count" to 0)
            }
            existing["count"] = (existing["count"] as Int) + 1
        }
        return buckets.values.sortedByDescending { it["count"] as Int }
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
        return try {
            contentResolver.openInputStream(Uri.parse(uriText)).use { input ->
                if (input == null) return ByteArray(0)
                var remainingSkip = offset
                while (remainingSkip > 0) {
                    val skipped = input.skip(remainingSkip)
                    if (skipped <= 0) break
                    remainingSkip -= skipped
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
        } catch (_: Exception) {
            ByteArray(0)
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

        val authContexts = mutableListOf<AuthenticationContext>()
        if (username.isNotBlank()) {
            authContexts.add(AuthenticationContext(username, password.toCharArray(), null))
        }
        authContexts.add(AuthenticationContext.guest())
        authContexts.add(AuthenticationContext.anonymous())

        var lastError: Exception? = null
        for (auth in authContexts) {
            try {
                return readSmbFileBytesWithAuth(config, host, auth, shareName, smbPath)
            } catch (error: Exception) {
                lastError = error
            }
        }

        throw lastError ?: IllegalStateException("SMB 读取失败")
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
}
