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
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.preference.PreferenceManager
import androidx.work.CoroutineWorker
import androidx.work.ForegroundInfo
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.bbflight.background_downloader.BDPlugin.Companion.gson
import kotlinx.coroutines.*
import java.io.*
import java.lang.Long.max
import java.lang.System.currentTimeMillis
import java.net.HttpURLConnection
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.SocketException
import java.net.URL
import java.util.*
import kotlin.concurrent.schedule
import kotlin.concurrent.write
import kotlin.math.roundToInt
import java.lang.Double.min as doubleMin


/***
 * The worker to execute one task
 *
 * Processes DownloadTask, UploadTask or MultiUploadTask
 */
open class TaskWorker(
    applicationContext: Context, workerParams: WorkerParameters
) : CoroutineWorker(applicationContext, workerParams) {

    @Suppress("RegExpRedundantEscape")
    companion object {
        const val TAG = "TaskWorker"
        const val chunkGroup = "chunk"
        const val keyTask = "Task"
        const val keyNotificationConfig = "notificationConfig"
        const val keyResumeDataData = "tempFilename"
        const val keyStartByte = "startByte"
        const val keyETag = "eTag"
        const val bufferSize = 2 shl 12

        const val taskTimeoutMillis = 9 * 60 * 1000L  // 9 minutes

        private val displayNameRegEx = Regex("""\{displayName\}""", RegexOption.IGNORE_CASE)
        private val fileNameRegEx = Regex("""\{filename\}""", RegexOption.IGNORE_CASE)
        private val progressRegEx = Regex("""\{progress\}""", RegexOption.IGNORE_CASE)
        private val networkSpeedRegEx = Regex("""\{networkSpeed\}""", RegexOption.IGNORE_CASE)
        private val timeRemainingRegEx = Regex("""\{timeRemaining\}""", RegexOption.IGNORE_CASE)
        private val metaDataRegEx = Regex("""\{metadata\}""", RegexOption.IGNORE_CASE)

        private var createdNotificationChannel = false


        /** Converts [Task] to JSON string representation */
        fun taskToJsonString(task: Task): String {
            return gson.toJson(task.toJsonMap())
        }

        /**
         * Post method message on backgroundChannel with arguments and return true if this was
         * successful
         *
         * [arg] can be single variable or a MutableList
         */
        suspend fun postOnBackgroundChannel(
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
                        if (BDPlugin.backgroundChannel != null) {
                            BDPlugin.backgroundChannel?.invokeMethod(
                                method, argList
                            )
                            if (!BDPlugin.forceFailPostOnBackgroundChannel) {
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
                return@coroutineScope runningOnUIThread || success.await()
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
                        BDPlugin.canceledTaskIds[task.taskId] =
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
                    val jsonMap: MutableMap<String, Any?> = mutableMapOf(
                        Pair("task", task.toJsonMap()),
                        Pair("taskStatus", status.ordinal)
                    )
                    storeLocally(
                        BDPlugin.keyStatusUpdateMap, task.taskId, jsonMap,
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
                            BDPlugin.TAG,
                            "Could not kill task wih id ${task.taskId} in operation: $operation"
                        )
                    }
                }
                BDPlugin.prefsLock.write {
                    val tasksMap = getTaskMap(prefs)
                    tasksMap.remove(task.taskId)
                    val editor = prefs.edit()
                    editor.putString(
                        BDPlugin.keyTasksMap,
                        gson.toJson(tasksMap)
                    )
                    editor.apply()
                }
                BDPlugin.localResumeData.remove(task.taskId)
            }
        }

        /** Return true if we can send a cancellation for this task
         *
         * Cancellation can only be sent if it wasn't already sent by the [BDPlugin]
         *  in the cancelTasksWithId method.  Side effect is to clean out older cancellation entries
         * from the [BDPlugin.canceledTaskIds]
         */
        private fun canSendCancellation(task: Task): Boolean {
            val idsToRemove = ArrayList<String>()
            val now = currentTimeMillis()
            for (entry in BDPlugin.canceledTaskIds) {
                if (now - entry.value > 1000) {
                    idsToRemove.add(entry.key)
                }
            }
            for (taskId in idsToRemove) {
                BDPlugin.canceledTaskIds.remove(taskId)
            }
            return BDPlugin.canceledTaskIds[task.taskId] == null
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
                    val jsonMap: MutableMap<String, Any?> = mutableMapOf(
                        Pair("task", task.toJsonMap()),
                        Pair("progress", progress),
                        Pair("expectedFileSize", expectedFileSize)
                    )
                    storeLocally(
                        BDPlugin.keyProgressUpdateMap, task.taskId, jsonMap,
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
            BDPlugin.localResumeData[resumeData.task.taskId] = resumeData
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
                    BDPlugin.keyResumeDataMap,
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
            BDPlugin.prefsLock.write {
                // add the data to a map keyed by taskId
                val jsonString = prefs.getString(prefsKey, "{}")
                val mapByTaskId = gson.fromJson<Map<String, Any>>(
                    jsonString, BDPlugin.jsonMapType
                ).toMutableMap()
                mapByTaskId[taskId] = item
                val editor = prefs.edit()
                editor.putString(
                    prefsKey, gson.toJson(mapByTaskId)
                )
                editor.apply()
            }
        }

    }

    lateinit var task: Task

    // properties related to pause/resume functionality and progress
    var startByte = 0L // actual starting position within the task range, used for resume
    var bytesTotal = 0L // total bytes read in this download session
    var taskCanResume = false // whether task is able to resume
    var isResume = false // whether task is a resume
    private var bytesTotalAtLastProgressUpdate = 0L
    private var lastProgressUpdateTime = 0L // in millis
    private var lastProgressUpdate = 0.0
    private var nextProgressUpdateTime = 0L
    private var networkSpeed = -1.0 // in MB/s
    private var isTimedOut = false

    // properties related to notifications
    var notificationConfigJsonString: String? = null
    var notificationConfig: NotificationConfig? = null
    private var notificationId = 0
    private var notificationProgress = 2.0 // indeterminate
    private var lastNotificationTime = 0L

    var taskException: TaskException? = null
    var responseBody: String? = null
    private var runInForegroundFileSize: Int = -1
    var canRunInForeground = false
    var runInForeground = false

    lateinit var prefs: SharedPreferences

    /**
     * Worker execution entrypoint
     *
     * The flow for all workers is:
     * > do Work - extracts notification config and determines if resume is possible
     *   > doTask - extracts task details and sets up the general connection
     *     > connectAndProcess - configures the connection and connects, processes errors
     *       > process - processes the connection, eg transfers bytes
     *
     * Subclasses of [TaskWorker] will override some or all of these methods, with most
     * of the work typically done in the process method
     */
    override suspend fun doWork(): Result {
        prefs = PreferenceManager.getDefaultSharedPreferences(applicationContext)
        runInForegroundFileSize =
            prefs.getInt(BDPlugin.keyConfigForegroundFileSize, -1)
        withContext(Dispatchers.IO) {
            Timer().schedule(taskTimeoutMillis) {
                isTimedOut =
                    true // triggers .failed in [TransferBytes] method if not runInForeground
            }
            task = Task(
                gson.fromJson(inputData.getString(keyTask), BDPlugin.jsonMapType)
            )
            notificationConfigJsonString = inputData.getString(keyNotificationConfig)
            notificationConfig =
                if (notificationConfigJsonString != null) gson.fromJson(
                    notificationConfigJsonString, NotificationConfig::class.java
                ) else null
            canRunInForeground = runInForegroundFileSize >= 0 &&
                    notificationConfig?.running != null // must have notification
            isResume = determineIfResume()
            Log.i(
                TAG,
                "${if (isResume) "Resuming" else "Starting"} task with taskId ${task.taskId}"
            )
            processStatusUpdate(task, TaskStatus.running, prefs)
            if (!isResume) {
                processProgressUpdate(task, 0.0, prefs)
            }
            updateNotification(notificationTypeForTaskStatus(TaskStatus.running))
            val status = doTask()
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
                updateNotification(notificationTypeForTaskStatus(status))
            }
        }
        return Result.success()
    }

    /** Return true if resume is possible - defaults to false */
    open fun determineIfResume(): Boolean {
        return false
    }

    /**
     * Do the task
     *
     * Sets up the HTTP client to use, creates the connection (but does not
     * yet connect) and calls [connectAndProcess]
     *
     * Returns the [TaskStatus]
     */
    private suspend fun doTask(): TaskStatus {
        try {
            val urlString = task.url
            val url = URL(urlString)
            val requestTimeoutSeconds =
                prefs.getInt(BDPlugin.keyConfigRequestTimeout, 60)
            val proxyAddress =
                prefs.getString(BDPlugin.keyConfigProxyAddress, null)
            val proxyPort = prefs.getInt(BDPlugin.keyConfigProxyPort, 0)
            val proxy = if (proxyAddress != null && proxyPort != 0) Proxy(
                Proxy.Type.HTTP,
                InetSocketAddress(proxyAddress, proxyPort)
            ) else null
            if (!BDPlugin.haveLoggedProxyMessage) {
                Log.i(
                    TAG,
                    if (proxy == null) "Not using proxy for any task"
                    else "Using proxy $proxyAddress:$proxyPort for all tasks"
                )
                BDPlugin.haveLoggedProxyMessage = true
            }
            with(withContext(Dispatchers.IO) {
                url.openConnection(proxy ?: Proxy.NO_PROXY)
            } as HttpURLConnection) {
                requestMethod = task.httpRequestMethod
                connectTimeout = requestTimeoutSeconds * 1000
                for (header in task.headers) {
                    setRequestProperty(header.key, header.value)
                }
                return connectAndProcess(this)
            }
        } catch (e: Exception) {
            Log.w(
                TAG, "Error for taskId ${task.taskId}: $e\n${e.stackTraceToString()}"
            )
            setTaskException(e)
        }
        return TaskStatus.failed
    }

    /**
     * Further configures the connection and makes the actual request by
     * calling [process], while catching errors
     *
     * Returns the [TaskStatus]
     * */
    open suspend fun connectAndProcess(connection: HttpURLConnection): TaskStatus {
        val filePath = task.filePath(applicationContext) // "" for MultiUploadTask
        try {
            if (task.isDownloadTask() && task.post != null) {
                connection.doOutput = true
                connection.setFixedLengthStreamingMode(task.post!!.length)
                DataOutputStream(connection.outputStream).use { it.writeBytes(task.post) }
            }
            return process(connection, filePath)
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
                    return TaskStatus.canceled
                }

                else -> {
                    Log.w(
                        TAG,
                        "Error for taskId ${task.taskId}: ${e.message}\n${e.stackTraceToString()}"
                    )
                    taskException = TaskException(
                        ExceptionType.general, description =
                        "Error for url ${task.url} and $filePath: ${e.message}"
                    )
                }
            }
        } finally {
            // clean up remaining bytes tracking
            BDPlugin.remainingBytesToDownload.remove(task.taskId)
        }
        return TaskStatus.failed
    }

    /**
     * Process the [task] using the [connection]
     *
     * Returns the [TaskStatus]
     *
     * Overridden by subclasses
     */
    open suspend fun process(
        connection: HttpURLConnection,
        filePath: String
    ): TaskStatus {
        throw NotImplementedError()
    }

    /**
     * Transfer [contentLength] bytes from [inputStream] to [outputStream] and provide
     * progress updates for the [task]
     *
     * Will return [TaskStatus.canceled], [TaskStatus.paused], [TaskStatus.failed],
     * [TaskStatus.complete], or special [TaskStatus.enqueued] which signals the task timed out
     */
    suspend fun transferBytes(
        inputStream: InputStream, outputStream: OutputStream, contentLength: Long, task: Task
    ): TaskStatus {
        val dataBuffer = ByteArray(bufferSize)
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
                                BDPlugin.remainingBytesToDownload[task.taskId]
                            if (remainingBytes != null) {
                                BDPlugin.remainingBytesToDownload[task.taskId] =
                                    remainingBytes - numBytes
                            }
                        }
                        val expectedFileSize = contentLength + startByte
                        val progress = doubleMin(
                            (bytesTotal + startByte).toDouble() / expectedFileSize,
                            0.999
                        )
                        if (contentLength > 0 && shouldSendProgressUpdate(
                                progress,
                                currentTimeMillis()
                            )
                        ) {
                            updateProgressAndNotify(progress, expectedFileSize, task)
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
                        if (BDPlugin.pausedTaskIds.contains(task.taskId)) {
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

    /**
     * Returns true if [currentProgress] > [lastProgressUpdate] + threshold and
     * [now] > [nextProgressUpdateTime]
     */
    open fun shouldSendProgressUpdate(currentProgress: Double, now: Long): Boolean {
        return currentProgress - lastProgressUpdate > 0.02 &&
                now > nextProgressUpdateTime
    }

    /**
     * Calculate network speed and time remaining, then post an update
     * to the Dart side and update the 'running' notification
     *
     * Mst be called at the appropriate frequency, and will update
     * [lastProgressUpdate] and [nextProgressUpdateTime]
     */
    suspend fun updateProgressAndNotify(
        progress: Double,
        expectedFileSize: Long,
        task: Task
    ) {
        val now = currentTimeMillis()
        if (task.isParallelDownloadTask()) {
            // approximate based on aggregate progress
            bytesTotal = (progress * expectedFileSize).toLong()
        }
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
            notificationTypeForTaskStatus(TaskStatus.running),
            progress, timeRemaining
        )
        lastProgressUpdate = progress
        nextProgressUpdateTime = currentTimeMillis() + 500
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
                BDPlugin.notificationChannel, name, importance
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
    suspend fun updateNotification(
        notificationType: NotificationType, progress: Double = 2.0,
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
            applicationContext, BDPlugin.notificationChannel
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
                    if (BDPlugin.requestingNotificationPermission) {
                        return  // don't ask twice
                    }
                    BDPlugin.requestingNotificationPermission = true
                    BDPlugin.activity?.requestPermissions(
                        arrayOf(
                            Manifest.permission.POST_NOTIFICATIONS
                        ), BDPlugin.notificationPermissionRequestCode
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
        val activity = BDPlugin.activity
        if (activity != null) {
            val taskJsonString = gson.toJson(
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
     * Replace special tokens {displayName}, {filename}, {metadata}, {progress}, {networkSpeed},
     * {timeRemaining} with their respective values
     */
    private fun replaceTokens(
        input: String,
        task: Task,
        progress: Double,
        timeRemaining: Long
    ): String {
        // filename and metadata
        val output = displayNameRegEx.replace(fileNameRegEx.replace(metaDataRegEx.replace(input, task.metaData), task.filename), task.displayName)

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
    fun determineRunInForeground(task: Task, contentLength: Long) {
        runInForeground =
            canRunInForeground && contentLength > (runInForegroundFileSize.toLong() shl 20)
        if (runInForeground) {
            Log.i(TAG, "TaskId ${task.taskId} will run in foreground")
        }
    }


    /**
     * Return the response's error content as a String, or null if unable
     */
    fun responseErrorContent(connection: HttpURLConnection): String? {
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
        BDPlugin.keyTasksMap, "{}"
    )
    return gson.fromJson<Map<String, Any>>(
        jsonString, BDPlugin.jsonMapType
    ).toMutableMap()
}
