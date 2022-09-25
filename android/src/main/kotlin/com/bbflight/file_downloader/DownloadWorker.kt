@file:Suppress("EnumEntryName")

package com.bbflight.file_downloader

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import com.google.gson.Gson
import com.google.gson.reflect.TypeToken
import io.ktor.client.*
import io.ktor.client.call.*
import io.ktor.client.engine.cio.*
import io.ktor.client.plugins.*
import io.ktor.client.request.*
import io.ktor.http.*
import io.ktor.util.date.*
import io.ktor.utils.io.*
import io.ktor.utils.io.core.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.lang.Double.min
import java.nio.file.Files
import java.nio.file.StandardCopyOption
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
    val directory: String,
    val baseDirectory: BaseDirectory,
    val group: String,
    val progressUpdates: DownloadTaskProgressUpdates
) {

    /** Creates object from JsonMap */
    constructor(jsonMap: Map<String, Any>) : this(
        taskId = jsonMap["taskId"] as String,
        url = jsonMap["url"] as String,
        filename = jsonMap["filename"] as String,
        directory = jsonMap["directory"] as String,
        baseDirectory = BaseDirectory.values()[(jsonMap["baseDirectory"] as Double).toInt()],
        group = jsonMap["group"] as String,
        progressUpdates =
        DownloadTaskProgressUpdates.values()[(jsonMap["progressUpdates"] as Double).toInt()]
    )

    /** Creates JSON map of this object */
    fun toJsonMap(): Map<String, Any> {
        return mapOf(
            "taskId" to taskId,
            "url" to url,
            "filename" to filename,
            "directory" to directory,
            "baseDirectory" to baseDirectory.ordinal, // stored as int
            "group" to group,
            "progressUpdates" to progressUpdates.ordinal
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
    undefined,
    enqueued,
    running,
    complete,
    notFound,
    failed,
    canceled
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
         * is finished, processes a final status update
         * */
        fun processStatusUpdate(task: BackgroundDownloadTask, status: DownloadTaskStatus) {
            if (task.providesStatusUpdates()) {
                Handler(Looper.getMainLooper()).post {
                    try {
                        val gson = Gson()
                        val arg = listOf<Any>(gson.toJson(task.toJsonMap()), status.ordinal)
                        FileDownloaderPlugin.backgroundChannel?.invokeMethod("statusUpdate", arg)
                    } catch (e: Exception) {
                        Log.w(TAG, "Exception trying to post status update: ${e.message}")
                    }
                }
            }
            // if task is in final state, process a final progressUpdate
            if (status != DownloadTaskStatus.running && status != DownloadTaskStatus.enqueued) {
                when (status) {
                    DownloadTaskStatus.complete -> processProgressUpdate(task, 1.0)
                    DownloadTaskStatus.failed -> processProgressUpdate(task, -1.0)
                    DownloadTaskStatus.canceled -> processProgressUpdate(task, -2.0)
                    DownloadTaskStatus.notFound -> processProgressUpdate(task, -3.0)
                    else -> {}
                }
            }
        }

        fun processProgressUpdate(task: BackgroundDownloadTask, progress: Double) {
            if (task.providesProgressUpdates()) {
                Handler(Looper.getMainLooper()).post {
                    try {
                        val gson = Gson()
                        val arg = listOf<Any>(gson.toJson(task.toJsonMap()), progress)
                        FileDownloaderPlugin.backgroundChannel?.invokeMethod("progressUpdate", arg)
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
        val filePath = pathToFileForTask(downloadTask)
        val status = downloadFile(downloadTask, filePath)
        processStatusUpdate(downloadTask, status)
        return Result.success()
    }

    /** download a file from the urlString to the filePath */
    @Suppress("BlockingMethodInNonBlockingContext")
    private suspend fun downloadFile(
        downloadTask: BackgroundDownloadTask,
        filePath: String
    ): DownloadTaskStatus {
        val urlString = downloadTask.url
        try {
            val client = HttpClient(CIO) {
                install(HttpTimeout) {
                    requestTimeoutMillis = 8 * 60 * 1000 // 8 minutes
                }
            }
            return withContext(Dispatchers.IO) {
                return@withContext client.prepareGet(urlString).execute { httpResponse ->
                    if (httpResponse.status.value in 200..299) {
                        // try to determine content length. If not available, set to -1
                        val contentLengthString =
                            httpResponse.headers[HttpHeaders.ContentLength] ?: "-1"
                        val contentLength = try {
                            contentLengthString.toLong()
                        } catch (e: NumberFormatException) {
                            -1
                        }
                        var bytesReceivedTotal: Long = 0
                        var lastProgressUpdate = 0.0
                        var nextProgressUpdateTime = 0L
                        var dir = applicationContext.cacheDir
                        val tempFile = File.createTempFile(
                            "com.bbflight.file_downloader",
                            Random.nextInt().toString(),
                            dir
                        )
                        val channel: ByteReadChannel = httpResponse.body()
                        while (!channel.isClosedForRead && !isStopped) {
                            val packet = channel.readRemaining(DEFAULT_BUFFER_SIZE.toLong())
                            while (!packet.isEmpty) {
                                val bytes = packet.readBytes()
                                tempFile.appendBytes(bytes)
                                if (downloadTask.providesProgressUpdates()
                                    && contentLength > 0
                                    && getTimeMillis() > nextProgressUpdateTime) {
                                    bytesReceivedTotal += bytes.size
                                    val progress = min(bytesReceivedTotal.toDouble() / contentLength, 0.999)
                                    if (progress - lastProgressUpdate > 0.02) {
                                        processProgressUpdate(downloadTask, progress)
                                        lastProgressUpdate = progress
                                        nextProgressUpdateTime = getTimeMillis() + 500
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
                        }

                        if (isStopped) {
                            Log.i(TAG, "Canceled task for $filePath")
                            return@execute DownloadTaskStatus.canceled
                        }
                        Log.i(
                            TAG,
                            "Successfully downloaded taskId ${downloadTask.taskId} to $filePath"
                        )
                        return@execute DownloadTaskStatus.complete
                    } else {
                        Log.w(
                            TAG,
                            "Response code ${httpResponse.status.value} for download from  $urlString to $filePath"
                        )
                        if (httpResponse.status.value == 404) {
                            return@execute DownloadTaskStatus.notFound
                        } else {
                            return@execute DownloadTaskStatus.failed
                        }
                    }
                }
            }
        } catch (e: Exception) {
            when (e) {
                is FileSystemException -> Log.w(
                    TAG,
                    "Filesystem exception downloading from $urlString to $filePath: ${e.message}"
                )
                is HttpRequestTimeoutException -> Log.w(
                    TAG,
                    "Request timeout downloading from $urlString to $filePath: ${e.message}"
                )
                is CancellationException -> {
                    Log.i(TAG, "Job cancelled: $urlString to $filePath: ${e.message}")
                    return DownloadTaskStatus.canceled
                }
                else -> Log.w(TAG, "Error downloading from $urlString to $filePath: ${e.message}")
            }
        }
        return DownloadTaskStatus.failed
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


