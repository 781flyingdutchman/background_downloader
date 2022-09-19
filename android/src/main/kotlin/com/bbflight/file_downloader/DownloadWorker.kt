package com.bbflight.file_downloader

import android.content.Context
import android.content.SharedPreferences
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
import io.ktor.utils.io.*
import io.ktor.utils.io.core.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.concurrent.locks.ReentrantLock
import kotlin.io.path.Path
import kotlin.io.path.pathString
import kotlin.random.Random


/// Partial version of the Dart side DownloadTask, only used for background loading
class BackgroundDownloadTask(
    val taskId: String,
    val url: String,
    val filename: String,
    val directory: String,
    val baseDirectory: Int
)

/// Defines a set of possible states which a [DownloadTask] can be in.
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
        const val keyTaskMap = "com.bbflight.file_downloader.taskMap"
        const val keyNativeMap = "com.bbflight.file_downloader.nativeMap"
        const val keyTaskIdMap = "com.bbflight.file_downloader.taskIdMap"

        /** Get the native map from UserDefaults. Maps taskId to native id */
        fun getNativeMap(prefs: SharedPreferences): MutableMap<String, String> {
            val jsonString = prefs.getString(keyNativeMap, "{}")
            val gson = Gson()
            val mapType = object : TypeToken<MutableMap<String, String>>() {}.type
            return gson.fromJson(jsonString, mapType)
        }

        /** Get the taskId map from TaskMap. Maps the native id to the taskId of the DownloadTask */
        fun getTaskIdMap(prefs: SharedPreferences): MutableMap<String, String> {
            val jsonString = prefs.getString(keyTaskIdMap, "{}")
            val gson = Gson()
            val mapType = object : TypeToken<MutableMap<String, String>>() {}.type
            return gson.fromJson(jsonString, mapType)
        }
    }

    private val prefsSuccess = "com.bbflight.file_downloader.success"
    private val prefsFailure = "com.bbflight.file_downloader.failure"
    private val prefsLock = ReentrantLock()


    override suspend fun doWork(): Result {
        val gson = Gson()
        val downloadTaskJsonString = inputData.getString(keyDownloadTask)
        val downloadTask = gson.fromJson(
            downloadTaskJsonString,
            BackgroundDownloadTask::class.java
        )
        Log.i(TAG, " Starting download for taskId ${downloadTask.taskId}")
        val filePath = pathToFileForTask(downloadTask)
        val status = downloadFile(downloadTask.url, filePath)
        sendStatusUpdate(downloadTask, status)
        return Result.success()
    }

    /** download a file from the urlString to the filePath */
    private suspend fun downloadFile(urlString: String, filePath: String): DownloadTaskStatus {
        try {
            val client = HttpClient(CIO)
            return client.prepareGet(urlString).execute { httpResponse ->
                if (httpResponse.status.value in 200..299) {
                    withContext(Dispatchers.IO) {
                        var dir = applicationContext.cacheDir
                        val tempFile = File.createTempFile(
                            "com.bbflight.file_downloader",
                            Random.nextInt().toString(),
                            dir
                        )
                        val channel: ByteReadChannel = httpResponse.body()
                        while (!channel.isClosedForRead) {
                            val packet = channel.readRemaining(DEFAULT_BUFFER_SIZE.toLong())
                            while (!packet.isEmpty) {
                                val bytes = packet.readBytes()
                                tempFile.appendBytes(bytes)
                            }
                        }
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
                    return DownloadTaskStatus.canceled;
                }
                else -> Log.w(TAG, "Error downloading from $urlString to $filePath: ${e.message}")
            }
            return DownloadTaskStatus.failed
        }
    }

    /** Records success or failure for this task by adding it to the list in preferences */
    private fun sendStatusUpdate(task: BackgroundDownloadTask, status: DownloadTaskStatus) {
        Handler(Looper.getMainLooper()).post {
            try {
                val arg = listOf<Any>(task.taskId, status.ordinal)
                FileDownloaderPlugin.backgroundChannel?.invokeMethod("completion", arg)
            } catch (e: Exception) {
                Log.w(TAG, "Exception trying to post result: ${e.message}")
            }
        }
    }


    /** Returns full path (String) to the file to be downloaded */
    private fun pathToFileForTask(task: BackgroundDownloadTask): String {
        val baseDir = when (task.baseDirectory) {
            0 -> applicationContext.dataDir
            1 -> applicationContext.cacheDir
            2 -> applicationContext.filesDir
            else -> throw IllegalArgumentException("BaseDirectory int value ${task.baseDirectory} out of range")
        }
        val path = Path(baseDir.path, task.directory)
        return Path(path.pathString, task.filename).pathString
    }

}


