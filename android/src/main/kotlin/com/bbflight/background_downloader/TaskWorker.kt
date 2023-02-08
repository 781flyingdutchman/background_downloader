@file:Suppress("EnumEntryName")

package com.bbflight.background_downloader

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.webkit.MimeTypeMap
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import com.google.gson.Gson
import com.google.gson.reflect.TypeToken
import kotlinx.coroutines.CancellationException
import java.io.*
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

/// Type of updates requested for a group of tasks
enum class Updates {
    none,  // no status or progress updates
    statusChange, // only calls upon change in DownloadTaskStatus
    progressUpdates, // only calls for progress
    statusChangeAndProgressUpdates // calls also for progress along the way
}

/// Partial version of the Dart side DownloadTask, only used for background loading
class Task(
    val taskId: String,
    val url: String,
    val filename: String,
    val headers: Map<String, String>,
    val post: String?,
    val directory: String,
    val baseDirectory: BaseDirectory,
    val group: String,
    val updates: Updates,
    val requiresWiFi: Boolean,
    val retries: Int,
    val retriesRemaining: Int,
    val metaData: String,
    val taskType: String // distinction between DownloadTask and UploadTask
) {

    /** Creates object from JsonMap */
    @Suppress("UNCHECKED_CAST")
    constructor(jsonMap: Map<String, Any>) : this(
        taskId = jsonMap["taskId"] as String,
        url = jsonMap["url"] as String,
        filename = jsonMap["filename"] as String,
        headers = jsonMap["headers"] as Map<String, String>,
        post = jsonMap["post"] as String?,
        directory = jsonMap["directory"] as String,
        baseDirectory = BaseDirectory.values()[(jsonMap["baseDirectory"] as Double).toInt()],
        group = jsonMap["group"] as String,
        updates =
        Updates.values()[(jsonMap["updates"] as Double).toInt()],
        requiresWiFi = jsonMap["requiresWiFi"] as Boolean,
        retries = (jsonMap["retries"] as Double).toInt(),
        retriesRemaining = (jsonMap["retriesRemaining"] as Double).toInt(),
        metaData = jsonMap["metaData"] as String,
        taskType = jsonMap["taskType"] as String
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
            "updates" to updates.ordinal,
            "requiresWiFi" to requiresWiFi,
            "retries" to retries,
            "retriesRemaining" to retriesRemaining,
            "metaData" to metaData,
            "taskType" to taskType
        )
    }

    /** True if this task expects to provide progress updates */
    fun providesProgressUpdates(): Boolean {
        return updates == Updates.progressUpdates ||
                updates == Updates.statusChangeAndProgressUpdates
    }

    /** True if this task expects to provide status updates */
    fun providesStatusUpdates(): Boolean {
        return updates == Updates.statusChange ||
                updates == Updates.statusChangeAndProgressUpdates
    }

    /** True if this task is a DownloadTask, otherwise it is an UploadTask */
    fun isDownloadTask(): Boolean {
        return taskType != "UploadTask"
    }

}

/** Defines a set of possible states which a [Task] can be in.
 *
 * Must match the Dart equivalent enum, as value are passed as ordinal/index integer
 */
