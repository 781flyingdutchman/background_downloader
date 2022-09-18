package com.bbflight.file_downloader

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.preference.PreferenceManager
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
    val savedDir: String,
    val baseDirectory: Int
)

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
        val success = downloadFile(downloadTask.url, filePath)
        recordSuccessOrFailure(downloadTask, success)
//        val prefs = PreferenceManager.getDefaultSharedPreferences(applicationContext)
//        Log.v(TAG, "Success= ${prefs.getString(prefsSuccess, "EMPTY")}")
//        Log.v(TAG, "Failure= ${prefs.getString(prefsFailure, "EMPTY")}")
        return Result.success()
    }

    /** download a file from the urlString to the filePath */
    private suspend fun downloadFile(urlString: String, filePath: String): Boolean {
        try {
            val client = HttpClient(CIO)
            return client.prepareGet(urlString).execute { httpResponse ->
                if (httpResponse.status.value in 200..299) {
                    withContext(Dispatchers.IO) {
                        var dir = applicationContext.cacheDir
                        val tempFile = File.createTempFile("com.bbflight.file_downloader", Random.nextInt().toString(), dir)
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
                            Files.move(tempFile.toPath(), destFile.toPath(), StandardCopyOption.REPLACE_EXISTING)
                        }
                        else {
                            tempFile.copyTo(destFile, overwrite = true)
                            tempFile.delete()
                        }
                    }
                    return@execute true
                } else {
                    Log.w(TAG, "Response code ${httpResponse.status.value} for download from  $urlString to $filePath")
                    return@execute false
                }
            }
        } catch (e: Exception) {
            when (e) {
                is FileSystemException -> Log.w(TAG, "Filesystem exception downloading from $urlString to $filePath: ${e.message}")
                is HttpRequestTimeoutException -> Log.w(TAG, "Request timeout downloading from $urlString to $filePath: ${e.message}")
                else -> Log.w(TAG, "Error downloading from $urlString to $filePath: ${e.message}")
            }
            return false
        }
    }

    /** Records success or failure for this task by adding it to the list in preferences */
    private fun recordSuccessOrFailure(task: BackgroundDownloadTask, success: Boolean) {
        Handler(Looper.getMainLooper()).post {
            try {
                val arg = listOf<Any>(task.taskId, success)
                FileDownloaderPlugin.backgroundChannel?.invokeMethod("completion", arg)
            } catch (e: Exception) {
                Log.w(TAG, "Exception trying to post result: ${e.message}")
            }
        }
        prefsLock.lock()  // Only one thread can access prefs at the same time
        try {
            val prefsKey = if (success) prefsSuccess else prefsFailure
            val prefs = PreferenceManager.getDefaultSharedPreferences(applicationContext)
            val existingAsJsonString = prefs.getString(prefsKey, "")
            val gson = Gson()
            val arrayBackgroundDownloadTaskType =
                object : TypeToken<MutableList<BackgroundDownloadTask>>() {}.type
            val existing =
                if (existingAsJsonString?.isNotEmpty() == true) gson.fromJson(
                    existingAsJsonString,
                    arrayBackgroundDownloadTaskType
                ) else mutableListOf<BackgroundDownloadTask>()
            existing.add(task)
            val newAsJsonString = gson.toJson(existing)
            val editor = prefs.edit()
            editor.putString(prefsKey, newAsJsonString)
            editor.apply()
            if (!success) {
                Log.w(
                    TAG,
                    "Failed background download for taskId ${task.taskId} from ${task.url} to ${task.filename}"
                )
            } else {
                Log.d(
                    TAG,
                    "Successful background download for taskId ${task.taskId} from ${task.url} to ${task.filename}"
                )
            }
        } finally {
            prefsLock.unlock()
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
        val path = Path(baseDir.path, task.savedDir)
        return Path(path.pathString, task.filename).pathString
    }

}


