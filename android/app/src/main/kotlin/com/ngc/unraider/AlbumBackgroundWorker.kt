package com.ngc.unraider

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.database.sqlite.SQLiteDatabase
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import androidx.core.app.NotificationCompat
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.ForegroundInfo
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters
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
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.Response
import okio.BufferedSink
import java.net.HttpURLConnection
import java.net.URL
import java.util.EnumSet
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

private const val BACKGROUND_PREFERENCES = "album_background"
private const val PERIODIC_WORK = "unraider-album-periodic"
private const val FOCUSED_WORK = "unraider-album-focused"
private const val NOTIFICATION_CHANNEL = "album_backup"
private const val NOTIFICATION_ID = 4271

object AlbumBackgroundScheduler {
    fun configure(context: Context, values: Map<String, Any?>) {
        val preferences = context.getSharedPreferences(BACKGROUND_PREFERENCES, Context.MODE_PRIVATE)
        preferences.edit().apply {
            values.forEach { (key, value) ->
                when (value) {
                    is Boolean -> putBoolean(key, value)
                    is Number -> putLong(key, value.toLong())
                    null -> remove(key)
                    else -> putString(key, value.toString())
                }
            }
        }.apply()
        if (values["enabled"] != true) {
            WorkManager.getInstance(context).cancelUniqueWork(PERIODIC_WORK)
            return
        }
        val constraints = constraints(values)
        val periodic = PeriodicWorkRequestBuilder<AlbumBackgroundWorker>(15, TimeUnit.MINUTES)
            .setConstraints(constraints)
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
            .addTag(PERIODIC_WORK)
            .build()
        WorkManager.getInstance(context).enqueueUniquePeriodicWork(
            PERIODIC_WORK,
            ExistingPeriodicWorkPolicy.UPDATE,
            periodic,
        )
    }

    fun runNow(context: Context, focused: Boolean = true) {
        val preferences = context.getSharedPreferences(BACKGROUND_PREFERENCES, Context.MODE_PRIVATE)
        val values = mapOf<String, Any?>(
            "wifiOnly" to preferences.getBoolean("wifiOnly", true),
            "chargingOnly" to preferences.getBoolean("chargingOnly", false),
        )
        val request = OneTimeWorkRequestBuilder<AlbumBackgroundWorker>()
            .setConstraints(constraints(values))
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
            .addTag(FOCUSED_WORK)
            .build()
        WorkManager.getInstance(context).enqueueUniqueWork(
            FOCUSED_WORK,
            if (focused) ExistingWorkPolicy.REPLACE else ExistingWorkPolicy.KEEP,
            request,
        )
    }

    fun cancelFocused(context: Context) {
        WorkManager.getInstance(context).cancelUniqueWork(FOCUSED_WORK)
    }

    fun status(context: Context): Map<String, Any?> {
        val preferences = context.getSharedPreferences(BACKGROUND_PREFERENCES, Context.MODE_PRIVATE)
        return mapOf(
            "stage" to preferences.getString("stage", "idle"),
            "pending" to preferences.getInt("pending", 0),
            "completed" to preferences.getInt("completed", 0),
            "failed" to preferences.getInt("failed", 0),
            "bytesPerSecond" to preferences.getLong("bytesPerSecond", 0L),
            "lastSuccessMs" to preferences.getLong("lastSuccessMs", 0L),
            "lastRunMs" to preferences.getLong("lastRunMs", 0L),
            "lastError" to preferences.getString("lastError", ""),
        )
    }

    private fun constraints(values: Map<String, Any?>): Constraints =
        Constraints.Builder()
            .setRequiredNetworkType(
                if (values["wifiOnly"] == true) NetworkType.UNMETERED else NetworkType.CONNECTED,
            )
            .setRequiresCharging(values["chargingOnly"] == true)
            .setRequiresBatteryNotLow(true)
            .setRequiresStorageNotLow(true)
            .build()
}

