@file:Suppress("EnumEntryName")

package com.bbflight.background_downloader

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import com.google.gson.Gson
import com.google.gson.reflect.TypeToken
import kotlinx.coroutines.CancellationException
import java.io.BufferedInputStream
import java.io.DataOutputStream
import java.io.File
import java.io.FileOutputStream
import java.lang.Double.min
import java.lang.System.currentTimeMillis
import java.net.HttpURLConnection
import java.net.SocketException
import java.net.URL
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import kotlin.concurrent.write
import kotlin.io.path.Path
import kotlin.io.path.pathString
import kotlin.random.Random


/// Base directory in which files will be stored, based on their relative
/// path.
///
/// These correspond to the directories provided by the path_provider package
enum class BaseDirectory {
    applicationDocuments,  // getApplicationDocumentsDirectory()
    temporary,  // getTemporaryDirectory()
    applicationSupport // getApplicationSupportDirectory()
}

/// Type of download updates requested for a group of downloads
enum class DownloadTaskProgressUpdates {
    none,  // no status or progress updates
    statusChange, // only calls upon change in DownloadTaskStatus
    progressUpdates, // only calls for progress
    statusChangeAndProgressUpdates // calls also for progress along the way
}

/// Partial version of the Dart side DownloadTask, only used for background loading
class BackgroundDownloadTask(
    val taskId: String,
    val url: String,
    val filename: String,
    val headers: Map<String, String>,
    val post: Any?,
    val directory: String,
    val baseDirectory: BaseDirectory,
    val group: String,
    val progressUpdates: DownloadTaskProgressUpdates,
    val requiresWiFi: Boolean,
    val retries: Int,
    val retriesRemaining: Int,
    val metaData: String
) {

    /** Creates object from JsonMap */
    constructor(jsonMap: Map<String, Any>) : this(
        taskId = jsonMap["taskId"] as String,
        url = jsonMap["url"] as String,
        filename = jsonMap["filename"] as String,
        headers = jsonMap["headers"] as Map<String, String>,
        post = jsonMap["post"],
        directory = jsonMap["directory"] as String,
        baseDirectory = BaseDirectory.values()[(jsonMap["baseDirectory"] as Double).toInt()],
        group = jsonMap["group"] as String,
        progressUpdates =
        DownloadTaskProgressUpdates.values()[(jsonMap["progressUpdates"] as Double).toInt()],
        requiresWiFi = jsonMap["requiresWiFi"] as Boolean,
        retries = (jsonMap["retries"] as Double).toInt(),
        retriesRemaining = (jsonMap["retriesRemaining"] as Double).toInt(),
        metaData = jsonMap["metaData"] as String
    )

    /** Creates JSON map of this object */
    fun toJsonMap(): Map<String, Any?> {
        return mapOf(
            "taskId" to taskId,
            "url" to url,
            "filename" to filename,
            "headers" to headers,
            "post" to post,
            "directory" to directory,
            "baseDirectory" to baseDirectory.ordinal, // stored as int
            "group" to group,
            "progressUpdates" to progressUpdates.ordinal,
            "requiresWiFi" to requiresWiFi,
            "retries" to retries,
            "retriesRemaining" to retriesRemaining,
            "metaData" to metaData
        )
    }

    /** True if this task expects to provide progress updates */
    fun providesProgressUpdates(): Boolean {
        return progressUpdates == DownloadTaskProgressUpdates.progressUpdates ||
                progressUpdates == DownloadTaskProgressUpdates.statusChangeAndProgressUpdates
    }

    /** True if this task expects to provide status updates */
    fun providesStatusUpdates(): Boolean {
        return progressUpdates == DownloadTaskProgressUpdates.statusChange ||
                progressUpdates == DownloadTaskProgressUpdates.statusChangeAndProgressUpdates
    }

}

/** Defines a set of possible states which a [BackgroundDownloadTask] can be in.
 *
 * Must match the Dart equivalent enum, as value are passed as ordinal/index integer
 */
enum class DownloadTaskStatus {
    enqueued,
    running,
    complete,
    notFound,
    failed,
    canceled,
    waitingToRetry;

    fun isNotFinalState(): Boolean {
        return this == enqueued || this == running || this == waitingToRetry
    }

    fun isFinalState(): Boolean {
        return !isNotFinalState()
    }
}


/***
 * A simple worker that will post your input back to your Flutter application.
 *
 * It will block the background thread until a value of either true or false is received back from Flutter code.
 */
