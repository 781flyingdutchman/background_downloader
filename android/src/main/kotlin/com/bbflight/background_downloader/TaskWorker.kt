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
    val creationTime: Long, // untouched, so kept as integer on Android side
    val taskType: String // distinction between DownloadTask and UploadTask
) {

    /** Creates object from JsonMap */
    @Suppress("UNCHECKED_CAST")
    constructor(jsonMap: Map<String, Any>) : this(
        taskId = jsonMap["taskId"] as String? ?: "",
        url = jsonMap["url"] as String? ?: "",
        filename = jsonMap["filename"] as String? ?: "",
        headers = jsonMap["headers"] as Map<String, String>? ?: mutableMapOf<String, String>(),
        post = jsonMap["post"] as String?,
        directory = jsonMap["directory"] as String? ?: "",
        baseDirectory = BaseDirectory.values()[(jsonMap["baseDirectory"] as Double? ?: 0).toInt()],
        group = jsonMap["group"] as String? ?: "",
        updates = Updates.values()[(jsonMap["updates"] as Double? ?: 0).toInt()],
        requiresWiFi = jsonMap["requiresWiFi"] as Boolean? ?: false,
        retries = (jsonMap["retries"] as Double? ?: 0).toInt(),
        retriesRemaining = (jsonMap["retriesRemaining"] as Double? ?: 0).toInt(),
        metaData = jsonMap["metaData"] as String? ?: "",
        creationTime = (jsonMap["creationTime"] as Double? ?: 0).toLong(),
        taskType = jsonMap["taskType"] as String? ?: ""
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
            "creationTime" to creationTime,
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
         * Sends status update via the background channel to Flutter, if requested
         * If the task is finished, processes a final progressUpdate update and removes
         * task from persistent storage
         * */
        fun processStatusUpdate(
            task: Task,
            status: TaskStatus
        ) {
            val retryNeeded =
                status == TaskStatus.failed && task.retriesRemaining > 0
            // if task is in final state, process a final progressUpdate
            // A 'failed' progress update is only provided if
            // a retry is not needed: if it is needed, a `waitingToRetry` progress update
            // will be generated on the Dart side
            var canSendStatusUpdate = true  // may become false for cancellations
            if (status.isFinalState()) {
                when (status) {
                    TaskStatus.complete -> processProgressUpdate(
                        task,
                        1.0
                    )
                    TaskStatus.failed ->
                        if (!retryNeeded) processProgressUpdate(
                            task,
                            -1.0
                        )
                    TaskStatus.canceled -> {
                        canSendStatusUpdate = canSendCancellation(task)
                        if (canSendStatusUpdate) {
                            BackgroundDownloaderPlugin.canceledTaskIds[task.taskId] =
                                currentTimeMillis()
                            processProgressUpdate(
                                task,
                                -2.0
                            )
                        }
                    }
                    TaskStatus.notFound -> processProgressUpdate(
                        task,
                        -3.0
                    )
                    else -> {}
                }
            }
            // Post update if task expects one, or if failed and retry is needed
            if (canSendStatusUpdate && (task.providesStatusUpdates() || retryNeeded)) {
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
            // if task is in final state, remove from persistent storage
            if (status.isFinalState()) {
                BackgroundDownloaderPlugin.prefsLock.write {
                    val tasksMap =
                        getTaskMap()
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

        /** Return true if we can send a cancellation for this task
         *
         * Cancellation can only be sent if it wasn't already sent by the [BackgroundDownloaderPlugin]
         *  in the cancelTasksWithId method.  Side effect is to clean out older cancellation entries
         * from the [BackgroundDownloaderPlugin.canceledTaskIds]
         */
        private fun canSendCancellation(task: Task): Boolean {
            val idsToRemove = ArrayList<String>()
            val now = currentTimeMillis()
            for (entry in BackgroundDownloaderPlugin.canceledTaskIds) {
                if (now - entry.value > 1000) {
                    idsToRemove.add(entry.key)
                }
            }
            for (taskId in idsToRemove) {
                BackgroundDownloaderPlugin.canceledTaskIds.remove(taskId)
            }
            return BackgroundDownloaderPlugin.canceledTaskIds[task.taskId] == null
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
        Log.i(TAG, "Starting task with taskId ${task.taskId}")
        processStatusUpdate(task, TaskStatus.running)
        processProgressUpdate(task, 0.0)
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
                else -> {
                    Log.w(
                        TAG,
                        "Error for url ${task.url} and $filePath: ${e.message} $e ${e.localizedMessage}"
                    )
                    e.printStackTrace()
                }
            }
        }
        return TaskStatus.failed
    }

    /** Process the upload of the file
     *
     * If the [Task.post] field is set to "binary" then the file will be uploaded as a byte stream POST
     * and if the Content-Type header is not set, will attempt to derive it from the file extension.
     * Content-Disposition will be set to "attachment" with filename [Task.filename].
     *
     * If the [Task.post] field is not "binary" then the file will be uploaded as a multipart POST
     * with the name and filename set to [Task.filename] and the content type derived from the
     * file extension
     * Note that the actual Content-Type of the request will be multipart/form-data.
     *
     * Note that the [Task.post] field is just used to set whether this is a binary or multipart
     * upload. The bytes that will be posted are derived from the file to be uploaded.
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
        val fileSize = file.length()
        if (fileSize <= 0) {
            Log.w(TAG, "File $filePath has 0 length")
            return TaskStatus.failed
        }
        if (task.post?.lowercase() == "binary") {
            // binary file upload posts file bytes directly
            // set Content-Type based on file extension
            Log.d(TAG, "Binary upload for taskId ${task.taskId}")
            val mimeType =
                MimeTypeMap.getSingleton().getMimeTypeFromExtension(file.extension)
            if (mimeType != null) {
                connection.setRequestProperty("Content-Type", mimeType)
            }
            connection.setRequestProperty(
                "Content-Disposition",
                "attachment; filename=\"" + task.filename + "\""
            )
            connection.setRequestProperty("Content-Length", fileSize.toString())
            connection.setFixedLengthStreamingMode(fileSize)
            FileInputStream(file).use { inputStream ->
                DataOutputStream(connection.outputStream.buffered()).use { outputStream ->
                    transferBytes(inputStream, outputStream, fileSize, task)
                }
            }
        } else {
            // multipart file upload using Content-Type multipart/form-data
            Log.d(TAG, "Multipart upload for taskId ${task.taskId}")
            val boundary = "-----background_downloader-akjhfw281onqciyhnIk"
            // determine Content-Type based on file extension
            val mimeType =
                MimeTypeMap.getSingleton().getMimeTypeFromExtension(file.extension)
                    ?: "application/octet-stream"
            val lineFeed = "\r\n"
            val contentDispositionString =
                "Content-Disposition: form-data; name=\"file\"; filename=\"${task.filename}\""
            val contentTypeString = "Content-Type: $mimeType"
            // determine the content length of the multi-part data
            val contentLength =
                2 * boundary.length + 6 * lineFeed.length + contentDispositionString.length +
                        contentTypeString.length + 3 * "--".length + fileSize
            connection.setRequestProperty("Accept-Charset", "UTF-8")
            connection.setRequestProperty("Connection", "Keep-Alive")
            connection.setRequestProperty("Cache-Control", "no-cache")
            connection.setRequestProperty(
                "Content-Type",
                "multipart/form-data; boundary=$boundary"
            )
            connection.setRequestProperty("Content-Length", contentLength.toString())
            connection.setFixedLengthStreamingMode(contentLength)
            connection.useCaches = false
            FileInputStream(file).use { inputStream ->
                DataOutputStream(connection.outputStream).use { outputStream ->
                    val writer = outputStream.writer()
                    writer.append("--${boundary}").append(lineFeed)
                        .append(contentDispositionString).append(lineFeed)
                        .append(contentTypeString).append(lineFeed).append(lineFeed)
                        .flush()
                    transferBytes(inputStream, outputStream, fileSize, task)
                    if (!isStopped) {
                        writer.append(lineFeed).append("--${boundary}--").append(lineFeed)
                    }
                    writer.close()
                }
            }
        }
        if (isStopped) {
            Log.i(TAG, "Canceled taskId ${task.taskId} for $filePath")
            return TaskStatus.canceled
        }
        if (connection.responseCode in 200..206) {
            Log.i(
                TAG,
                "Successfully uploaded taskId ${task.taskId} from $filePath"
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
        Log.d(TAG, "Download for taskId ${task.taskId}")
        if (connection.responseCode in 200..206) {
            var dir = applicationContext.cacheDir
            val tempFile = File.createTempFile(
                "com.bbflight.background_downloader",
                Random.nextInt().toString(),
                dir
            )
            BufferedInputStream(connection.inputStream).use { inputStream ->
                FileOutputStream(tempFile).use { outputStream ->
                    transferBytes(inputStream, outputStream, connection.contentLengthLong, task)
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
     * Transfer [contentLength] bytes from [inputStream] to [outputStream] and provide
     * progress updates for the [task]
     *
     * Will return if during the transfer [isStopped] becomes true
     */
    private fun transferBytes(
        inputStream: InputStream,
        outputStream: OutputStream,
        contentLength: Long,
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
                    bytesTotal.toDouble() / contentLength,
                    0.999
                )
            if (contentLength > 0 &&
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

/** Return the map of tasks stored in preferences */
fun getTaskMap(): MutableMap<String, Any> {
    val jsonString =
        BackgroundDownloaderPlugin.prefs.getString(
            BackgroundDownloaderPlugin.keyTasksMap,
            "{}"
        )
    return BackgroundDownloaderPlugin.gson.fromJson<Map<String, Any>>(
        jsonString,
        BackgroundDownloaderPlugin.jsonMapType
    ).toMutableMap()
}


