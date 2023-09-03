@file:Suppress("EnumEntryName")

package com.bbflight.background_downloader

import android.Manifest
import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Context.NOTIFICATION_SERVICE
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.storage.StorageManager
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.preference.PreferenceManager
import androidx.work.CoroutineWorker
import androidx.work.ForegroundInfo
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.google.gson.Gson
import kotlinx.coroutines.*
import java.io.*
import java.lang.Long.max
import java.lang.System.currentTimeMillis
import java.net.HttpURLConnection
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.SocketException
import java.net.URL
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.util.*
import kotlin.concurrent.schedule
import kotlin.concurrent.write
import kotlin.math.roundToInt
import kotlin.random.Random
import java.lang.Double.min as doubleMin


/***
 * The worker to execute one task
 *
 * Processes DownloadTask, UploadTask or MultiUploadTask
 */
class TaskWorker(
    applicationContext: Context, workerParams: WorkerParameters
) : CoroutineWorker(applicationContext, workerParams) {

    @Suppress("RegExpRedundantEscape")
    companion object {
        const val TAG = "TaskWorker"
        const val keyTask = "Task"
        const val keyNotificationConfig = "notificationConfig"
        const val keyTempFilename = "tempFilename"
        const val keyStartByte = "startByte"
        const val keyEtag = "eTag"
        const val bufferSize = 8096
        const val taskTimeoutMillis = 9 * 60 * 1000L  // 9 minutes

        private val fileNameRegEx = Regex("""\{filename\}""", RegexOption.IGNORE_CASE)
        private val progressRegEx = Regex("""\{progress\}""", RegexOption.IGNORE_CASE)
        private val networkSpeedRegEx = Regex("""\{networkSpeed\}""", RegexOption.IGNORE_CASE)
        private val timeRemainingRegEx = Regex("""\{timeRemaining\}""", RegexOption.IGNORE_CASE)
        private val metaDataRegEx = Regex("""\{metadata\}""", RegexOption.IGNORE_CASE)
        private val asciiOnlyRegEx = Regex("^[\\x00-\\x7F]+$")
        private val newlineRegEx = Regex("\r\n|\r|\n")

        const val boundary = "-----background_downloader-akjhfw281onqciyhnIk"
        const val lineFeed = "\r\n"

        private var createdNotificationChannel = false


        /** Converts [Task] to JSON string representation */
        private fun taskToJsonString(task: Task): String {
            val gson = Gson()
            return gson.toJson(task.toJsonMap())
        }

        /**
         * Post method message on backgroundChannel with arguments and return true if this was
         * successful
         *
         * [arg] can be single variable or a MutableList
         */
        private suspend fun postOnBackgroundChannel(
            method: String, task: Task, arg: Any
        ): Boolean {
            val runningOnUIThread = Looper.myLooper() == Looper.getMainLooper()
            return coroutineScope {
                val success = CompletableDeferred<Boolean>()
                Handler(Looper.getMainLooper()).post {
                    try {
                        val argList = mutableListOf<Any>(
                            taskToJsonString(task)
                        )
                        if (arg is ArrayList<*>) {
                            argList.addAll(arg)
                        } else {
                            argList.add(arg)
                        }
                        if (BackgroundDownloaderPlugin.backgroundChannel != null) {
                            BackgroundDownloaderPlugin.backgroundChannel?.invokeMethod(
                                method, argList
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
         * task from persistent storage.
         *
         * Optional [taskException] for status .failed
         * */
        suspend fun processStatusUpdate(
            task: Task,
            status: TaskStatus,
            prefs: SharedPreferences,
            taskException: TaskException? = null,
            responseBody: String? = null,
            context: Context? = null
        ) {
            // A 'failed' progress update is only provided if
            // a retry is not needed: if it is needed, a `waitingToRetry` progress update
            // will be generated on the Dart side
            val retryNeeded = status == TaskStatus.failed && task.retriesRemaining > 0
            var canSendStatusUpdate = true  // may become false for cancellations
            // if task is in final state, process a final progressUpdate
            when (status) {
                TaskStatus.complete -> processProgressUpdate(
                    task, 1.0, prefs
                )

                TaskStatus.failed -> if (!retryNeeded) processProgressUpdate(
                    task, -1.0, prefs
                )

                TaskStatus.canceled -> {
                    canSendStatusUpdate = canSendCancellation(task)
                    if (canSendStatusUpdate) {
                        BackgroundDownloaderPlugin.canceledTaskIds[task.taskId] =
                            currentTimeMillis()
                        processProgressUpdate(
                            task, -2.0, prefs
                        )
                    }
                }

                TaskStatus.notFound -> processProgressUpdate(
                    task, -3.0, prefs
                )

                TaskStatus.paused -> processProgressUpdate(
                    task, -5.0, prefs
                )

                else -> {}
            }

            // Post update if task expects one, or if failed and retry is needed
            if (canSendStatusUpdate && (task.providesStatusUpdates() || retryNeeded)) {
                val finalTaskException = taskException ?: TaskException(ExceptionType.general)
                // send exception data only for .failed task, otherwise just the status
                val arg: Any = if (status == TaskStatus.failed) mutableListOf(
                    status.ordinal,
                    finalTaskException.type.typeString,
                    finalTaskException.description,
                    finalTaskException.httpResponseCode,
                    responseBody
                ) else mutableListOf(
                    status.ordinal,
                    if (status.isFinalState()) responseBody else null
                )
                if (!postOnBackgroundChannel("statusUpdate", task, arg)) {
                    // unsuccessful post, so store in local prefs (without exception info)
                    Log.d(TAG, "Could not post status update -> storing locally")
                    val jsonMap = task.toJsonMap().toMutableMap()
                    jsonMap["taskStatus"] = status.ordinal // merge into Task JSON
                    storeLocally(
                        BackgroundDownloaderPlugin.keyStatusUpdateMap, task.taskId, jsonMap,
                        prefs
                    )
                }
            }
            // if task is in final state, cancel the WorkManager job (if failed),
            // remove task from persistent storage and remove resume data from local memory
            if (status.isFinalState()) {
                if (context != null && status == TaskStatus.failed) {
                    // Cancel the WorkManager job.
                    // This is to avoid the WorkManager restarting a job that was
                    // canceled because job constraints are violated (e.g. network unavailable)
                    // We want to manage cancellation ourselves, so we cancel the job
                    val workManager = WorkManager.getInstance(context)
                    val operation = workManager.cancelAllWorkByTag("taskId=${task.taskId}")
                    try {
                        withContext(Dispatchers.IO) {
                            operation.result.get()
                        }
                    } catch (e: Throwable) {
                        Log.w(
                            BackgroundDownloaderPlugin.TAG,
                            "Could not kill task wih id ${task.taskId} in operation: $operation"
                        )
                    }
                }
                BackgroundDownloaderPlugin.prefsLock.write {
                    val tasksMap = getTaskMap(prefs)
                    tasksMap.remove(task.taskId)
                    val editor = prefs.edit()
                    editor.putString(
                        BackgroundDownloaderPlugin.keyTasksMap,
                        BackgroundDownloaderPlugin.gson.toJson(tasksMap)
                    )
                    editor.apply()
                }
                BackgroundDownloaderPlugin.localResumeData.remove(task.taskId)
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
            task: Task, progress: Double, prefs: SharedPreferences, expectedFileSize: Long = -1,
            downloadSpeed: Double = -1.0, timeRemaining: Long = -1000
        ) {
            if (task.providesProgressUpdates()) {
                if (!postOnBackgroundChannel(
                        "progressUpdate",
                        task,
                        mutableListOf(progress, expectedFileSize, downloadSpeed, timeRemaining)
                    )
                ) {
                    // unsuccessful post, so store in local prefs
                    Log.d(TAG, "Could not post progress update -> storing locally")
                    val jsonMap = task.toJsonMap().toMutableMap()
                    jsonMap["progress"] = progress // merge into Task JSON
                    jsonMap["expectedFileSize"] = expectedFileSize
                    storeLocally(
                        BackgroundDownloaderPlugin.keyProgressUpdateMap, task.taskId, jsonMap,
                        prefs
                    )
                }
            }
        }

        /**
         * Send 'canResume' message via the background channel to Flutter
         */
        suspend fun processCanResume(task: Task, canResume: Boolean) {
            postOnBackgroundChannel("canResume", task, canResume)
        }

        /**
         * Process resume information
         *
         * Attempts to post this to the Dart side via background channel. If that is not
         * successful, stores the resume data in shared preferences, for later retrieval by
         * the Dart side.
         *
         * Also stores a copy in memory locally, to allow notifications to resume a task
         */
        suspend fun processResumeData(resumeData: ResumeData, prefs: SharedPreferences) {
            BackgroundDownloaderPlugin.localResumeData[resumeData.task.taskId] = resumeData
            if (!postOnBackgroundChannel(
                    "resumeData", resumeData.task, mutableListOf(
                        resumeData.data,
                        resumeData.requiredStartByte,
                        resumeData.eTag
                    )
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
                val jsonString = prefs.getString(prefsKey, "{}")
                val mapByTaskId = BackgroundDownloaderPlugin.gson.fromJson<Map<String, Any>>(
                    jsonString, BackgroundDownloaderPlugin.jsonMapType
                ).toMutableMap()
                mapByTaskId[taskId] = item
                val editor = prefs.edit()
                editor.putString(
                    prefsKey, BackgroundDownloaderPlugin.gson.toJson(mapByTaskId)
                )
                editor.apply()
            }
        }

        /**
         * Returns the multipart entry for one field name/value pair
         */
        private fun fieldEntry(name: String, value: String): String {
            return "--$boundary$lineFeed${headerForField(name, value)}$value$lineFeed"
        }

        /**
         * Returns the header string for a field
         *
         * The return value is guaranteed to contain only ASCII characters
         */
        private fun headerForField(name: String, value: String): String {
            var header = "content-disposition: form-data; name=\"${browserEncode(name)}\""
            if (!isPlainAscii(value)) {
                header = "$header\r\n" +
                        "content-type: text/plain; charset=utf-8\r\n" +
                        "content-transfer-encoding: binary"
            }
            return "$header\r\n\r\n"
        }

        /**
         * Returns whether [string] is composed entirely of ASCII-compatible characters
         */
        private fun isPlainAscii(string: String): Boolean {
            return asciiOnlyRegEx.matches(string)
        }

        /**
         * Encode [value] in the same way browsers do
         */
        private fun browserEncode(value: String): String {
            // http://tools.ietf.org/html/rfc2388 mandates some complex encodings for
            // field names and file names, but in practice user agents seem not to
            // follow this at all. Instead, they URL-encode `\r`, `\n`, and `\r\n` as
            // `\r\n`; URL-encode `"`; and do nothing else (even for `%` or non-ASCII
            // characters). We follow their behavior.
            return value.replace(newlineRegEx, "%0D%0A").replace("\"", "%22")
        }

        /**
         * Returns the length of the [string] in bytes when utf-8 encoded
         */
        private fun lengthInBytes(string: String): Int {
            return string.toByteArray().size
        }
    }

    // properties related to pause/resume functionality and progress
    private var requiredStartByte = 0L
    private var bytesTotal = 0L
    private var bytesTotalAtLastProgressUpdate = 0L
    private var startByte = 0L
    private var eTagHeader: String? = null
    private var eTag: String? = null
    private var lastProgressUpdateTime = 0L // in millis
    private var networkSpeed = -1.0 // in MB/s
    private var isTimedOut = false
    private var taskCanResume = false // whether task is able to resume
    private var isResume = false // whether task is a resume
    private var tempFilePath = ""
    private var serverAcceptsRanges = false // if true, send resume data on fail

    // properties related to notifications
    private var notificationConfigJsonString: String? = null
    private var notificationConfig: NotificationConfig? = null
    private var notificationId = 0
    private var notificationProgress = 2.0 // indeterminate
    private var lastNotificationTime = 0L

    private var taskException: TaskException? = null
    private var responseBody: String? = null
    private var runInForegroundFileSize: Int = -1
    private var canRunInForeground = false
    private var runInForeground = false

    private lateinit var prefs: SharedPreferences

    /**
     * Worker execution entrypoint
     */
    override suspend fun doWork(): Result {
        prefs = PreferenceManager.getDefaultSharedPreferences(applicationContext)
        runInForegroundFileSize =
            prefs.getInt(BackgroundDownloaderPlugin.keyConfigForegroundFileSize, -1)
        withContext(Dispatchers.IO) {
            Timer().schedule(taskTimeoutMillis) {
                isTimedOut =
                    true // triggers .failed in [TransferBytes] method if not runInForeground
            }
            val gson = Gson()
            val taskJsonMapString = inputData.getString(keyTask)
            val task = Task(
                gson.fromJson(taskJsonMapString, BackgroundDownloaderPlugin.jsonMapType)
            )
            notificationConfigJsonString = inputData.getString(keyNotificationConfig)
            notificationConfig =
                if (notificationConfigJsonString != null) BackgroundDownloaderPlugin.gson.fromJson(
                    notificationConfigJsonString, NotificationConfig::class.java
                ) else null
            canRunInForeground = runInForegroundFileSize >= 0 &&
                    notificationConfig?.running != null // must have notification
            // pre-process resume
            requiredStartByte = inputData.getLong(keyStartByte, 0)
            isResume = requiredStartByte != 0L
            // set tempFilePath from resume data, or "" if a new tempFile is needed
            tempFilePath = if (isResume) inputData.getString(keyTempFilename) ?: ""
            else ""
            eTag = inputData.getString(keyEtag)
            isResume = isResume && determineIfResumeIsPossible()
            Log.i(
                TAG,
                "${if (isResume) "Resuming" else "Starting"} task with taskId ${task.taskId}"
            )
            processStatusUpdate(task, TaskStatus.running, prefs)
            if (!isResume) {
                processProgressUpdate(task, 0.0, prefs)
            }
            updateNotification(task, notificationTypeForTaskStatus(TaskStatus.running))
            val status = doTask(task)
            withContext(NonCancellable) {
                // NonCancellable to make sure we complete the status and notification
                // updates even if the job is being cancelled
                processStatusUpdate(
                    task,
                    status,
                    prefs,
                    taskException,
                    responseBody,
                    applicationContext
                )
                updateNotification(task, notificationTypeForTaskStatus(status))
            }
        }
        return Result.success()
    }

    /** Return true if resume is possible, given [tempFilePath] and [requiredStartByte] */
    private fun determineIfResumeIsPossible(): Boolean {
        val tempFile = File(tempFilePath)
        if (tempFile.exists()) {
            val tempFileLength = tempFile.length()
            if (tempFileLength == requiredStartByte) {
                return true
            } else {
                // attempt to truncate the file to the expected size
                Log.d(
                    TAG,
                    "File length = ${tempFile.length()} vs requiredStartByte = $requiredStartByte"
                )
                if (tempFileLength > requiredStartByte && Build.VERSION.SDK_INT >= 26) {
                    try {
                        val fileChannel =
                            FileChannel.open(tempFile.toPath(), StandardOpenOption.WRITE)
                        fileChannel.truncate(requiredStartByte)
                        fileChannel.close()
                        Log.d(TAG, "Truncated temp file to desired length")
                        return true
                    } catch (e: IOException) {
                        e.printStackTrace()
                    }
                }
                Log.i(TAG, "Partially downloaded file is corrupted, resume not possible")
            }
        } else {
            Log.i(TAG, "Partially downloaded file not available, resume not possible")
        }
        return false
    }

    /**
     * do the task: download or upload a file
     */
    private suspend fun doTask(task: Task): TaskStatus {
        try {
            val urlString = task.url
            val url = URL(urlString)
            val prefs = PreferenceManager.getDefaultSharedPreferences(applicationContext)
            val requestTimeoutSeconds =
                prefs.getInt(BackgroundDownloaderPlugin.keyConfigRequestTimeout, 60)
            val proxyAddress =
                prefs.getString(BackgroundDownloaderPlugin.keyConfigProxyAddress, null)
            val proxyPort = prefs.getInt(BackgroundDownloaderPlugin.keyConfigProxyPort, 0)
            val proxy = if (proxyAddress != null && proxyPort != 0) Proxy(
                Proxy.Type.HTTP,
                InetSocketAddress(proxyAddress, proxyPort)
            ) else null
            if (!BackgroundDownloaderPlugin.haveLoggedProxyMessage) {
                Log.i(
                    TAG,
                    if (proxy == null) "Not using proxy for any task"
                    else "Using proxy $proxyAddress:$proxyPort for all tasks"
                )
                BackgroundDownloaderPlugin.haveLoggedProxyMessage = true
            }
            with(withContext(Dispatchers.IO) {
                url.openConnection(proxy ?: Proxy.NO_PROXY)
            } as HttpURLConnection) {
                connectTimeout = requestTimeoutSeconds * 1000
                for (header in task.headers) {
                    setRequestProperty(header.key, header.value)
                }
                if (isResume) {
                    setRequestProperty("Range", "bytes=$requiredStartByte-")
                }
                return connectAndProcess(this, task)
            }
        } catch (e: Exception) {
            Log.w(
                TAG, "Error downloading from ${task.url} to ${task.filename}: $e"
            )
            setTaskException(e)
        }
        return TaskStatus.failed
    }

    /** Make the request to the [connection] and process the [Task] */
    private suspend fun connectAndProcess(connection: HttpURLConnection, task: Task): TaskStatus {
        val filePath = task.filePath(applicationContext) // "" for MultiUploadTask
        try {
            connection.requestMethod = task.httpRequestMethod
            if (task.isDownloadTask()) {
                if (task.post != null) {
                    connection.doOutput = true
                    connection.setFixedLengthStreamingMode(task.post.length)
                    DataOutputStream(connection.outputStream).use { it.writeBytes(task.post) }
                }
                return processDownload(connection, task, filePath)
            }
            return processUpload(connection, task, filePath)
        } catch (e: Exception) {
            setTaskException(e)
            when (e) {
                is FileSystemException -> Log.w(
                    TAG,
                    "Filesystem exception for taskId ${task.taskId} and $filePath: ${e.message}"
                )

                is SocketException -> Log.i(
                    TAG,
                    "Socket exception for taskId ${task.taskId} and $filePath: ${e.message}"
                )

                is CancellationException -> {
                    Log.i(
                        TAG,
                        "Job cancelled for taskId ${task.taskId} and $filePath: ${e.message}"
                    )
                    deleteTempFile()
                    return TaskStatus.canceled
                }

                else -> {
                    Log.w(
                        TAG,
                        "Error for taskId ${task.taskId} and $filePath: ${e.message}"
                    )
                    taskException = TaskException(
                        ExceptionType.general, description =
                        "Error for url ${task.url} and $filePath: ${e.message}"
                    )
                }
            }
        } finally {
            // clean up remaining bytes tracking
            BackgroundDownloaderPlugin.remainingBytesToDownload.remove(task.taskId)
        }
        prepResumeAfterFailure(task)
        return TaskStatus.failed
    }

    /** Process the response to the GET or POST request on this [connection]
     *
     * Returns the [TaskStatus]
     */
    private suspend fun processDownload(
        connection: HttpURLConnection,
        task: Task,
        filePath: String
    ): TaskStatus {
        if (connection.responseCode in 200..206) {
            // ok response, check if resume is possible
            eTagHeader = connection.headerFields["ETag"]?.first()
            val acceptRangesHeader = connection.headerFields["Accept-Ranges"]
            serverAcceptsRanges =
                acceptRangesHeader?.first() == "bytes" || connection.responseCode == 206
            if (task.allowPause) {
                taskCanResume = serverAcceptsRanges
                processCanResume(
                    task,
                    taskCanResume
                )
            }
            isResume = isResume && connection.responseCode == 206  // confirm resume response
            if (isResume && !prepareResume(connection)) {
                deleteTempFile()
                return TaskStatus.failed
            }
            if (isResume && (eTagHeader != eTag || eTag?.subSequence(0, 1) == "W/")) {
                deleteTempFile()
                Log.i(TAG, "Cannot resume: ETag is not identical, or is weak")
                taskException = TaskException(
                    ExceptionType.resume,
                    description = "Cannot resume: ETag is not identical, or is weak"
                )
                return TaskStatus.failed
            }
            // determine tempFile
            val contentLength = connection.contentLengthLong
            val tempDir = when (PreferenceManager.getDefaultSharedPreferences(applicationContext)
                .getInt(BackgroundDownloaderPlugin.keyConfigUseCacheDir, -2)) {
                0 -> applicationContext.cacheDir // 'always'
                -1 -> applicationContext.filesDir // 'never'
                else -> {
                    // 'whenAble' -> determine based on cache quota
                    val storageManager =
                        applicationContext.getSystemService(Context.STORAGE_SERVICE) as StorageManager
                    val cacheQuota = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        storageManager.getCacheQuotaBytes(
                            storageManager.getUuidForPath(
                                applicationContext.cacheDir
                            )
                        )
                    } else {
                        50L shl (20)  // for older OS versions, assume 50MB
                    }
                    if (contentLength < cacheQuota / 2) applicationContext.cacheDir else applicationContext.filesDir
                }
            }
            tempFilePath =
                tempFilePath.ifEmpty { "${tempDir.absolutePath}/com.bbflight.background_downloader${Random.nextInt()}" }
            val tempFile = File(tempFilePath)
            // confirm enough storage space for download
            if (insufficientSpace(applicationContext, contentLength)) {
                Log.i(
                    TAG,
                    "Insufficient space to store the file to be downloaded for taskId ${task.taskId}"
                )
                taskException = TaskException(
                    ExceptionType.fileSystem,
                    description = "Insufficient space to store the file to be downloaded"
                )
                return TaskStatus.failed
            }
            BackgroundDownloaderPlugin.remainingBytesToDownload[task.taskId] = contentLength
            determineRunInForeground(task, contentLength) // sets 'runInForeground'
            // transfer the bytes from the server to the temp file
            val transferBytesResult: TaskStatus
            BufferedInputStream(connection.inputStream).use { inputStream ->
                FileOutputStream(tempFile, isResume).use { outputStream ->
                    transferBytesResult = transferBytes(
                        inputStream, outputStream, contentLength, task
                    )
                }
            }
            // act on the result of the bytes transfer
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
                        deleteTempFile()
                    }
                    Log.i(
                        TAG, "Successfully downloaded taskId ${task.taskId} to $filePath"
                    )
                    return TaskStatus.complete
                }

                TaskStatus.canceled -> {
                    deleteTempFile()
                    Log.i(TAG, "Canceled taskId ${task.taskId} for $filePath")
                    return TaskStatus.canceled
                }

                TaskStatus.paused -> {
                    BackgroundDownloaderPlugin.pausedTaskIds.remove(task.taskId)
                    if (taskCanResume) {
                        Log.i(TAG, "Task ${task.taskId} paused")
                        processResumeData(
                            ResumeData(
                                task, tempFilePath, bytesTotal + startByte, eTagHeader
                            ), prefs
                        )
                        return TaskStatus.paused
                    }
                    Log.i(TAG, "Task ${task.taskId} cannot resume, therefore pause failed")
                    taskException = TaskException(
                        ExceptionType.resume,
                        description = "Task was paused but cannot resume"
                    )
                    deleteTempFile()
                    return TaskStatus.failed
                }

                TaskStatus.enqueued -> {
                    // Special status, in this context means that the task timed out
                    // so if allowed, pause it and schedule the resume task immediately
                    if (!task.allowPause) {
                        Log.i(TAG, "Task ${task.taskId} timed out")
                        taskException =
                            TaskException(
                                ExceptionType.connection,
                                description = "Task timed out"
                            )
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
                            eTag,
                            1000
                        )
                        return TaskStatus.paused
                    }
                    Log.i(TAG, "Task ${task.taskId} timed out and cannot pause/resume")
                    taskException =
                        TaskException(ExceptionType.connection, description = "Task timed out")
                    deleteTempFile()
                    return TaskStatus.failed
                }

                TaskStatus.failed -> {
                    prepResumeAfterFailure(task)
                    return TaskStatus.failed
                }

                else -> {
                    Log.e(TAG, "Unknown transferBytesResult $transferBytesResult")
                    deleteTempFile()
                    return TaskStatus.failed
                }
            }
        } else {
            // HTTP response code not OK
            Log.i(
                TAG,
                "Response code ${connection.responseCode} for download from  ${task.url} to $filePath"
            )
            val errorContent = responseErrorContent(connection)
            taskException = TaskException(
                ExceptionType.httpResponse, httpResponseCode = connection.responseCode,
                description = if (errorContent?.isNotEmpty() == true) errorContent else connection.responseMessage
            )
            return if (connection.responseCode == 404) {
                responseBody = errorContent
                TaskStatus.notFound
            } else {
                TaskStatus.failed
            }
        }
    }


    /**
     * Process the upload of the file
     *
     * If the [Task.post] field is set to "binary" then the file will be uploaded as a byte stream POST
     *
     * If the [Task.post] field is not "binary" then the file(s) will be uploaded as a multipart POST
     *
     * Note that the [Task.post] field is just used to set whether this is a binary or multipart
     * upload. The bytes that will be posted are derived from the file to be uploaded.
     *
     * Returns the [TaskStatus]
     */
    private suspend fun processUpload(
        connection: HttpURLConnection, task: Task, filePath: String
    ): TaskStatus {
        connection.doOutput = true
        val transferBytesResult =
            if (task.post?.lowercase() == "binary") {
                processBinaryUpload(connection, task, filePath)
            } else {
                processMultipartUpload(connection, task, filePath)
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
                responseBody = responseBodyContent(connection)
                if (connection.responseCode in 200..206) {
                    Log.i(
                        TAG, "Successfully uploaded taskId ${task.taskId} from $filePath"
                    )
                    return TaskStatus.complete
                }
                Log.i(
                    TAG,
                    "Response code ${connection.responseCode} for upload of $filePath to ${task.url}"
                )
                val errorContent = responseErrorContent(connection)
                taskException = TaskException(
                    ExceptionType.httpResponse, httpResponseCode = connection.responseCode,
                    description = if (errorContent?.isNotEmpty() == true) errorContent else connection.responseMessage
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
     * Process the binary upload of the file
     *
     * Content-Disposition will be set to "attachment" with filename [Task.filename], and the
     * mime-type will be set to [Task.mimeType]
     *
     * Returns the [TaskStatus]
     */
    private suspend fun processBinaryUpload(
        connection: HttpURLConnection, task: Task, filePath: String
    ): TaskStatus {
        val file = File(filePath)
        if (!file.exists() || !file.isFile) {
            Log.w(TAG, "File $filePath does not exist or is not a file")
            taskException = TaskException(
                ExceptionType.fileSystem,
                description = "File to upload does not exist: $filePath"
            )
            return TaskStatus.failed
        }
        val fileSize = file.length()
        if (fileSize <= 0) {
            Log.w(TAG, "File $filePath has 0 length")
            taskException = TaskException(
                ExceptionType.fileSystem,
                description = "File $filePath has 0 length"
            )
            return TaskStatus.failed
        }
        determineRunInForeground(task, fileSize)
        // binary file upload posts file bytes directly
        // set Content-Type based on file extension
        Log.d(TAG, "Binary upload for taskId ${task.taskId}")
        connection.setRequestProperty("Content-Type", task.mimeType)
        connection.setRequestProperty(
            "Content-Disposition", "attachment; filename=\"" + task.filename + "\""
        )
        connection.setRequestProperty("Content-Length", fileSize.toString())
        connection.setFixedLengthStreamingMode(fileSize)
        return withContext(Dispatchers.IO) {
            FileInputStream(file).use { inputStream ->
                DataOutputStream(connection.outputStream.buffered()).use { outputStream ->
                    return@withContext transferBytes(inputStream, outputStream, fileSize, task)
                }
            }
        }
    }

    /**
     * Process the multi-part upload of one or more files, and potential form fields
     *
     * Form fields are taken from [Task.fields]. If only one file is to be uploaded,
     * then the [filePath] determines the file, and [Task.fileField] and [Task.mimeType]
     * are used to set the file field name and mime type respectively.
     * If [filePath] is empty, then the list of fileField, filePath and mimeType are
     * extracted from the [Task.fileField], [Task.filename] and [Task.mimeType] (which
     * for MultiUploadTasks contain a JSON encoded list of strings).
     *
     * The total content length is calculated from the sum of all parts, the connection
     * is set up, and the bytes for each part are transferred to the host.
     *
     * Returns the [TaskStatus]
     */
    private suspend fun processMultipartUpload(
        connection: HttpURLConnection, task: Task,
        filePath: String
    ): TaskStatus {
        // field portion of the multipart
        var fieldsString = ""
        for (entry in task.fields.entries) {
            fieldsString += fieldEntry(entry.key, entry.value)
        }
        // File portion of the multi-part
        // Assumes list of files. If only one file, that becomes a list of length one.
        // For each file, determine contentDispositionString, contentTypeString
        // and file length, so that we can calculate total size of upload
        val separator = "$lineFeed--$boundary$lineFeed" // between files
        val terminator = "$lineFeed--$boundary--$lineFeed" // after last file
        val filesData = if (filePath.isNotEmpty()) {
            listOf(
                Triple(task.fileField, filePath, task.mimeType)
            )
        } else {
            task.extractFilesData(applicationContext)
        }
        val contentDispositionStrings = ArrayList<String>()
        val contentTypeStrings = ArrayList<String>()
        val fileLengths = ArrayList<Long>()
        for ((fileField, path, mimeType) in filesData) {
            val file = File(path)
            if (!file.exists() || !file.isFile) {
                Log.w(TAG, "File at $path does not exist")
                taskException = TaskException(
                    ExceptionType.fileSystem,
                    description = "File to upload does not exist: $path"
                )
                return TaskStatus.failed
            }
            contentDispositionStrings.add(
                "Content-Disposition: form-data; name=\"${browserEncode(fileField)}\"; " +
                        "filename=\"${browserEncode(file.name)}\"$lineFeed"
            )
            contentTypeStrings.add("Content-Type: $mimeType$lineFeed$lineFeed")
            fileLengths.add(file.length())
        }
        val fileDataLength =
            contentDispositionStrings.sumOf { string: String -> lengthInBytes(string) } +
                    contentTypeStrings.sumOf { string: String -> string.length } +
                    fileLengths.sum() + separator.length * contentDispositionStrings.size + 2
        val contentLength =
            lengthInBytes(fieldsString) + "--$boundary$lineFeed".length + fileDataLength
        determineRunInForeground(task, contentLength)
        // setup the connection
        connection.setRequestProperty("Accept-Charset", "UTF-8")
        connection.setRequestProperty("Connection", "Keep-Alive")
        connection.setRequestProperty("Cache-Control", "no-cache")
        connection.setRequestProperty(
            "Content-Type", "multipart/form-data; boundary=$boundary"
        )
        connection.setRequestProperty("Content-Length", contentLength.toString())
        connection.setFixedLengthStreamingMode(contentLength)
        connection.useCaches = false
        // transfer the bytes
        return withContext(Dispatchers.IO) {
            DataOutputStream(connection.outputStream).use { outputStream ->
                val writer = outputStream.writer()
                // write form fields
                writer.append(fieldsString).append("--${boundary}").append(lineFeed)
                // write each file
                for (i in filesData.indices) {
                    FileInputStream(filesData[i].second).use { inputStream ->
                        writer.append(contentDispositionStrings[i])
                            .append(contentTypeStrings[i]).flush()
                        val transferBytesResult =
                            transferBytes(inputStream, outputStream, contentLength, task)
                        if (transferBytesResult == TaskStatus.complete) {
                            if (i < filesData.size - 1) {
                                writer.append(separator)
                            } else
                                writer.append(terminator)
                        } else {
                            return@withContext transferBytesResult
                        }
                    }
                }
                writer.close()
            }
            return@withContext TaskStatus.complete
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
        inputStream: InputStream, outputStream: OutputStream, contentLength: Long, task: Task
    ): TaskStatus {
        val dataBuffer = ByteArray(bufferSize)
        var lastProgressUpdate = 0.0
        var nextProgressUpdateTime = 0L
        var numBytes: Int
        return withContext(Dispatchers.Default) {
            var readerJob: Job? = null
            var testerJob: Job? = null
            val doneCompleter = CompletableDeferred<TaskStatus>()
            try {
                readerJob = launch(Dispatchers.IO) {
                    while (inputStream.read(
                            dataBuffer, 0,
                            bufferSize
                        )
                            .also { numBytes = it } != -1
                    ) {
                        if (!isActive) {
                            doneCompleter.complete(TaskStatus.failed)
                            break
                        }
                        if (numBytes > 0) {
                            outputStream.write(dataBuffer, 0, numBytes)
                            bytesTotal += numBytes
                            val remainingBytes =
                                BackgroundDownloaderPlugin.remainingBytesToDownload[task.taskId]
                            if (remainingBytes != null) {
                                BackgroundDownloaderPlugin.remainingBytesToDownload[task.taskId] =
                                    remainingBytes - numBytes
                            }
                        }
                        val expectedFileSize = contentLength + startByte
                        val progress = doubleMin(
                            (bytesTotal + startByte).toDouble() / expectedFileSize,
                            0.999
                        )
                        if (contentLength > 0 && progress - lastProgressUpdate > 0.02 && currentTimeMillis() > nextProgressUpdateTime) {
                            // calculate download speed and time remaining
                            val now = currentTimeMillis()
                            val timeSinceLastUpdate = now - lastProgressUpdateTime
                            lastProgressUpdateTime = now
                            val bytesSinceLastUpdate = bytesTotal - bytesTotalAtLastProgressUpdate
                            bytesTotalAtLastProgressUpdate = bytesTotal
                            val currentNetworkSpeed: Double = if (timeSinceLastUpdate > 3600000)
                                -1.0 else bytesSinceLastUpdate / (timeSinceLastUpdate * 1000.0)
                            networkSpeed =
                                if (networkSpeed == -1.0) currentNetworkSpeed else (networkSpeed * 3.0 + currentNetworkSpeed) / 4.0
                            val remainingBytes = (1 - progress) * expectedFileSize
                            val timeRemaining: Long =
                                if (networkSpeed == -1.0) -1000 else (remainingBytes / networkSpeed / 1000).toLong()
                            // update progress and notification
                            processProgressUpdate(
                                task,
                                progress,
                                prefs,
                                expectedFileSize,
                                networkSpeed,
                                timeRemaining
                            )
                            updateNotification(
                                task, notificationTypeForTaskStatus(TaskStatus.running),
                                progress, timeRemaining
                            )
                            lastProgressUpdate = progress
                            nextProgressUpdateTime = currentTimeMillis() + 500
                        }
                    }
                    doneCompleter.complete(TaskStatus.complete)
                }
                testerJob = launch {
                    while (isActive) {
                        // check if task is stopped (canceled), paused or timed out
                        if (isStopped) {
                            doneCompleter.complete(TaskStatus.failed)
                            break
                        }
                        // 'pause' is signalled by adding the taskId to a static list
                        if (BackgroundDownloaderPlugin.pausedTaskIds.contains(task.taskId)) {
                            doneCompleter.complete(TaskStatus.paused)
                            break
                        }
                        if (isTimedOut && !runInForeground) {
                            // special use of .enqueued status, see [processDownload]
                            doneCompleter.complete(TaskStatus.enqueued)
                            break
                        }
                        delay(100)
                    }
                }
                return@withContext doneCompleter.await()
            } catch (e: Exception) {
                Log.i(TAG, "Exception for taskId ${task.taskId}: $e")
                setTaskException(e)
                return@withContext TaskStatus.failed
            } finally {
                readerJob?.cancelAndJoin()
                testerJob?.cancelAndJoin()
            }
        }
    }

    /** Prepare for resume if possible
     *
     * Returns true if task can continue, false if task failed.
     * Extracts and parses Range headers, and truncates temp file
     */
    private fun prepareResume(connection: HttpURLConnection): Boolean {
        if (tempFilePath.isEmpty()) {
            return false
        }
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
            taskException = TaskException(
                ExceptionType.resume,
                description = "Could not process partial response Content-Range $range"
            )
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
            taskException = TaskException(
                ExceptionType.resume,
                description = "Offered range not feasible: $range"
            )
            return false
        }
        startByte = start
        // resume possible, set start conditions
        try {
            RandomAccessFile(tempFilePath, "rw").use { it.setLength(start) }
        } catch (e: IOException) {
            Log.i(TAG, "Could not truncate temp file")
            taskException =
                TaskException(
                    ExceptionType.resume,
                    description = "Could not truncate temp file"
                )
            return false
        }
        return true
    }

    /**
     * Attempt to allow resume after failure by sending resume data
     * back to Dart
     *
     * If this is not possible, the temp file will be deleted
     */
    private suspend fun prepResumeAfterFailure(task: Task) {
        if (serverAcceptsRanges && bytesTotal + startByte > 1 shl 20) {
            // if failure can be resumed, post resume data
            processResumeData(
                ResumeData(
                    task, tempFilePath, bytesTotal + startByte, eTagHeader
                ), prefs
            )
        } else {
            // if it cannot be resumed, delete the temp file
            deleteTempFile()
        }

    }

    /**
     * Create the notification channel to use for download notifications
     */
    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val name =
                applicationContext.getString(R.string.bg_downloader_notification_channel_name)
            val descriptionText = applicationContext.getString(
                R.string.bg_downloader_notification_channel_description
            )
            val importance = NotificationManager.IMPORTANCE_LOW
            val channel = NotificationChannel(
                BackgroundDownloaderPlugin.notificationChannel, name, importance
            ).apply {
                description = descriptionText
            }
            // Register the channel with the system
            val notificationManager: NotificationManager = applicationContext.getSystemService(
                NOTIFICATION_SERVICE
            ) as NotificationManager
            notificationManager.createNotificationChannel(channel)
        }
        createdNotificationChannel = true
    }

    /**
     * Create or update the notification for this [task], associated with this [notificationType]
     * and [progress]
     *
     * [notificationType] determines the type of notification, and whether absence of one will
     * cancel the notification
     * The [progress] field is only relevant for [NotificationType.running]. If progress is
     * negative no progress bar will be shown. If progress > 1 an indeterminate progress bar
     * will be shown
     * [networkSpeed] and [timeRemaining] are only relevant for [NotificationType.running]
     */
    @SuppressLint("MissingPermission")
    private suspend fun updateNotification(
        task: Task, notificationType: NotificationType, progress: Double = 2.0,
        timeRemaining: Long = -1000
    ) {
        val notification = when (notificationType) {
            NotificationType.running -> notificationConfig?.running
            NotificationType.complete -> notificationConfig?.complete
            NotificationType.error -> notificationConfig?.error
            NotificationType.paused -> notificationConfig?.paused
        }
        val removeNotification = when (notificationType) {
            NotificationType.running -> false
            else -> notification == null
        }
        if (removeNotification) {
            if (notificationId != 0) {
                with(NotificationManagerCompat.from(applicationContext)) {
                    cancel(notificationId)
                }
            }
            return
        }
        if (notification == null) {
            return
        }
        // need to show a notification
        if (!createdNotificationChannel) {
            createNotificationChannel()
        }
        if (notificationId == 0) {
            notificationId = task.taskId.hashCode()
        }
        val iconDrawable = when (notificationType) {
            NotificationType.running -> if (task.isDownloadTask()) R.drawable.outline_file_download_24 else R.drawable.outline_file_upload_24
            NotificationType.complete -> R.drawable.outline_download_done_24
            NotificationType.error -> R.drawable.outline_error_outline_24
            NotificationType.paused -> R.drawable.outline_pause_24
        }
        val builder = NotificationCompat.Builder(
            applicationContext, BackgroundDownloaderPlugin.notificationChannel
        ).setPriority(NotificationCompat.PRIORITY_LOW).setSmallIcon(iconDrawable)
        // use stored progress if notificationType is .paused
        notificationProgress =
            if (notificationType == NotificationType.paused) notificationProgress else progress
        // title and body interpolation of {filename}, {progress} and {metadata}
        val title = replaceTokens(
            notification.title,
            task,
            notificationProgress,
            timeRemaining
        )
        if (title.isNotEmpty()) {
            builder.setContentTitle(title)
        }
        val body = replaceTokens(
            notification.body,
            task,
            notificationProgress,
            timeRemaining
        )
        if (body.isNotEmpty()) {
            builder.setContentText(body)
        }
        // progress bar
        val progressBar =
            notificationConfig?.progressBar ?: false && (notificationType == NotificationType.running || notificationType == NotificationType.paused)
        if (progressBar && notificationProgress >= 0) {
            if (notificationProgress <= 1) {
                builder.setProgress(100, (notificationProgress * 100).roundToInt(), false)
            } else { // > 1 means indeterminate
                builder.setProgress(100, 0, true)
            }
        }
        // action buttons
        addNotificationActions(notificationType, task, builder)
        with(NotificationManagerCompat.from(applicationContext)) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                // On Android 33+, check/ask for permission
                if (ActivityCompat.checkSelfPermission(
                        applicationContext, Manifest.permission.POST_NOTIFICATIONS
                    ) != PackageManager.PERMISSION_GRANTED
                ) {
                    if (BackgroundDownloaderPlugin.requestingNotificationPermission) {
                        return  // don't ask twice
                    }
                    BackgroundDownloaderPlugin.requestingNotificationPermission = true
                    BackgroundDownloaderPlugin.activity?.requestPermissions(
                        arrayOf(
                            Manifest.permission.POST_NOTIFICATIONS
                        ), BackgroundDownloaderPlugin.notificationPermissionRequestCode
                    )
                    return
                }
            }
            val androidNotification = builder.build()
            if (runInForeground) {
                if (notificationType == NotificationType.running) {
                    setForeground(ForegroundInfo(notificationId, androidNotification))
                } else {
                    // to prevent the 'not running' notification getting killed as the foreground
                    // process is terminated, this notification is shown regularly, but with
                    // a delay
                    CoroutineScope(Dispatchers.Main).launch {
                        delay(200)
                        notify(notificationId, androidNotification)
                    }
                }
            } else {
                val now = currentTimeMillis()
                val timeSinceLastUpdate = now - lastNotificationTime
                lastNotificationTime = now
                if (notificationType == NotificationType.running || timeSinceLastUpdate > 2000) {
                    notify(notificationId, androidNotification)
                } else {
                    // to prevent the 'not running' notification getting ignored
                    // due to too frequent updates, post it with a delay
                    CoroutineScope(Dispatchers.Main).launch {
                        delay(2000 - max(timeSinceLastUpdate, 1000L))
                        notify(notificationId, androidNotification)
                    }
                }
            }
        }
    }

    /**
     * Add action to notification via buttons or tap
     *
     * Which button(s) depends on the [notificationType], and the actions require
     * access to [task] and the [builder]
     */
    private fun addNotificationActions(
        notificationType: NotificationType, task: Task, builder: NotificationCompat.Builder
    ) {
        val activity = BackgroundDownloaderPlugin.activity
        if (activity != null) {
            val taskJsonString = BackgroundDownloaderPlugin.gson.toJson(
                task.toJsonMap()
            )
            // add tap action for all notifications
            val tapIntent =
                applicationContext.packageManager.getLaunchIntentForPackage(
                    applicationContext.packageName
                )
            if (tapIntent != null) {
                tapIntent.apply {
                    action = NotificationRcvr.actionTap
                    putExtra(NotificationRcvr.keyTask, taskJsonString)
                    putExtra(NotificationRcvr.keyNotificationType, notificationType.ordinal)
                    putExtra(
                        NotificationRcvr.keyNotificationConfig,
                        notificationConfigJsonString
                    )
                    putExtra(NotificationRcvr.keyNotificationId, notificationId)
                }
                val tapPendingIntent: PendingIntent = PendingIntent.getActivity(
                    applicationContext,
                    notificationId,
                    tapIntent,
                    PendingIntent.FLAG_CANCEL_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
                builder.setContentIntent(tapPendingIntent)
            }
            // add buttons depending on notificationType
            when (notificationType) {
                NotificationType.running -> {
                    // cancel button when running
                    val cancelOrPauseBundle = Bundle().apply {
                        putString(NotificationRcvr.keyTaskId, task.taskId)
                    }
                    val cancelIntent =
                        Intent(applicationContext, NotificationRcvr::class.java).apply {
                            action = NotificationRcvr.actionCancelActive
                            putExtra(NotificationRcvr.keyBundle, cancelOrPauseBundle)
                        }
                    val cancelPendingIntent: PendingIntent = PendingIntent.getBroadcast(
                        applicationContext,
                        notificationId,
                        cancelIntent,
                        PendingIntent.FLAG_IMMUTABLE
                    )
                    builder.addAction(
                        R.drawable.outline_cancel_24,
                        activity.getString(R.string.bg_downloader_cancel),
                        cancelPendingIntent
                    )
                    if (taskCanResume && (notificationConfig?.paused != null)) {
                        // pause button when running and paused notification configured
                        val pauseIntent = Intent(
                            applicationContext, NotificationRcvr::class.java
                        ).apply {
                            action = NotificationRcvr.actionPause
                            putExtra(NotificationRcvr.keyBundle, cancelOrPauseBundle)
                        }
                        val pausePendingIntent: PendingIntent = PendingIntent.getBroadcast(
                            applicationContext,
                            notificationId,
                            pauseIntent,
                            PendingIntent.FLAG_IMMUTABLE
                        )
                        builder.addAction(
                            R.drawable.outline_pause_24,
                            activity.getString(R.string.bg_downloader_pause),
                            pausePendingIntent
                        )
                    }
                }

                NotificationType.paused -> {
                    // cancel button
                    val cancelBundle = Bundle().apply {
                        putString(NotificationRcvr.keyTaskId, task.taskId)
                        putString(
                            NotificationRcvr.keyTask, taskJsonString
                        )
                    }
                    val cancelIntent = Intent(
                        applicationContext, NotificationRcvr::class.java
                    ).apply {
                        action = NotificationRcvr.actionCancelInactive
                        putExtra(NotificationRcvr.keyBundle, cancelBundle)
                    }
                    val cancelPendingIntent: PendingIntent = PendingIntent.getBroadcast(
                        applicationContext,
                        notificationId,
                        cancelIntent,
                        PendingIntent.FLAG_IMMUTABLE
                    )
                    builder.addAction(
                        R.drawable.outline_cancel_24,
                        activity.getString(R.string.bg_downloader_cancel),
                        cancelPendingIntent
                    )
                    // resume button
                    val resumeBundle = Bundle().apply {
                        putString(NotificationRcvr.keyTaskId, task.taskId)
                        putString(
                            NotificationRcvr.keyTask, taskJsonString
                        )
                        putString(
                            NotificationRcvr.keyNotificationConfig,
                            notificationConfigJsonString
                        )
                    }
                    val resumeIntent = Intent(
                        applicationContext, NotificationRcvr::class.java
                    ).apply {
                        action = NotificationRcvr.actionResume
                        putExtra(NotificationRcvr.keyBundle, resumeBundle)
                    }
                    val resumePendingIntent: PendingIntent = PendingIntent.getBroadcast(
                        applicationContext,
                        notificationId,
                        resumeIntent,
                        PendingIntent.FLAG_IMMUTABLE
                    )
                    builder.addAction(
                        R.drawable.outline_play_arrow_24,
                        activity.getString(R.string.bg_downloader_resume),
                        resumePendingIntent
                    )
                }

                NotificationType.complete -> {}
                NotificationType.error -> {}
            }
        }
    }

    /**
     * Replace special tokens {filename}, {metadata}, {progress}, {networkSpeed},
     * {timeRemaining} with their respective values
     */
    private fun replaceTokens(
        input: String,
        task: Task,
        progress: Double,
        timeRemaining: Long
    ): String {
        // filename and metadata
        val output =
            fileNameRegEx.replace(metaDataRegEx.replace(input, task.metaData), task.filename)
        // progress
        val progressString =
            if (progress in 0.0..1.0) (progress * 100).roundToInt().toString() + "%"
            else ""
        val output2 = progressRegEx.replace(output, progressString)
        // download speed
        val networkSpeedString =
            if (networkSpeed <= 0.0) "-- MB/s" else if (networkSpeed > 1) "${networkSpeed.roundToInt()} MB/s" else "${(networkSpeed * 1000).roundToInt()} kB/s"
        val output3 = networkSpeedRegEx.replace(output2, networkSpeedString)
        // time remaining
        val hours = timeRemaining.div(3600000L)
        val minutes = (timeRemaining.mod(3600000L)).div(60000L)
        val seconds = (timeRemaining.mod(60000L)).div(1000L)
        val timeRemainingString = if (timeRemaining < 0) "--:--" else if (hours > 0)
            String.format(
                "%02d:%02d:%02d",
                hours,
                minutes,
                seconds
            ) else
            String.format(
                "%02d:%02d",
                minutes,
                seconds
            )
        return timeRemainingRegEx.replace(output3, timeRemainingString)
    }

    /**
     * Returns the notificationType related to this [status]
     */
    private fun notificationTypeForTaskStatus(status: TaskStatus): NotificationType {
        return when (status) {
            TaskStatus.enqueued, TaskStatus.running -> NotificationType.running
            TaskStatus.complete -> NotificationType.complete
            TaskStatus.paused -> NotificationType.paused
            else -> NotificationType.error
        }
    }

    /**
     * Determine if this task should run in the foreground
     *
     * Based on [canRunInForeground] and [contentLength] > [runInForegroundFileSize]
     */
    private fun determineRunInForeground(task: Task, contentLength: Long) {
        runInForeground =
            canRunInForeground && contentLength > (runInForegroundFileSize.toLong() shl 20)
        if (runInForeground) {
            Log.i(TAG, "TaskId ${task.taskId} will run in foreground")
        }
    }

    private fun deleteTempFile() {
        if (tempFilePath.isNotEmpty()) {
            try {
                val tempFile = File(tempFilePath)
                tempFile.delete()
            } catch (e: IOException) {
                Log.w(TAG, "Could not delete temp file at $tempFilePath")
            }
        }
    }

    /**
     * Return the response's error content as a String, or null if unable
     */
    private fun responseErrorContent(connection: HttpURLConnection): String? {
        try {
            return connection.errorStream.bufferedReader().readText()
        } catch (e: Exception) {
            Log.i(
                TAG,
                "Could not read response error content from httpResponseCode ${connection.responseCode}: $e"
            )
        }
        return null
    }

    /**
     * Return the response's body content as a String, or null if unable
     */
    private fun responseBodyContent(connection: HttpURLConnection): String? {
        try {
            return connection.inputStream.bufferedReader().readText()
        } catch (e: Exception) {
            Log.i(
                TAG,
                "Could not read response body from httpResponseCode ${connection.responseCode}: $e"
            )
        }
        return null
    }


    /**
     * Set the [taskException] variable based on Exception [e]
     */
    private fun setTaskException(e: Any) {
        var exceptionType = ExceptionType.general
        if (e is FileSystemException || e is IOException) {
            exceptionType = ExceptionType.fileSystem
        }
        if (e is SocketException) {
            exceptionType = ExceptionType.connection
        }
        taskException = TaskException(exceptionType, description = e.toString())
    }
}

/** Return the map of tasks stored in preferences */
fun getTaskMap(prefs: SharedPreferences): MutableMap<String, Any> {
    val jsonString = prefs.getString(
        BackgroundDownloaderPlugin.keyTasksMap, "{}"
    )
    return BackgroundDownloaderPlugin.gson.fromJson<Map<String, Any>>(
        jsonString, BackgroundDownloaderPlugin.jsonMapType
    ).toMutableMap()
}