class AlbumBackgroundWorker(
    context: Context,
    parameters: WorkerParameters,
) : Worker(context, parameters) {
    private val preferences =
        applicationContext.getSharedPreferences(BACKGROUND_PREFERENCES, Context.MODE_PRIVATE)

    override fun doWork(): Result {
        val started = System.currentTimeMillis()
        setForegroundAsync(foreground("正在扫描本机媒体", 0, 0))
        updateStatus(stage = "scanning", lastRunMs = started, lastError = "")
        val databaseFile = applicationContext.getDatabasePath("album_backup_v1.db")
        if (!databaseFile.exists()) {
            updateStatus(stage = "blocked", lastError = "相册索引尚未初始化，请先打开一次相册")
            return Result.success()
        }
        val config = BackgroundTransferConfig.from(preferences)
        if (!config.isUsable) {
            updateStatus(stage = "blocked", lastError = config.blockedReason)
            return Result.success()
        }
        val database = SQLiteDatabase.openDatabase(
            databaseFile.absolutePath,
            null,
            SQLiteDatabase.OPEN_READWRITE,
        )
        return try {
            database.execSQL("PRAGMA foreign_keys = ON")
            recoverExpiredLeases(database)
            discoverChangedMedia(database)
            val jobs = claimJobs(database, limit = 50)
            updateStatus(stage = "uploading", pending = jobs.size, completed = 0, failed = 0)
            if (jobs.isEmpty()) {
                updateStatus(stage = "completed", pending = 0, completed = 0, failed = 0)
                return Result.success()
            }
            val completed = AtomicInteger(0)
            val failed = AtomicInteger(0)
            val bytes = AtomicLong(0)
            val executor = Executors.newFixedThreadPool(config.concurrency.coerceIn(1, 4))
            val uploader = BackgroundUploader(applicationContext, config)
            try {
                val futures = jobs.map { job ->
                    executor.submit {
                        if (isStopped) return@submit
                        try {
                            val remoteSize = uploader.upload(job)
                            markCompleted(database, job, remoteSize)
                            bytes.addAndGet(remoteSize)
                            val done = completed.incrementAndGet()
                            val elapsed = (System.currentTimeMillis() - started).coerceAtLeast(1)
                            val speed = bytes.get() * 1000L / elapsed
                            val fallbackNotice = uploader.fallbackNotice
                            updateStatus(
                                stage = "uploading",
                                pending = (jobs.size - done - failed.get()).coerceAtLeast(0),
                                completed = done,
                                failed = failed.get(),
                                bytesPerSecond = speed,
                                lastError = fallbackNotice,
                            )
                            setForegroundAsync(
                                foreground(
                                    fallbackNotice ?: "正在备份 ${job.name}",
                                    done + failed.get(),
                                    jobs.size,
                                ),
                            )
                        } catch (error: Exception) {
                            markFailed(database, job, error.message ?: error.javaClass.simpleName)
                            failed.incrementAndGet()
                            updateStatus(lastError = error.message ?: "后台上传失败")
                        }
                    }
                }
                futures.forEach { it.get() }
            } finally {
                executor.shutdownNow()
                uploader.close()
            }
            val stage = if (failed.get() == 0) "completed" else "partial_failure"
            updateStatus(
                stage = stage,
                pending = (jobs.size - completed.get() - failed.get()).coerceAtLeast(0),
                completed = completed.get(),
                failed = failed.get(),
                lastSuccessMs = if (completed.get() > 0) System.currentTimeMillis() else null,
            )
            Result.success()
        } catch (error: Exception) {
            updateStatus(stage = "failed", lastError = error.message ?: error.javaClass.simpleName)
            Result.retry()
        } finally {
            database.close()
        }
    }

    private fun foreground(text: String, progress: Int, total: Int): ForegroundInfo {
        val manager = applicationContext.getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(
                    NOTIFICATION_CHANNEL,
                    "相册备份",
                    NotificationManager.IMPORTANCE_LOW,
                ),
            )
        }
        val intent = applicationContext.packageManager
            .getLaunchIntentForPackage(applicationContext.packageName)
        val pendingIntent = PendingIntent.getActivity(
            applicationContext,
            0,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(applicationContext, NOTIFICATION_CHANNEL)
            .setSmallIcon(applicationContext.applicationInfo.icon)
            .setContentTitle("Unraider 相册备份")
            .setContentText(text)
            .setOnlyAlertOnce(true)
            .setOngoing(progress < total)
            .setContentIntent(pendingIntent)
            .apply { if (total > 0) setProgress(total, progress, false) }
            .build()
        return ForegroundInfo(
            NOTIFICATION_ID,
            notification,
            ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
        )
    }

    @Synchronized
    private fun updateStatus(
        stage: String? = null,
        pending: Int? = null,
        completed: Int? = null,
        failed: Int? = null,
        bytesPerSecond: Long? = null,
        lastSuccessMs: Long? = null,
        lastRunMs: Long? = null,
        lastError: String? = null,
    ) {
        preferences.edit().apply {
            stage?.let { putString("stage", it) }
            pending?.let { putInt("pending", it) }
            completed?.let { putInt("completed", it) }
            failed?.let { putInt("failed", it) }
            bytesPerSecond?.let { putLong("bytesPerSecond", it) }
            lastSuccessMs?.let { putLong("lastSuccessMs", it) }
            lastRunMs?.let { putLong("lastRunMs", it) }
            lastError?.let { putString("lastError", it) }
        }.apply()
    }

    private fun recoverExpiredLeases(database: SQLiteDatabase) {
        database.execSQL(
            "UPDATE backup_records SET state='failed', last_error='后台任务中断，已恢复队列', " +
                "next_retry_ms=?, lease_owner=NULL, lease_expires_ms=NULL " +
                "WHERE state IN ('uploading','verifying') AND lease_expires_ms IS NOT NULL " +
                "AND lease_expires_ms <= ?",
            arrayOf(System.currentTimeMillis(), System.currentTimeMillis()),
        )
    }

    private fun discoverChangedMedia(database: SQLiteDatabase) {
        val sources = mutableListOf<BackgroundSource>()
        database.rawQuery(
            "SELECT id,volume_name,relative_path,display_name,destination_id,remote_base_path," +
                "device_id,device_name,initial_mode,baseline_ms,include_images,include_videos " +
                "FROM source_folders WHERE enabled=1",
            null,
        ).use { cursor ->
            while (cursor.moveToNext()) {
                sources.add(
                    BackgroundSource(
                        id = cursor.getString(0),
                        volume = cursor.getString(1),
                        relativePath = normalizeRelative(cursor.getString(2)),
                        displayName = cursor.getString(3),
                        destinationId = cursor.getString(4),
                        remoteRoot = cursor.getString(5),
                        deviceId = cursor.getString(6),
                        deviceName = cursor.getString(7),
                        initialMode = cursor.getString(8),
                        baselineMs = cursor.getLong(9),
                        includeImages = cursor.getInt(10) == 1,
                        includeVideos = cursor.getInt(11) == 1,
                    ),
                )
            }
        }
        if (sources.isEmpty()) return
        var minimumModified = Long.MAX_VALUE
        database.rawQuery("SELECT MIN(last_modified_ms) FROM discovery_checkpoints", null).use { cursor ->
            if (cursor.moveToFirst() && !cursor.isNull(0)) minimumModified = cursor.getLong(0)
        }
        if (minimumModified == Long.MAX_VALUE) minimumModified = 0
        queryChangedCollection(database, sources, videos = false, minimumModified)
        queryChangedCollection(database, sources, videos = true, minimumModified)
        val now = System.currentTimeMillis()
        sources.forEach { source ->
            database.execSQL(
                "UPDATE discovery_checkpoints SET last_scan_completed_ms=?, last_modified_ms=? " +
                    "WHERE source_folder_id=?",
                arrayOf(now, now - 1000, source.id),
            )
        }
    }

    private fun queryChangedCollection(
        database: SQLiteDatabase,
        sources: List<BackgroundSource>,
        videos: Boolean,
        minimumModifiedMs: Long,
    ) {
        val collection = if (videos) {
            MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL)
        } else {
            MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL)
        }
        val projection = arrayOf(
            MediaStore.MediaColumns._ID,
            MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.RELATIVE_PATH,
            MediaStore.MediaColumns.MIME_TYPE,
            MediaStore.MediaColumns.SIZE,
            MediaStore.MediaColumns.DATE_ADDED,
            MediaStore.MediaColumns.DATE_MODIFIED,
            MediaStore.MediaColumns.BUCKET_ID,
            MediaStore.MediaColumns.BUCKET_DISPLAY_NAME,
            MediaStore.MediaColumns.WIDTH,
            MediaStore.MediaColumns.HEIGHT,
        )
        val selection = "${MediaStore.MediaColumns.DATE_MODIFIED}>=?"
        val args = arrayOf(((minimumModifiedMs - 1000).coerceAtLeast(0) / 1000).toString())
        applicationContext.contentResolver.query(
            collection,
            projection,
            selection,
            args,
            "${MediaStore.MediaColumns.DATE_MODIFIED} ASC",
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                val id = cursor.getLong(0)
                val uri = ContentUris.withAppendedId(collection, id)
                val volume = MediaStore.getVolumeName(uri)
                val relative = normalizeRelative(cursor.getString(2).orEmpty())
                val matching = sources
                    .filter { source ->
                        (source.volume == "*" || source.volume == volume) &&
                            relative.lowercase().startsWith(source.relativePath.lowercase()) &&
                            if (videos) source.includeVideos else source.includeImages
                    }
                    .groupBy { it.destinationId }
                    .mapNotNull { (_, values) -> values.maxByOrNull { it.relativePath.length } }
                if (matching.isEmpty()) continue
                val kind = if (videos) "video" else "image"
                val assetId = "$volume:$kind:$id"
                val now = System.currentTimeMillis()
                val name = cursor.getString(1).orEmpty()
                val size = cursor.getLong(4)
                val added = cursor.getLong(5) * 1000L
                val modified = cursor.getLong(6) * 1000L
                val values = ContentValues().apply {
                    put("id", assetId)
                    put("volume_name", volume)
                    put("media_store_id", id.toString())
                    put("uri", uri.toString())
                    put("relative_path", relative)
                    put("display_name", name)
                    put("mime_type", cursor.getString(3).orEmpty())
                    put("media_kind", kind)
                    put("size_bytes", size)
                    put("date_added_ms", added)
                    put("date_modified_ms", modified)
                    put("capture_time_ms", modified)
                    put("width", cursor.getInt(9))
                    put("height", cursor.getInt(10))
                    put("duration_ms", 0)
                    put("orientation", 0)
                    put("bucket_id", cursor.getString(7).orEmpty())
                    put("bucket_name", cursor.getString(8).orEmpty())
                    put("last_seen_scan_id", "background-$now")
                    put("missing_local", 0)
                    put("updated_at_ms", now)
                }
                database.insertWithOnConflict("media_assets", null, values, SQLiteDatabase.CONFLICT_IGNORE)
                database.update("media_assets", values.apply { remove("id") }, "id=?", arrayOf(assetId))
                matching.forEach { source ->
                    val eligible = source.initialMode == "all" || added > source.baselineMs
                    if (!eligible) return@forEach
                    val remotePath = buildRemotePath(source, relative, name, assetId)
                    val record = ContentValues().apply {
                        put("asset_id", assetId)
                        put("destination_id", source.destinationId)
                        put("source_folder_id", source.id)
                        put("remote_path", remotePath)
                        put("state", "queued")
                        put("uploaded_bytes", 0)
                        put("total_bytes", size)
                        put("retry_count", 0)
                        put("thumbnail_state", "missing")
                        put("updated_at_ms", now)
                    }
                    database.insertWithOnConflict(
                        "backup_records",
                        null,
                        record,
                        SQLiteDatabase.CONFLICT_IGNORE,
                    )
                }
            }
        }
    }

    @Synchronized
    private fun claimJobs(database: SQLiteDatabase, limit: Int): List<BackgroundJob> {
        val jobs = mutableListOf<BackgroundJob>()
        val now = System.currentTimeMillis()
        database.beginTransaction()
        try {
            database.rawQuery(
                "SELECT br.asset_id,br.destination_id,br.remote_path,ma.uri,ma.display_name," +
                    "ma.size_bytes,ma.date_modified_ms FROM backup_records br " +
                    "JOIN media_assets ma ON ma.id=br.asset_id " +
                    "WHERE ma.missing_local=0 AND (br.state='queued' OR " +
                    "(br.state='failed' AND (br.next_retry_ms IS NULL OR br.next_retry_ms<=?))) " +
                    "ORDER BY br.updated_at_ms LIMIT ?",
                arrayOf(now.toString(), limit.toString()),
            ).use { cursor ->
                while (cursor.moveToNext()) {
                    val job = BackgroundJob(
                        assetId = cursor.getString(0),
                        destinationId = cursor.getString(1),
                        remotePath = cursor.getString(2),
                        uri = cursor.getString(3),
                        name = cursor.getString(4),
                        size = cursor.getLong(5),
                        modifiedMs = cursor.getLong(6),
                    )
                    jobs.add(job)
                    database.execSQL(
                        "UPDATE backup_records SET state='uploading', lease_owner=?, " +
                            "lease_expires_ms=?, last_error=NULL, updated_at_ms=? " +
                            "WHERE asset_id=? AND destination_id=?",
                        arrayOf(id.toString(), now + TimeUnit.MINUTES.toMillis(30), now, job.assetId, job.destinationId),
                    )
                }
            }
            database.setTransactionSuccessful()
        } finally {
            database.endTransaction()
        }
        return jobs
    }

    @Synchronized
    private fun markCompleted(database: SQLiteDatabase, job: BackgroundJob, size: Long) {
        val now = System.currentTimeMillis()
        database.execSQL(
            "UPDATE backup_records SET state='completed', uploaded_bytes=?, remote_size=?, " +
                "remote_modified_ms=?, last_error=NULL, next_retry_ms=NULL, lease_owner=NULL, " +
                "lease_expires_ms=NULL, updated_at_ms=? WHERE asset_id=? AND destination_id=?",
            arrayOf(size, size, job.modifiedMs, now, job.assetId, job.destinationId),
        )
    }

    @Synchronized
    private fun markFailed(database: SQLiteDatabase, job: BackgroundJob, message: String) {
        val now = System.currentTimeMillis()
        database.execSQL(
            "UPDATE backup_records SET state='failed', retry_count=retry_count+1, last_error=?, " +
                "next_retry_ms=?, lease_owner=NULL, lease_expires_ms=NULL, updated_at_ms=? " +
                "WHERE asset_id=? AND destination_id=?",
            arrayOf(message, now + TimeUnit.MINUTES.toMillis(1), now, job.assetId, job.destinationId),
        )
    }
}

