package com.ngc.unraider

import android.content.Context
import android.content.ContentUris
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.util.Size
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

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
                            .putBoolean("useHttps", call.argument<Boolean>("useHttps") ?: false)
                    } else {
                        editor
                            .remove("domain")
                            .remove("username")
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
                        result.success(readChunk(uri, offset, length))
                    }
                }
                else -> result.notImplemented()
            }
        }
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
}
