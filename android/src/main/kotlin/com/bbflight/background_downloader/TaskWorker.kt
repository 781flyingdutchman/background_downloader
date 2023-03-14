@file:Suppress("EnumEntryName")

package com.bbflight.background_downloader

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.Context.*
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.webkit.MimeTypeMap
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.preference.PreferenceManager
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import com.google.gson.Gson
import com.google.gson.reflect.TypeToken
import kotlinx.coroutines.*
import java.io.*
import java.lang.Double.min
import java.lang.System.currentTimeMillis
import java.net.HttpURLConnection
import java.net.SocketException
import java.net.URL
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.*
import kotlin.concurrent.schedule
import kotlin.concurrent.write
import kotlin.io.path.Path
import kotlin.io.path.pathString
import kotlin.math.roundToInt
import kotlin.random.Random


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
        const val taskTimeoutMillis = 9 * 60 * 1000L  // 9 minutes

        private val fileNameRegEx = Regex("""\{filename\}""", RegexOption.IGNORE_CASE)
        private val progressBarRegEx = Regex("""\{progressBar\}""", RegexOption.IGNORE_CASE)

        private var taskCanResume = false
        private var createdNotificationChannel = false


        /** Converts [Task] to JSON string representation */
        private fun taskToJsonString(task: Task): String {
            val gson = Gson()
            return gson.toJson(task.toJsonMap())
        }

        /**
         * Post method message on backgroundChannel with arguments and return true if this was
         * successful
         */
        private suspend fun postOnBackgroundChannel(
                method: String,
                task: Task,
                arg: Any,
                arg2: Any? = null
        ): Boolean {
            val runningOnUIThread = Looper.myLooper() == Looper.getMainLooper()
            return coroutineScope {
                val success = CompletableDeferred<Boolean>()
                Handler(Looper.getMainLooper()).post {
                    try {
                        val argList =
                                mutableListOf(
                                        taskToJsonString(task),
                                        arg
                                )
                        if (arg2 != null) {
                            argList.add(arg2)
                        }
                        if (BackgroundDownloaderPlugin.backgroundChannel != null) {
                            BackgroundDownloaderPlugin.backgroundChannel?.invokeMethod(
                                    method,
                                    argList
                            )
                            if (!BackgroundDownloaderPlugin.forceFailPostOnBackgroundChannel) {
                                success.complete(true)
                            }
                        } else {
                            Log.i(TAG, "Could not post $method to background channel")
                        }
                    } catch (e: Exception) {
                        Log.w(
                                TAG,
                                "Exception trying to post $method to background channel: ${e.message}"
                        )
                    } finally {
                        if (!success.isCompleted) {
                            success.complete(false)
                        }
                    }
                }
                // don't wait for result of post if running on UI thread -> true
                return@coroutineScope if (runningOnUIThread) true else success.await()
            }
        }

        /**
         * Processes a change in status for the task
         *
         * Sends status update via the background channel to Flutter, if requested
         * If the task is finished, processes a final progressUpdate update and removes
         * task from persistent storage
         * */
        suspend fun processStatusUpdate(
                task: Task,
                status: TaskStatus,
                prefs: SharedPreferences

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
                            1.0, prefs
                    )
                    TaskStatus.failed ->
                        if (!retryNeeded) processProgressUpdate(
                                task,
                                -1.0, prefs
                        )
                    TaskStatus.canceled -> {
                        canSendStatusUpdate = canSendCancellation(task)
                        if (canSendStatusUpdate) {
                            BackgroundDownloaderPlugin.canceledTaskIds[task.taskId] =
                                    currentTimeMillis()
                            processProgressUpdate(
                                    task,
                                    -2.0, prefs
                            )
                        }
                    }
                    TaskStatus.notFound -> processProgressUpdate(
                            task,
                            -3.0, prefs
                    )
                    else -> {}
                }
            }
            // Post update if task expects one, or if failed and retry is needed
            if (canSendStatusUpdate && (task.providesStatusUpdates() || retryNeeded)) {
                if (!postOnBackgroundChannel("statusUpdate", task, status.ordinal)) {
                    // unsuccessful post, so store in local prefs
                    Log.d(TAG, "Could not post status update -> storing locally")
                    val jsonMap = task.toJsonMap().toMutableMap()
                    jsonMap["taskStatus"] = status.ordinal // merge into Task JSON
                    storeLocally(
                            BackgroundDownloaderPlugin.keyStatusUpdateMap,
                            task.taskId,
                            jsonMap,
                            prefs
                    )
                }
            }
            // if task is in final state, remove from persistent storage
            if (status.isFinalState()) {
                BackgroundDownloaderPlugin.prefsLock.write {
                    val tasksMap =
                            getTaskMap(prefs)
                    tasksMap.remove(task.taskId)
                    val editor = prefs.edit()
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
        suspend fun processProgressUpdate(
                task: Task,
                progress: Double,
                prefs: SharedPreferences
        ) {
            if (task.providesProgressUpdates()) {
                if (!postOnBackgroundChannel("progressUpdate", task, progress)) {
                    // unsuccessful post, so store in local prefs
                    Log.d(TAG, "Could not post progress update -> storing locally")
                    val jsonMap = task.toJsonMap().toMutableMap()
                    jsonMap["progress"] = progress // merge into Task JSON
                    storeLocally(
                            BackgroundDownloaderPlugin.keyProgressUpdateMap,
                            task.taskId,
                            jsonMap,
                            prefs
                    )
                }
            }
        }

        /** Send 'canResume' message via the background channel to Flutter */
        suspend fun processCanResume(task: Task, canResume: Boolean) {
            taskCanResume = canResume
            postOnBackgroundChannel("canResume", task, canResume)
        }

        /**
         * Process resume information
         *
         * Attempts to post this to the Dart side via background channel. If that is not
         * successful, stores the resume data in shared preferences, for later retrieval by
         * the Dart side
         */
        suspend fun processResumeData(resumeData: ResumeData, prefs: SharedPreferences) {
            if (!postOnBackgroundChannel(
                            "resumeData",
                            resumeData.task,
                            resumeData.data,
                            resumeData.requiredStartByte
                    )
            ) {
                // unsuccessful post, so store in local prefs
                Log.d(TAG, "Could not post resume data -> storing locally")
                storeLocally(
                        BackgroundDownloaderPlugin.keyResumeDataMap,
                        resumeData.task.taskId,
                        resumeData.toJsonMap(),
                        prefs
                )
            }
        }

        /**
         * Store the [item] in preferences under [prefsKey], keyed by [taskId]
         */
        private fun storeLocally(
                prefsKey: String,
                taskId: String,
                item: MutableMap<String, Any?>,
                prefs: SharedPreferences
        ) {
            BackgroundDownloaderPlugin.prefsLock.write {
                // add the data to a map keyed by taskId
                val jsonString =
                        prefs.getString(prefsKey, "{}")
                val mapByTaskId = BackgroundDownloaderPlugin.gson.fromJson<Map<String, Any>>(
                        jsonString,
                        BackgroundDownloaderPlugin.jsonMapType
                ).toMutableMap()
                mapByTaskId[taskId] = item
                val editor = prefs.edit()
                editor.putString(
                        prefsKey,
                        BackgroundDownloaderPlugin.gson.toJson(mapByTaskId)
                )
                editor.apply()
            }
        }
    }

    // properties related to pause/resume functionality
    private var bytesTotal: Long = 0
    private var startByte = 0L
    private var isTimedOut = false

    // properties related to notifications
    private var notificationConfigJsonString: String? = null
    private var notificationConfig: NotificationConfig? = null
    private var notificationId = 0

    private lateinit var prefs: SharedPreferences

    override suspend fun doWork(): Result {
        prefs = PreferenceManager.getDefaultSharedPreferences(applicationContext)
        withContext(Dispatchers.IO) {
            Timer().schedule(taskTimeoutMillis) {
                isTimedOut = true
            }
            val gson = Gson()
            val taskJsonMapString = inputData.getString(keyTask)
            val mapType = object : TypeToken<Map<String, Any>>() {}.type
            val task = Task(
                    gson.fromJson(taskJsonMapString, mapType)
            )
            notificationConfigJsonString =
                    inputData.getString(BackgroundDownloaderPlugin.keyNotificationConfig)
            notificationConfig = if (notificationConfigJsonString != null)
                BackgroundDownloaderPlugin.gson.fromJson(notificationConfigJsonString,
                        NotificationConfig::class.java) else
                null
            Log.d(TAG, "NotificationConfig = $notificationConfig")
            // pre-process resume
            val requiredStartByte = inputData.getLong(BackgroundDownloaderPlugin.keyStartByte, 0)
            var isResume = requiredStartByte != 0L
            val tempFilePath =
                    if (isResume) inputData.getString(BackgroundDownloaderPlugin.keyTempFilename)
                            ?: ""
                    else "${applicationContext.cacheDir}/com.bbflight.background_downloader${Random.nextInt()}"
            isResume = isResume && determineIfResumeIsPossible(tempFilePath, requiredStartByte)
            Log.i(
                    TAG,
                    "${if (isResume) "Resuming" else "Starting"} task with taskId ${task.taskId}"
            )
            processStatusUpdate(task, TaskStatus.running, prefs)
            if (!isResume) {
                processProgressUpdate(task, 0.0, prefs)
            }
            val status = doTask(task, isResume, tempFilePath, requiredStartByte)
            processStatusUpdate(task, status, prefs)
            updateNotification(task, status);
        }
        return Result.success()
    }

    /** Return true if resume is possible, given [tempFilePath] and [requiredStartByte] */
    private fun determineIfResumeIsPossible(
            tempFilePath: String,
            requiredStartByte: Long
    ): Boolean {
        if (File(tempFilePath).exists()) {
            if (File(tempFilePath).length() == requiredStartByte) {
                return true
            } else {
                Log.i(TAG, "Partially downloaded file is corrupted, resume not possible")
            }
        } else {
            Log.i(TAG, "Partially downloaded file not available, resume not possible")
        }
        return false
    }

    /** do the task: download or upload a file */
    private suspend fun doTask(
            task: Task, isResume: Boolean, tempFilePath: String, requiredStartByte: Long
    ): TaskStatus {
        try {
            val urlString = task.url
            val url = URL(urlString)
            with(withContext(Dispatchers.IO) {
                url.openConnection()
            } as HttpURLConnection) {
                instanceFollowRedirects = true
                for (header in task.headers) {
                    setRequestProperty(header.key, header.value)
                }
                if (isResume) {
                    setRequestProperty("Range", "bytes=$requiredStartByte-")
                }
                return connectAndProcess(this, task, isResume, tempFilePath)
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
    private suspend fun connectAndProcess(
            connection: HttpURLConnection,
            task: Task,
            isResume: Boolean,
            tempFilePath: String
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
                return processDownload(
                        connection,
                        task,
                        filePath,
                        isResume,
                        tempFilePath
                )
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
                    deleteTempFile(tempFilePath)
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
        deleteTempFile(tempFilePath)
        return TaskStatus.failed
    }

    /** Process the response to the GET or POST request on this [connection]
     *
     * Returns the [TaskStatus]
     */
    private suspend fun processDownload(
            connection: HttpURLConnection,
            task: Task,
            filePath: String, isResumeParam: Boolean, tempFilePath: String
    ): TaskStatus {
        Log.d(TAG, "Download for taskId ${task.taskId}")
        if (connection.responseCode in 200..206) {
            if (task.allowPause) {
                val acceptRangesHeader = connection.headerFields["Accept-Ranges"]
                processCanResume(task, acceptRangesHeader?.first() == "bytes")
            }
            val isResume =
                    isResumeParam && connection.responseCode == 206  // confirm resume response
            if (isResume && !prepareResume(connection, tempFilePath)) {
                deleteTempFile(tempFilePath)
                return TaskStatus.failed
            }
            val tempFile = File(tempFilePath)
            val transferBytesResult: TaskStatus
            BufferedInputStream(connection.inputStream).use { inputStream ->
                FileOutputStream(tempFile, isResume).use { outputStream ->
                    transferBytesResult =
                            transferBytes(inputStream, outputStream, connection.contentLengthLong,
                                    task)
                }
            }
            when (transferBytesResult) {
                TaskStatus.complete -> {
                    // move file from its temp location to the destination
                    val destFile = File(filePath)
                    val dir = destFile.parentFile!!
                    if (!dir.exists()) {
                        dir.mkdirs()
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        withContext(Dispatchers.IO) {
                            Files.move(
                                    tempFile.toPath(),
                                    destFile.toPath(),
                                    StandardCopyOption.REPLACE_EXISTING
                            )
                        }
                    } else {
                        tempFile.copyTo(destFile, overwrite = true)
                        deleteTempFile(tempFilePath)
                    }
                    Log.i(
                            TAG,
                            "Successfully downloaded taskId ${task.taskId} to $filePath"
                    )
                    return TaskStatus.complete
                }

                TaskStatus.canceled -> {
                    deleteTempFile(tempFilePath)
                    Log.i(TAG, "Canceled taskId ${task.taskId} for $filePath")
                    return TaskStatus.canceled
                }

                TaskStatus.paused -> {
                    BackgroundDownloaderPlugin.pausedTaskIds.remove(task.taskId)
                    if (taskCanResume) {
                        Log.i(TAG, "Task ${task.taskId} paused")
                        processResumeData(
                                ResumeData(
                                        task,
                                        tempFilePath,
                                        bytesTotal + startByte
                                ), prefs
                        )
                        return TaskStatus.paused
                    }
                    Log.i(TAG, "Task ${task.taskId} cannot resume, therefore pause failed")
                    deleteTempFile(tempFilePath)
                    return TaskStatus.failed
                }

                TaskStatus.enqueued -> {
                    // Special status, in this context means that the task timed out
                    // so if allowed, pause it and schedule the resume task immediately
                    if (!task.allowPause) {
                        Log.i(TAG, "Task ${task.taskId} timed out")
                        return TaskStatus.failed
                    }
                    if (taskCanResume) {
                        Log.i(
                                TAG,
                                "Task ${task.taskId} paused due to timeout, will resume in 1 second"
                        )
                        val start = bytesTotal + startByte
                        BackgroundDownloaderPlugin.doEnqueue(
                                applicationContext,
                                taskToJsonString(task),
                                notificationConfigJsonString,
                                tempFilePath,
                                start,
                                1000
                        )
                        return TaskStatus.paused
                    }
                    Log.i(TAG, "Task ${task.taskId} cannot resume, therefore pause failed")
                    deleteTempFile(tempFilePath)
                    return TaskStatus.failed
                }
                else -> {
                    deleteTempFile(tempFilePath)
                    return TaskStatus.failed
                }
            }
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
    private suspend fun processUpload(
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
        var transferBytesResult: TaskStatus
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
            withContext(Dispatchers.IO) {
                FileInputStream(file).use { inputStream ->
                    DataOutputStream(connection.outputStream.buffered()).use { outputStream ->
                        transferBytesResult =
                                transferBytes(inputStream, outputStream, fileSize, task)
                    }
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
            withContext(Dispatchers.IO) {
                FileInputStream(file).use { inputStream ->
                    DataOutputStream(connection.outputStream).use { outputStream ->
                        val writer = outputStream.writer()
                        writer.append("--${boundary}").append(lineFeed)
                                .append(contentDispositionString).append(lineFeed)
                                .append(contentTypeString).append(lineFeed).append(lineFeed)
                                .flush()
                        transferBytesResult =
                                transferBytes(inputStream, outputStream, fileSize, task)
                        if (transferBytesResult == TaskStatus.complete) {
                            writer.append(lineFeed).append("--${boundary}--").append(lineFeed)
                        }
                        writer.close()
                    }
                }
            }
        }
        when (transferBytesResult) {
            TaskStatus.canceled -> {
                Log.i(TAG, "Canceled taskId ${task.taskId} for $filePath")
                return TaskStatus.canceled
            }

            TaskStatus.failed -> {
                return TaskStatus.failed
            }

            TaskStatus.complete -> {
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

            else -> {
                return TaskStatus.failed
            }
        }
    }


    /**
     * Transfer [contentLength] bytes from [inputStream] to [outputStream] and provide
     * progress updates for the [task]
     *
     * Will return [TaskStatus.canceled], [TaskStatus.paused], [TaskStatus.failed],
     * [TaskStatus.complete], or special [TaskStatus.enqueued] which signals the task timed out
     */
    private suspend fun transferBytes(
            inputStream: InputStream,
            outputStream: OutputStream,
            contentLength: Long,
            task: Task
    ): TaskStatus {
        val dataBuffer = ByteArray(bufferSize)
        var lastProgressUpdate = 0.0
        var nextProgressUpdateTime = 0L
        var numBytes: Int
        return withContext(Dispatchers.IO) {
            try {
                while (inputStream.read(dataBuffer, 0, bufferSize)
                                .also { numBytes = it } != -1
                ) {
                    // check if task is stopped (canceled), paused or timed out
                    if (isStopped) {
                        return@withContext TaskStatus.canceled
                    }
                    // 'pause' is signalled by adding the taskId to a static list
                    if (BackgroundDownloaderPlugin.pausedTaskIds.contains(task.taskId)) {
                        return@withContext TaskStatus.paused
                    }
                    if (isTimedOut) {
                        return@withContext TaskStatus.enqueued // special use of this status, see [processDownload]
                    }
                    if (numBytes > 0) {
                        outputStream.write(dataBuffer, 0, numBytes)
                        bytesTotal += numBytes
                    }
                    val progress =
                            min(
                                    (bytesTotal + startByte).toDouble() / (contentLength + startByte),
                                    0.999
                            )
                    if (contentLength > 0 &&
                            progress - lastProgressUpdate > 0.02 && currentTimeMillis() > nextProgressUpdateTime
                    ) {
                        processProgressUpdate(task, progress, prefs)
                        updateNotification(task, TaskStatus.running, progress)
                        lastProgressUpdate = progress
                        nextProgressUpdateTime = currentTimeMillis() + 500
                    }
                }
            } catch (e: Exception) {
                Log.i(TAG, "Exception for ${task.taskId}: $e")
                return@withContext TaskStatus.failed
            }
            return@withContext TaskStatus.complete
        }
    }

    /** Prepare for resume if possible
     *
     * Returns true if task can continue, false if task failed.
     * Extracts and parses Range headers, and truncates temp file
     */
    private fun prepareResume(connection: HttpURLConnection, tempFilePath: String): Boolean {
        val contentRanges = connection.headerFields["Content-Range"]
        if (contentRanges == null || contentRanges.size > 1) {
            Log.i(TAG, "Could not process partial response Content-Range")
            return false
        }
        val range = contentRanges.first()
        val contentRangeRegEx = Regex("(\\d+)-(\\d+)/(\\d+)")
        val matchResult = contentRangeRegEx.find(range)
        if (matchResult == null) {
            Log.i(TAG, "Could not process partial response Content-Range $range")
            return false
        }
        val start = matchResult.groups[1]?.value?.toLong()!!
        val end = matchResult.groups[2]?.value?.toLong()!!
        val total = matchResult.groups[3]?.value?.toLong()!!
        val tempFile = File(tempFilePath)
        val tempFileLength = tempFile.length()
        Log.d(
                TAG,
                "Resume start=$start, end=$end of total=$total bytes, tempFile = $tempFileLength bytes"
        )
        if (total != end + 1 || start > tempFileLength) {
            Log.i(TAG, "Offered range not feasible: $range")
            return false
        }
        startByte = start
        // resume possible, set start conditions
        try {
            RandomAccessFile(tempFilePath, "rw").use { it.setLength(start) }
        } catch (e: IOException) {
            Log.i(TAG, "Could not truncate temp file")
            return false
        }
        return true
    }

    /**
     * Create the notification channel to use for download notifications
     */
    private fun createNotificationChannel() {
        // Create the NotificationChannel, but only on API 26+ because
        // the NotificationChannel class is new and not in the support library
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val name = "Downloads"
            val descriptionText = "Download notifications"
            val importance = NotificationManager.IMPORTANCE_LOW
            val channel =
                    NotificationChannel(BackgroundDownloaderPlugin.notificationChannel, name,
                            importance).apply {
                        description = descriptionText
                    }
            // Register the channel with the system
            val notificationManager: NotificationManager =
                    applicationContext.getSystemService(
                            NOTIFICATION_SERVICE) as NotificationManager
            notificationManager.createNotificationChannel(channel)
        }
        createdNotificationChannel = true
    }

    /**
     * Create or update the notification for this [task], associated with this [status]
     * and [progress]
     *
     * The [status] field is interpreted differently:
     * - [TaskStatus.running] triggers the activeNotification
     * - [TaskStatus.complete] triggers the completeNotification
     * - [TaskStatus.canceled] triggers removal of the notification
     * - Any other status triggers the errorNotification
     * If the [status] is [TaskStatus.complete] and no notification is given, will cancel the notification
     * The [progress] field is only relevant for [TaskStatus.running]
     */
    private fun updateNotification(task: Task, status: TaskStatus, progress: Double = 1.0) {
        val notification = when (status) {
            TaskStatus.running -> notificationConfig?.activeNotification
            TaskStatus.complete -> notificationConfig?.completeNotification
            else -> notificationConfig?.errorNotification
        }
        if ((status == TaskStatus.complete && notification == null) || status == TaskStatus.canceled) {
            // remove notification and return
            if (notificationId != 0) {
                with(NotificationManagerCompat.from(applicationContext)) {
                    cancel(notificationId)
                }
            }
            return
        }
        if (notification == null) { return } // no notification
        // need to show a notification
        if (!createdNotificationChannel) {
            createNotificationChannel()
        }
        if (notificationId == 0) {
            notificationId = Random.nextInt()
        }
        val builder = NotificationCompat.Builder(applicationContext, BackgroundDownloaderPlugin
                .notificationChannel)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .setSmallIcon(R.drawable.baseline_downloading_24)
        if (notification.title.isNotEmpty()) {
            builder.setContentTitle(notification.title)
        }
        var body = fileNameRegEx.replace(notification.body, task.filename)
        val progressString = if (progress >= 0) (progress * 100).roundToInt().toString() + "%"
        else "..."
        body = body.replace("{progress}", progressString)
        val progressBar = progressBarRegEx.containsMatchIn(body)
        if (progressBar) {
            body = progressBarRegEx.replace(body, "")
        }
        if (body.isNotEmpty()) {
            builder.setContentText(body)
        }
        // TODO set contentIntent to deal with tap
        // TODO set cancel button and action
        // TODO something with progressBar
        with(NotificationManagerCompat.from(applicationContext)) {
            if (!BackgroundDownloaderPlugin.haveNotificationPermission && Build.VERSION.SDK_INT
                    >= Build.VERSION_CODES
                            .TIRAMISU) {
                // On Android 33+, ask for permission
                if (ActivityCompat.checkSelfPermission(applicationContext,
                                Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                    BackgroundDownloaderPlugin.activity?.requestPermissions(
                            arrayOf(Manifest.permission
                                    .POST_NOTIFICATIONS),
                            BackgroundDownloaderPlugin.notificationPermissionRequestCode)
                    return
                }
            }
            notify(notificationId, builder.build())
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

    private fun deleteTempFile(tempFilePath: String) {
        if (tempFilePath.isNotEmpty()) {
            try {
                val tempFile = File(tempFilePath)
                tempFile.delete()
            } catch (e: IOException) {
                Log.w(TAG, "Could not delete temp file at $tempFilePath")
            }
        }
    }
}

/** Return the map of tasks stored in preferences */
fun getTaskMap(prefs: SharedPreferences): MutableMap<String, Any> {
    val jsonString =
            prefs.getString(
                    BackgroundDownloaderPlugin.keyTasksMap,
                    "{}"
            )
    return BackgroundDownloaderPlugin.gson.fromJson<Map<String, Any>>(
            jsonString,
            BackgroundDownloaderPlugin.jsonMapType
    ).toMutableMap()
}