private data class BackgroundSource(
    val id: String,
    val volume: String,
    val relativePath: String,
    val displayName: String,
    val destinationId: String,
    val remoteRoot: String,
    val deviceId: String,
    val deviceName: String,
    val initialMode: String,
    val baselineMs: Long,
    val includeImages: Boolean,
    val includeVideos: Boolean,
)

private data class BackgroundJob(
    val assetId: String,
    val destinationId: String,
    val remotePath: String,
    val uri: String,
    val name: String,
    val size: Long,
    val modifiedMs: Long,
)

private data class BackgroundTransferConfig(
    val host: String,
    val username: String,
    val password: String,
    val webDavEnabled: Boolean,
    val webDavUrl: String,
    val webDavPrefix: String,
    val webDavToken: String,
    val concurrency: Int,
) {
    val isUsable: Boolean
        get() = host.isNotBlank() && username.isNotBlank() && password.isNotBlank()
    val blockedReason: String
        get() = if (password.isBlank()) {
            "后台备份需要保存登录凭据，请开启记住登录"
        } else {
            "后台备份连接配置不完整"
        }

    companion object {
        fun from(preferences: android.content.SharedPreferences) = BackgroundTransferConfig(
            host = preferences.getString("host", "").orEmpty(),
            username = preferences.getString("username", "root").orEmpty(),
            password = preferences.getString("password", "").orEmpty(),
            webDavEnabled = preferences.getBoolean("webDavEnabled", false),
            webDavUrl = preferences.getString("webDavUrl", "").orEmpty(),
            webDavPrefix = preferences.getString("webDavPrefix", "/mnt/user").orEmpty(),
            webDavToken = preferences.getString("webDavToken", "").orEmpty(),
            concurrency = preferences.getLong("concurrency", 2).toInt(),
        )
    }
}