class DownloadWorker(
    applicationContext: Context,
    workerParams: WorkerParameters
) :
    CoroutineWorker(applicationContext, workerParams) {

    companion object {
        const val TAG = "DownloadWorker"
        const val keyDownloadTask = "downloadTask"

        /**
         * Processes a change in status for the task
         *
         * Sends status update via the background channel to Flutter, if requested, and if the task
         * is finished, processes a final status update and remove references to persistent storage
         * */
        fun processStatusUpdate(
            backgroundDownloadTask: BackgroundDownloadTask,
            status: DownloadTaskStatus
        ) {
            // Post update if task expects one, or if failed and retry is needed
            val retryNeeded =
                status == DownloadTaskStatus.failed && backgroundDownloadTask.retriesRemaining > 0
            if (backgroundDownloadTask.providesStatusUpdates() || retryNeeded) {
                Handler(Looper.getMainLooper()).post {
                    try {
                        val gson = Gson()
                        val arg = listOf<Any>(
                            gson.toJson(backgroundDownloadTask.toJsonMap()),
                            status.ordinal
                        )
                        BackgroundDownloaderPlugin.backgroundChannel?.invokeMethod(
                            "statusUpdate",
                            arg
                        )
                    } catch (e: Exception) {
                        Log.w(TAG, "Exception trying to post status update: ${e.message}")
                    }
                }
            }
            // if task is in final state, process a final progressUpdate and remove from
            // persistent storage. A 'failed' progress update is only provided if
            // a retry is not needed: if it is needed, a `waitingToRetry` progress update
            // will be generated on the Dart side
            if (status.isFinalState()) {
                when (status) {
                    DownloadTaskStatus.complete -> processProgressUpdate(
                        backgroundDownloadTask,
                        1.0
                    )
                    DownloadTaskStatus.failed -> if (!retryNeeded) processProgressUpdate(
                        backgroundDownloadTask,
                        -1.0
                    )
                    DownloadTaskStatus.canceled -> processProgressUpdate(
                        backgroundDownloadTask,
                        -2.0
                    )
                    DownloadTaskStatus.notFound -> processProgressUpdate(
                        backgroundDownloadTask,
                        -3.0
                    )
                    else -> {}
                }
                BackgroundDownloaderPlugin.prefsLock.write {
                    val jsonString =
                        BackgroundDownloaderPlugin.prefs.getString(
                            BackgroundDownloaderPlugin.keyTasksMap,
                            "{}"
                        )
                    val backgroundDownloadTaskMap =
                        BackgroundDownloaderPlugin.gson.fromJson<Map<String, Any>>(
                            jsonString,
                            BackgroundDownloaderPlugin.mapType
                        ).toMutableMap()
                    backgroundDownloadTaskMap.remove(backgroundDownloadTask.taskId)
                    val editor = BackgroundDownloaderPlugin.prefs.edit()
                    editor.putString(
                        BackgroundDownloaderPlugin.keyTasksMap,
                        BackgroundDownloaderPlugin.gson.toJson(backgroundDownloadTaskMap)
                    )
                    editor.apply()
                }
            }
        }

        /**
         * Processes a progress update for the [backgroundDownloadTask]
         *
         * Sends progress update via the background channel to Flutter, if requested
         */
        fun processProgressUpdate(
            backgroundDownloadTask: BackgroundDownloadTask,
            progress: Double
        ) {
            if (backgroundDownloadTask.providesProgressUpdates()) {
                Handler(Looper.getMainLooper()).post {
                    try {
                        val gson = Gson()
                        val arg =
                            listOf<Any>(
                                gson.toJson(backgroundDownloadTask.toJsonMap()),
                                progress
                            )
                        BackgroundDownloaderPlugin.backgroundChannel?.invokeMethod(
                            "progressUpdate",
                            arg
                        )
                    } catch (e: Exception) {
                        Log.w(TAG, "Exception trying to post progress update: ${e.message}")
                    }
                }
            }
        }
    }


    override suspend fun doWork(): Result {
        val gson = Gson()
        val downloadTaskJsonMapString = inputData.getString(keyDownloadTask)
        val mapType = object : TypeToken<Map<String, Any>>() {}.type
        val downloadTask = BackgroundDownloadTask(
            gson.fromJson(downloadTaskJsonMapString, mapType)
        )
        Log.i(TAG, " Starting download for taskId ${downloadTask.taskId}")
        processStatusUpdate(downloadTask, DownloadTaskStatus.running)
        val filePath = pathToFileForTask(downloadTask)
        val status = downloadFile(downloadTask, filePath)
        processStatusUpdate(downloadTask, status)
        return Result.success()
    }

    /** download a file from the urlString to the filePath */
    private fun downloadFile(
        downloadTask: BackgroundDownloadTask,
        filePath: String
    ): DownloadTaskStatus {
        try {
            Log.v(TAG, "downloadFile")
            val urlString = downloadTask.url
            val url = URL(urlString)
            with(url.openConnection() as HttpURLConnection) {
                return makeRequest(this, downloadTask, filePath)
            }
        } catch (e: Exception) {
            Log.w(
                TAG,
                "Error downloading from ${downloadTask.url} to ${downloadTask.filename}: $e"
            )
        }
        return DownloadTaskStatus.failed
    }

    /** Make the request and process the result */
    private fun makeRequest(
        connection: HttpURLConnection, downloadTask: BackgroundDownloadTask,
        filePath: String
    ): DownloadTaskStatus {
        connection.instanceFollowRedirects = true
        for (header in downloadTask.headers) {
            connection.setRequestProperty(header.key, header.value)
        }
        try {
            if (downloadTask.post != null) {
                Log.v(TAG, "POST request")
                // post the data and requery the content length of the response
                connection.requestMethod = "POST"
                connection.doOutput = true
                when (downloadTask.post) {
                    is String -> {
                        connection.setRequestProperty(
                            "Content-Length",
                            downloadTask.post.length.toString()
                        )
                        DataOutputStream(connection.outputStream).use { it.writeBytes(downloadTask.post) }
                    }
                    is ByteArray -> {
                        connection.setRequestProperty(
                            "Content-Length",
                            downloadTask.post.size.toString()
                        )
                        DataOutputStream(connection.outputStream).use { it.write(downloadTask.post) }
                    }
                    else -> {
                        Log.w(
                            TAG,
                            "Type of post field must be String or ByteArray and is ${downloadTask.post::class}"
                        )
                        return DownloadTaskStatus.failed
                    }
                }
            } else {
                Log.v(TAG, "GET request")
                connection.requestMethod = "GET"
            }
            return processResponse(connection, downloadTask, filePath)
        } catch (e: Exception) {
            when (e) {
                is FileSystemException -> Log.w(
                    TAG,
                    "Filesystem exception downloading from ${downloadTask.url} to $filePath: ${e.message}"
                )
                is SocketException -> Log.i(
                    TAG,
                    "Socket exception downloading from ${downloadTask.url} to $filePath: ${e.message}"
                )
                is CancellationException -> {
                    Log.v(
                        TAG,
                        "Job cancelled: ${downloadTask.url} to $filePath: ${e.message}"
                    )
                    return DownloadTaskStatus.canceled
                }
                else -> Log.w(
                    TAG,
                    "Error downloading from ${downloadTask.url} to $filePath: ${e.message}"
                )
            }
        }
        return DownloadTaskStatus.failed
    }

    /** Process the response to the GET or POST request on this [connection] */
    private fun processResponse(
        connection: HttpURLConnection,
        downloadTask: BackgroundDownloadTask,
        filePath: String
    ): DownloadTaskStatus {
        if (connection.responseCode in 200..206) {
            var bytesReceivedTotal: Long = 0
            var lastProgressUpdate = 0.0
            var nextProgressUpdateTime = 0L
            var dir = applicationContext.cacheDir
            val tempFile = File.createTempFile(
                "com.bbflight.background_downloader",
                Random.nextInt().toString(),
                dir
            )
            BufferedInputStream(connection.inputStream).use { inputStream ->
                FileOutputStream(tempFile).use { fileOutputStream ->
                    val dataBuffer = ByteArray(8096)
                    var bytesRead: Int
                    while (inputStream.read(dataBuffer, 0, 8096)
                            .also { bytesRead = it } != -1
                    ) {
                        if (isStopped) {
                            break
                        }
                        fileOutputStream.write(dataBuffer, 0, bytesRead)
                        bytesReceivedTotal += bytesRead
                        val progress =
                            min(
                                bytesReceivedTotal.toDouble() / connection.contentLengthLong,
                                0.999
                            )
                        if (connection.contentLengthLong > 0 &&
                            (bytesReceivedTotal < 10000 || (progress - lastProgressUpdate > 0.02 && currentTimeMillis() > nextProgressUpdateTime))
                        ) {
                            processProgressUpdate(downloadTask, progress)
                            lastProgressUpdate = progress
                            nextProgressUpdateTime = currentTimeMillis() + 500
                        }
                    }
                }
            }
            if (!isStopped) {
                val destFile = File(filePath)
                dir = destFile.parentFile
                if (!dir.exists()) {
                    dir.mkdirs()
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    Files.move(
                        tempFile.toPath(),
                        destFile.toPath(),
                        StandardCopyOption.REPLACE_EXISTING
                    )
                } else {
                    tempFile.copyTo(destFile, overwrite = true)
                    tempFile.delete()
                }
            } else {
                Log.v(TAG, "Canceled task for $filePath")
                return DownloadTaskStatus.canceled
            }
            Log.i(
                TAG,
                "Successfully downloaded taskId ${downloadTask.taskId} to $filePath"
            )
            return DownloadTaskStatus.complete
        } else {
            Log.i(
                TAG,
                "Response code ${connection.responseCode} for download from  ${downloadTask.url} to $filePath"
            )
            return if (connection.responseCode == 404) {
                DownloadTaskStatus.notFound
            } else {
                DownloadTaskStatus.failed
            }
        }
    }


    /** Returns full path (String) to the file to be downloaded */
    private fun pathToFileForTask(task: BackgroundDownloadTask): String {
        val baseDirPath = when (task.baseDirectory) {
            BaseDirectory.applicationDocuments -> Path(
                applicationContext.dataDir.path,
                "app_flutter"
            ).pathString
            BaseDirectory.temporary -> applicationContext.cacheDir.path
            BaseDirectory.applicationSupport -> applicationContext.filesDir.path
        }
        val path = Path(baseDirPath, task.directory)
        return Path(path.pathString, task.filename).pathString
    }

}