enum class TaskStatus {
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
class TaskWorker(
    applicationContext: Context,
    workerParams: WorkerParameters
) :
    CoroutineWorker(applicationContext, workerParams) {

    companion object {
        const val TAG = "TaskWorker"
        const val keyTask = "Task"
        const val bufferSize = 8096

        /**
         * Processes a change in status for the task
         *
         * Sends status update via the background channel to Flutter, if requested, and if the task
         * is finished, processes a final status update and remove references to persistent storage
         * */
        fun processStatusUpdate(
            task: Task,
            status: TaskStatus
        ) {
            // Post update if task expects one, or if failed and retry is needed
            val retryNeeded =
                status == TaskStatus.failed && task.retriesRemaining > 0
            if (task.providesStatusUpdates() || retryNeeded) {
                Handler(Looper.getMainLooper()).post {
                    try {
                        val gson = Gson()
                        val arg = listOf<Any>(
                            gson.toJson(task.toJsonMap()),
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
                    TaskStatus.complete -> processProgressUpdate(
                        task,
                        1.0
                    )
                    TaskStatus.failed -> if (!retryNeeded) processProgressUpdate(
                        task,
                        -1.0
                    )
                    TaskStatus.canceled -> processProgressUpdate(
                        task,
                        -2.0
                    )
                    TaskStatus.notFound -> processProgressUpdate(
                        task,
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
                    val tasksMap =
                        BackgroundDownloaderPlugin.gson.fromJson<Map<String, Any>>(
                            jsonString,
                            BackgroundDownloaderPlugin.mapType
                        ).toMutableMap()
                    tasksMap.remove(task.taskId)
                    val editor = BackgroundDownloaderPlugin.prefs.edit()
                    editor.putString(
                        BackgroundDownloaderPlugin.keyTasksMap,
                        BackgroundDownloaderPlugin.gson.toJson(tasksMap)
                    )
                    editor.apply()
                }
            }
        }

        /**
         * Processes a progress update for the [task]
         *
         * Sends progress update via the background channel to Flutter, if requested
         */
        fun processProgressUpdate(
            task: Task,
            progress: Double
        ) {
            if (task.providesProgressUpdates()) {
                Handler(Looper.getMainLooper()).post {
                    try {
                        val gson = Gson()
                        val arg =
                            listOf<Any>(
                                gson.toJson(task.toJsonMap()),
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
        val taskJsonMapString = inputData.getString(keyTask)
        val mapType = object : TypeToken<Map<String, Any>>() {}.type
        val task = Task(
            gson.fromJson(taskJsonMapString, mapType)
        )
        Log.i(TAG, " Starting task with taskId ${task.taskId}")
        processStatusUpdate(task, TaskStatus.running)
        val status = doTask(task)
        processStatusUpdate(task, status)
        return Result.success()
    }

    /** do the task: download or upload a file */
    private fun doTask(
        task: Task
    ): TaskStatus {
        try {
            val urlString = task.url
            val url = URL(urlString)
            with(url.openConnection() as HttpURLConnection) {
                instanceFollowRedirects = true
                for (header in task.headers) {
                    setRequestProperty(header.key, header.value)
                }
                return connectAndProcess(this, task)
            }
        } catch (e: Exception) {
            Log.w(
                TAG,
                "Error downloading from ${task.url} to ${task.filename}: $e"
            )
        }
        return TaskStatus.failed
    }

    /** Make the request to the [connection] and process the [Task] */
    private fun connectAndProcess(
        connection: HttpURLConnection, task: Task
    ): TaskStatus {
        val filePath = pathToFileForTask(task)
        try {
            if (task.isDownloadTask()) {
                if (task.post != null) {
                    connection.requestMethod = "POST"
                    connection.doOutput = true
                    connection.setFixedLengthStreamingMode(task.post.length)
                    DataOutputStream(connection.outputStream).use { it.writeBytes(task.post) }
                } else {
                    connection.requestMethod = "GET"
                }
                return processDownload(connection, task, filePath)
            }
            return processUpload(connection, task, filePath)
        } catch (e: Exception) {
            when (e) {
                is FileSystemException -> Log.w(
                    TAG,
                    "Filesystem exception for url ${task.url} and $filePath: ${e.message}"
                )
                is SocketException -> Log.i(
                    TAG,
                    "Socket exception for url ${task.url} and $filePath: ${e.message}"
                )
                is CancellationException -> {
                    Log.i(
                        TAG,
                        "Job cancelled for url ${task.url} and $filePath: ${e.message}"
                    )
                    return TaskStatus.canceled
                }
                else -> Log.w(
                    TAG,
                    "Error for url ${task.url} and $filePath: ${e.message}"
                )
            }
        }
        return TaskStatus.failed
    }

    /** Process the upload of the file
     *
     * If Content-Type header is not set, will attempt to derive it from the file extension
     *
     * Returns the [TaskStatus]
     */
    private fun processUpload(
        connection: HttpURLConnection,
        task: Task,
        filePath: String
    ): TaskStatus {
        connection.requestMethod = "POST"
        connection.doOutput = true
        val file = File(filePath)
        if (!file.exists() || !file.isFile) {
            Log.w(TAG, "File $filePath does not exist or is not a file")
            return TaskStatus.failed
        }
        val contentLength = file.length()
        if (contentLength <= 0) {
            Log.w(TAG, "File $filePath has 0 length")
            return TaskStatus.failed
        }
        if (!connection.requestProperties.keys.contains("Content-Type")) {
            val mimeType =
                MimeTypeMap.getSingleton().getMimeTypeFromExtension(file.extension)
            if (mimeType != null) {
                connection.setRequestProperty("Content-Type", mimeType)
            }
        }
        connection.setRequestProperty("Content-Length", contentLength.toString())
        connection.setFixedLengthStreamingMode(contentLength)
        FileInputStream(file).use { inputStream ->
            DataOutputStream(connection.outputStream.buffered()).use { outputStream ->
                transferBytes(inputStream, outputStream, connection, task)
            }
        }
        if (isStopped) {
            Log.i(TAG, "Canceled taskId ${task.taskId} for $filePath")
            return TaskStatus.canceled
        }
        if (connection.responseCode in 200..206) {
            Log.i(
                TAG,
                "Successfully uploaded taskId ${task.taskId} to $filePath"
            )
            return TaskStatus.complete
        }
        Log.i(
            TAG,
            "Response code ${connection.responseCode} for upload of $filePath to ${task.url}"
        )
        return if (connection.responseCode == 404) {
            TaskStatus.notFound
        } else {
            TaskStatus.failed
        }
    }

    /** Process the response to the GET or POST request on this [connection]
     *
     * Returns the [TaskStatus]
     */
    private fun processDownload(
        connection: HttpURLConnection,
        task: Task,
        filePath: String
    ): TaskStatus {
        if (connection.responseCode in 200..206) {
            var dir = applicationContext.cacheDir
            val tempFile = File.createTempFile(
                "com.bbflight.background_downloader",
                Random.nextInt().toString(),
                dir
            )
            BufferedInputStream(connection.inputStream).use { inputStream ->
                FileOutputStream(tempFile).use { outputStream ->
                    transferBytes(inputStream, outputStream, connection, task)
                }
            }
            if (!isStopped) {
                // move file from its temp location to the destination
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
                Log.i(TAG, "Canceled taskId ${task.taskId} for $filePath")
                return TaskStatus.canceled
            }
            Log.i(
                TAG,
                "Successfully downloaded taskId ${task.taskId} to $filePath"
            )
            return TaskStatus.complete
        } else {
            Log.i(
                TAG,
                "Response code ${connection.responseCode} for download from  ${task.url} to $filePath"
            )
            return if (connection.responseCode == 404) {
                TaskStatus.notFound
            } else {
                TaskStatus.failed
            }
        }
    }

    /**
     * Transfer bytes from [inputStream] to [outputStream] via the [connection] and provide
     * progress updates for the [task]
     *
     * Will return if during the transfer [isStopped] becomes true
     */
    private fun transferBytes(
        inputStream: InputStream,
        outputStream: OutputStream,
        connection: HttpURLConnection,
        task: Task
    ) {
        val dataBuffer = ByteArray(bufferSize)
        var bytesTotal: Long = 0
        var lastProgressUpdate = 0.0
        var nextProgressUpdateTime = 0L
        var numBytes: Int
        while (inputStream.read(dataBuffer, 0, bufferSize)
                .also { numBytes = it } != -1
        ) {
            if (isStopped) {
                break
            }
            outputStream.write(dataBuffer, 0, numBytes)
            bytesTotal += numBytes
            val progress =
                min(
                    bytesTotal.toDouble() / connection.contentLengthLong,
                    0.999
                )
            if (connection.contentLengthLong > 0 &&
                (bytesTotal < 10000 || (progress - lastProgressUpdate > 0.02 && currentTimeMillis() > nextProgressUpdateTime))
            ) {
                processProgressUpdate(task, progress)
                lastProgressUpdate = progress
                nextProgressUpdateTime = currentTimeMillis() + 500
            }
        }
    }


    /** Returns full path (String) to the file to be downloaded */
    private fun pathToFileForTask(task: Task): String {
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