private class BackgroundUploader(
    private val context: Context,
    private val config: BackgroundTransferConfig,
) : AutoCloseable {
    private var smbClient: SMBClient? = null
    private var smbConnection: Connection? = null
    private val shares = mutableMapOf<String, DiskShare>()
    private val webDavDirectoryLock = Any()
    private val verifiedWebDavDirectories = mutableSetOf<String>()
    @Volatile
    var fallbackNotice: String? = null
        private set
    private val webDavClient = OkHttpClient.Builder()
        .connectTimeout(20, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS)
        .writeTimeout(10, TimeUnit.MINUTES)
        .retryOnConnectionFailure(true)
        .build()

    fun upload(job: BackgroundJob): Long {
        val webDavTarget = webDavUrl(job.remotePath)
        var webDavFailure: Exception? = null
        if (webDavTarget != null) {
            try {
                return uploadWebDav(job, webDavTarget)
            } catch (error: Exception) {
                webDavFailure = error
                fallbackNotice = "WebDAV 连接失败，已自动降级为 SMB 上传"
            }
        }
        return try {
            uploadSmb(job)
        } catch (error: Exception) {
            if (webDavFailure != null) {
                throw IllegalStateException(
                    "WebDAV 连接失败，降级到 SMB 后仍上传失败：${error.message ?: error.javaClass.simpleName}",
                    error,
                )
            }
            throw error
        }
    }

    private fun uploadSmb(job: BackgroundJob): Long {
        val parts = job.remotePath.replace('\\', '/').split('/').filter { it.isNotBlank() }
        require(parts.size >= 4 && parts[0] == "mnt" && parts[1] == "user") {
            "后台 SMB 仅支持 /mnt/user/<共享> 路径"
        }
        val shareName = parts[2]
        val finalPath = parts.drop(3).joinToString("\\")
        val tempPath = "$finalPath.part-${UUID.randomUUID()}"
        val share = share(shareName)
        ensureDirectories(share, finalPath.substringBeforeLast('\\', ""))
        if (share.fileExists(finalPath)) {
            val size = share.getFileInformation(finalPath).standardInformation.endOfFile
            if (size == job.size) return size
            throw IllegalStateException("目标文件已存在且大小不同")
        }
        try {
            share.openFile(
                tempPath,
                EnumSet.of(AccessMask.GENERIC_WRITE, AccessMask.GENERIC_READ),
                EnumSet.noneOf(FileAttributes::class.java),
                SMB2ShareAccess.ALL,
                SMB2CreateDisposition.FILE_OVERWRITE_IF,
                EnumSet.of(SMB2CreateOptions.FILE_NON_DIRECTORY_FILE),
            ).use { remote ->
                context.contentResolver.openInputStream(Uri.parse(job.uri)).use { input ->
                    requireNotNull(input) { "无法打开本机媒体" }
                    remote.outputStream.use { input.copyTo(it, 1024 * 1024) }
                }
            }
            val size = share.getFileInformation(tempPath).standardInformation.endOfFile
            if (size != job.size) throw IllegalStateException("SMB 后台上传大小校验失败")
            share.openFile(
                tempPath,
                EnumSet.of(AccessMask.DELETE),
                EnumSet.noneOf(FileAttributes::class.java),
                SMB2ShareAccess.ALL,
                SMB2CreateDisposition.FILE_OPEN,
                EnumSet.of(SMB2CreateOptions.FILE_NON_DIRECTORY_FILE),
            ).use { it.rename(finalPath) }
            return size
        } catch (error: Exception) {
            try { if (share.fileExists(tempPath)) share.rm(tempPath) } catch (_: Exception) {}
            throw error
        }
    }

    private fun uploadWebDav(job: BackgroundJob, finalUrl: URL): Long {
        val tempUrl = URL("${finalUrl}.part-${UUID.randomUUID()}")
        val existing = head(finalUrl)
        if (existing.first in 200..299) {
            if (existing.second == job.size) return job.size
            throw IllegalStateException("目标文件已存在且大小不同")
        }
        ensureWebDavDirectories(finalUrl)
        try {
            val requestBody = object : RequestBody() {
                override fun contentType() = "application/octet-stream".toMediaType()

                override fun contentLength() = job.size

                override fun writeTo(sink: BufferedSink) {
                    context.contentResolver.openInputStream(Uri.parse(job.uri)).use { input ->
                        requireNotNull(input) { "无法打开本机媒体" }
                        val buffer = ByteArray(1024 * 1024)
                        var written = 0L
                        while (true) {
                            val read = input.read(buffer)
                            if (read <= 0) break
                            sink.write(buffer, 0, read)
                            written += read
                        }
                        check(written == job.size) {
                            "读取本机媒体不完整：期望 ${job.size}，实际 $written"
                        }
                    }
                }
            }
            val code = executeWebDavRequest(
                url = tempUrl,
                method = "PUT",
                body = requestBody,
            ).use { it.code }
            if (code !in 200..299 || head(tempUrl).second != job.size) {
                throw IllegalStateException("WebDAV 后台上传校验失败")
            }
            val moveCode = executeWebDavRequest(
                url = tempUrl,
                method = "MOVE",
                headers = mapOf(
                    "Destination" to finalUrl.toString(),
                    "Overwrite" to "F",
                ),
            ).use { it.code }
            if (moveCode !in 200..299 || head(finalUrl).second != job.size) {
                throw IllegalStateException("WebDAV 后台安全提交失败")
            }
            return job.size
        } catch (error: Exception) {
            try { executeWebDavRequest(tempUrl, "DELETE").close() } catch (_: Exception) {}
            throw error
        }
    }

    @Synchronized
    private fun share(name: String): DiskShare {
        shares[name]?.let { return it }
        if (smbClient == null) {
            smbClient = SMBClient(
                SmbConfig.builder()
                    .withTimeout(30, TimeUnit.SECONDS)
                    .withSoTimeout(60, TimeUnit.SECONDS)
                    .build(),
            )
            smbConnection = smbClient!!.connect(config.host)
        }
        val session = smbConnection!!.authenticate(
            AuthenticationContext(config.username, config.password.toCharArray(), null),
        )
        return (session.connectShare(name) as DiskShare).also { shares[name] = it }
    }

    private fun ensureDirectories(share: DiskShare, directory: String) {
        var current = ""
        directory.split('\\').filter { it.isNotBlank() }.forEach { part ->
            current = if (current.isEmpty()) part else "$current\\$part"
            if (!share.folderExists(current)) share.mkdir(current)
        }
    }

    private fun webDavUrl(remotePath: String): URL? {
        if (!config.webDavEnabled || config.webDavUrl.isBlank() || config.webDavToken.isBlank()) return null
        val normalized = remotePath.replace('\\', '/')
        val prefix = config.webDavPrefix.trimEnd('/')
        if (!normalized.startsWith("$prefix/")) return null
        val relative = normalized.removePrefix("$prefix/")
        val base = config.webDavUrl.trimEnd('/')
        return URL("$base/${relative.split('/').joinToString("/") { encodePath(it) }}")
    }

    private fun ensureWebDavDirectories(target: URL) {
        val root = URL(config.webDavUrl)
        require(
            target.protocol == root.protocol &&
                target.host == root.host &&
                target.port == root.port
        ) { "WebDAV 目标不在配置的服务器上" }
        val rootPath = root.toString().toHttpUrl().encodedPath.trimEnd('/')
        val parentPath = target.toString().toHttpUrl().encodedPath
            .substringBeforeLast('/', "")
            .trimEnd('/')
        require(parentPath == rootPath || parentPath.startsWith("$rootPath/")) {
            "WebDAV 目标不在配置的基础目录下"
        }
        val relative = parentPath.removePrefix(rootPath).trim('/')
        if (relative.isEmpty()) return
        synchronized(webDavDirectoryLock) {
            var path = rootPath
            relative.split('/').filter { it.isNotBlank() }.forEach { segment ->
                path += "/$segment"
                val url = URL(target.protocol, target.host, target.port, path)
                val key = url.toString()
                if (verifiedWebDavDirectories.contains(key)) return@forEach
                val code = webDavDirectoryStatus(url)
                if (code == HttpURLConnection.HTTP_NOT_FOUND) {
                    val mkdirCode = executeWebDavRequest(url, "MKCOL").use { it.code }
                    if (
                        mkdirCode !in 200..299 &&
                        mkdirCode != HttpURLConnection.HTTP_CONFLICT &&
                        mkdirCode != HttpURLConnection.HTTP_BAD_METHOD
                    ) {
                        throw IllegalStateException("WebDAV 创建目录失败（HTTP $mkdirCode）")
                    }
                } else if (code !in 200..299) {
                    throw IllegalStateException("WebDAV 检查目录失败（HTTP $code）")
                }
                verifiedWebDavDirectories.add(key)
            }
        }
    }

    private fun webDavDirectoryStatus(url: URL): Int =
        executeWebDavRequest(
            url = url,
            method = "PROPFIND",
            headers = mapOf("Depth" to "0"),
        ).use { it.code }

    private fun head(url: URL): Pair<Int, Long> {
        return executeWebDavRequest(url, "HEAD").use { response ->
            response.code to (response.header("Content-Length")?.toLongOrNull() ?: -1L)
        }
    }

    private fun executeWebDavRequest(
        url: URL,
        method: String,
        headers: Map<String, String> = emptyMap(),
        body: RequestBody? = null,
    ): Response {
        val token = android.util.Base64.encodeToString(
            "unraider:${config.webDavToken}".toByteArray(),
            android.util.Base64.NO_WRAP,
        )
        val request = Request.Builder()
            .url(url)
            .header("Authorization", "Basic $token")
            .header("Accept-Encoding", "identity")
            .apply { headers.forEach { (name, value) -> header(name, value) } }
            .method(method, body)
            .build()
        return webDavClient.newCall(request).execute()
    }

    override fun close() {
        shares.values.forEach { try { it.close() } catch (_: Exception) {} }
        try { smbConnection?.close() } catch (_: Exception) {}
        try { smbClient?.close() } catch (_: Exception) {}
    }
}

private fun normalizeRelative(value: String): String {
    val segments = value.replace('\\', '/').split('/').filter { it.isNotBlank() && it != "." }
    if (segments.any { it == ".." }) return ""
    return if (segments.isEmpty()) "" else segments.joinToString("/") + "/"
}

private fun stableKey(value: String): String {
    var hash = 0x811c9dc5L
    value.forEach { character ->
        hash = hash xor character.code.toLong()
        hash = (hash * 0x01000193L) and 0xffffffffL
    }
    return hash.toString(16).padStart(8, '0')
}

private fun safeSegment(value: String, fallback: String): String {
    val sanitized = value
        .replace(Regex("[\\x00-\\x1f\\x7f/\\\\:*?\"<>|]"), "_")
        .trim()
        .replace(Regex("[. ]+$"), "")
    return if (sanitized.isBlank() || sanitized == "." || sanitized == "..") fallback else sanitized
}

private fun buildRemotePath(
    source: BackgroundSource,
    assetRelativePath: String,
    name: String,
    assetId: String,
): String {
    val rawDeviceId = source.deviceId.replace(Regex("[^a-zA-Z0-9]"), "")
    val deviceSuffix = (if (rawDeviceId.isBlank()) stableKey(source.deviceName) else rawDeviceId).take(8)
    val device = "${safeSegment(source.deviceName, "Android")}-$deviceSuffix"
    val sourceDirectory = "${safeSegment(source.displayName, "Photos")}-${stableKey(source.id).take(6)}"
    val relative = if (source.relativePath.isEmpty()) {
        assetRelativePath
    } else {
        assetRelativePath.removePrefix(source.relativePath)
    }
    val directories = relative.split('/').filter { it.isNotBlank() }.map { safeSegment(it, "folder") }
    val filename = safeSegment(name, "media_${stableKey(assetId)}")
    return (listOf(source.remoteRoot.trimEnd('/'), device, sourceDirectory) + directories + filename)
        .joinToString("/")
}

private fun encodePath(value: String): String =
    Uri.encode(value).replace("+", "%20")
