package com.bbflight.background_downloader

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import androidx.preference.PreferenceManager
import androidx.work.CoroutineWorker
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.bbflight.background_downloader.TaskWorker.Companion.TAG
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.DataOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.lang.System.currentTimeMillis
import java.net.HttpURLConnection
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.SocketException
import java.net.URL
import kotlin.concurrent.write
import java.lang.Double.min as doubleMin


/***
 * The worker to execute one task
 *
 * Processes DownloadTask, UploadTask or MultiUploadTask
 */
@Suppress("ConstPropertyName")
open class TaskWorker(
    applicationContext: Context, workerParams: WorkerParameters
) : CoroutineWorker(applicationContext, workerParams) {

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

        /** Converts [Task] to JSON string representation */
        fun taskToJsonString(task: Task): String {
            return Json.encodeToString(task)
        }

        /**
         * Post method message on backgroundChannel with arguments
         *
         * If the post is not successful, execute the [onFail] block, if given
         *
         * [arg] can be single variable or a MutableList
         */
        suspend fun postOnBackgroundChannel(
            method: String, task: Task, arg: Any, onFail: (suspend () -> Unit)? = null
        ) {
            val bgPost = BackgroundPost(task, method, arg, onFail)
            QueueService.postOnBackgroundChannel(bgPost)
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
            responseHeaders: Map<String, String>? = null,
            responseStatusCode: Int? = null,
            mimeType: String? = null,
            charSet: String? = null,
            context: Context
        ) {
            // Intercept status updates resulting from re-enqueue request, which
            // themselves are triggered by a change in WiFi requirement
            if (BDPlugin.tasksToReEnqueue.remove(task)) {
                if (status == TaskStatus.paused || status == TaskStatus.canceled || status == TaskStatus.failed) {
                    WiFi.reEnqueue(
                        EnqueueItem(
                            context,
                            task,
                            BDPlugin.notificationConfigJsonStrings[task.taskId],
                            BDPlugin.localResumeData[task.taskId]
                        )
                    )
                    if (BDPlugin.tasksToReEnqueue.isEmpty()) {
                        WiFi.reEnqueue(null) // signal end of batch
                    }
                    return
                }
                if (BDPlugin.tasksToReEnqueue.isEmpty()) {
                    WiFi.reEnqueue(null) // signal end of batch
                }
            }

            // Normal status update

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

            val taskStatusUpdate =
                if (status.isFinalState()) {  // last update gets all data
                    TaskStatusUpdate(
                        task = task,
                        taskStatus = status,
                        exception = if (status == TaskStatus.failed) taskException
                            ?: TaskException(ExceptionType.general) else null,
                        responseBody = responseBody,
                        responseStatusCode = if (status == TaskStatus.complete || status == TaskStatus.notFound) responseStatusCode else null,
                        responseHeaders = responseHeaders?.filterNotNull()
                            ?.mapKeys { it.key.lowercase() },
                        mimeType = mimeType,
                        charSet = charSet
                    )
                } else TaskStatusUpdate(  // interim updates are limited
                    task = task,
                    taskStatus = status,
                    exception = null,
                    responseBody = null,
                    responseStatusCode = null,
                    responseHeaders = null,
                    mimeType = null,
                    charSet = null
                )

            // Post update if task expects one, or if failed and retry is needed
            if (canSendStatusUpdate && (task.providesStatusUpdates() || retryNeeded)) {
                val arg = taskStatusUpdate.argList
                postOnBackgroundChannel("statusUpdate", task, arg, onFail = {
                    // unsuccessful post, so store in local prefs
                    Log.d(TAG, "Could not post status update -> storing locally")
                    storeLocally(
                        BDPlugin.keyStatusUpdateMap,
                        task.taskId,
                        Json.encodeToString(taskStatusUpdate),
                        prefs
                    )
                })
            }
            // if task is in final state, cancel the WorkManager job (if failed),
            // remove task from persistent storage, clean up references to taskId
            // and invoke the onTaskFinishedCallback if necessary
            if (status.isFinalState()) {
                if (status == TaskStatus.failed) {
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
                        Json.encodeToString(tasksMap)
                    )
                    editor.apply()
                }
                QueueService.cleanupTaskId(task.taskId)
                if (task.options?.hasFinishCallback() == true) {
                    Callbacks.invokeOnTaskFinishedCallback(context, taskStatusUpdate)
                }
            }
        }

        /** Return true if we can send a cancellation for this task
         *
         * Cancellation can only be sent if it wasn't already sent by the [BDPlugin]
         *  in the cancelTasksWithId method.  Side effect is to clean out older cancellation entries
         * from the [BDPlugin.canceledTaskIds]
         */
        private fun canSendCancellation(task: Task): Boolean {
            val now = currentTimeMillis()
            BDPlugin.canceledTaskIds =
                BDPlugin.canceledTaskIds.filter { now - it.value < 1000 } as MutableMap
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
                postOnBackgroundChannel("progressUpdate", task,
                    mutableListOf(progress, expectedFileSize, downloadSpeed, timeRemaining),
                    onFail =
                    {
                        // unsuccessful post, so store in local prefs
                        Log.d(TAG, "Could not post progress update -> storing locally")
                        storeLocally(
                            BDPlugin.keyProgressUpdateMap,
                            task.taskId,
                            Json.encodeToString(
                                TaskProgressUpdate(
                                    task,
                                    progress,
                                    expectedFileSize
                                )
                            ),
                            prefs
                        )
                    })
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
            postOnBackgroundChannel(
                "resumeData", resumeData.task, mutableListOf(
                    resumeData.data,
                    resumeData.requiredStartByte,
                    resumeData.eTag
                ), onFail =
                {
                    // unsuccessful post, so store in local prefs
                    Log.d(TAG, "Could not post resume data -> storing locally")
                    storeLocally(
                        BDPlugin.keyResumeDataMap,
                        resumeData.task.taskId,
                        Json.encodeToString(resumeData),
                        prefs
                    )
                })
        }

        /**
         * Store the [item] in preferences under [prefsKey], keyed by [taskId]
         */
        private fun storeLocally(
            prefsKey: String,
            taskId: String,
            item: String,
            prefs: SharedPreferences
        ) {
            BDPlugin.prefsLock.write {
                // add the data to a map keyed by taskId
                val jsonString = prefs.getString(prefsKey, "{}") as String
                val mapByTaskId = Json.decodeFromString<MutableMap<String, String>>(jsonString)
                mapByTaskId[taskId] = item
                val editor = prefs.edit()
                editor.putString(
                    prefsKey, Json.encodeToString(mapByTaskId)
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
    var networkSpeed = -1.0 // in MB/s
    private var isTimedOut = false

    // properties related to notifications
    var notificationConfigJsonString: String? = null
    var notificationConfig: NotificationConfig? = null
    var notificationId = 0
    var notificationProgress = 2.0 // indeterminate
    var lastNotificationTime = 0L

    // additional parameters for final TaskStatusUpdate
    var taskException: TaskException? = null
    var responseBody: String? = null
    private var responseHeaders: Map<String, String>? = null
    var responseStatusCode: Int? = null
    private var mimeType: String? = null // derived from Content-Type header
    private var charSet: String? = null // derived from Content-Type header

    // related to foreground tasks
    private var runInForegroundFileSize: Int = -1
    var canRunInForeground = false
    var runInForeground = false
    private var hasDeliveredResult = false
    val isActive: Boolean
        get() = !hasDeliveredResult && !isStopped

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
            CoroutineScope(Dispatchers.Default).launch {
                delay(taskTimeoutMillis)
                isTimedOut = true
            }
            task = getModifiedTask(
                context = applicationContext,
                task = Json.decodeFromString(inputData.getString(keyTask)!!)
            )
            notificationConfigJsonString = inputData.getString(keyNotificationConfig)
            notificationConfig =
                if (notificationConfigJsonString != null) Json.decodeFromString(
                    notificationConfigJsonString!!
                ) else null
            canRunInForeground = runInForegroundFileSize >= 0 &&
                    notificationConfig?.running != null // must have notification
            isResume = determineIfResume()
            Log.i(
                TAG,
                "${if (isResume) "Resuming" else "Starting"} task with taskId ${task.taskId}"
            )
            processStatusUpdate(task, TaskStatus.running, prefs, context = applicationContext)
            if (!isResume) {
                processProgressUpdate(task, 0.0, prefs)
            }
            NotificationService.updateNotification(this@TaskWorker, TaskStatus.running)
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
                    responseHeaders,
                    responseStatusCode,
                    mimeType,
                    charSet,
                    applicationContext
                )
                if (status != TaskStatus.failed || task.retriesRemaining == 0) {
                    // update only if not failed, or no retries remaining
                    NotificationService.updateNotification(this@TaskWorker, status)
                }
                if (status != TaskStatus.canceled) {
                    // let the holdingQueue know this task is no longer active
                    // except TaskStatus.canceled is handled directly in cancellation and reset methods
                    BDPlugin.holdingQueue?.taskFinished(task)
                }
            }
        }
        hasDeliveredResult = true
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
                    // copy headers unless Range header in UploadTask
                    if (header.key != "Range" || task.taskType != "UploadTask") {
                        setRequestProperty(header.key, header.value)
                    }
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
            if ((task.isDownloadTask() || task.isDataTask()) && task.post != null) {
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
                    if (BDPlugin.canceledTaskIds.contains(task.taskId)) {
                        Log.i(
                            TAG,
                            "Canceled task with id ${task.taskId}: ${e.message}"
                        )
                        return TaskStatus.canceled
                    } else {
                        Log.i(
                            TAG,
                            "WorkManager CancellationException for task with id ${task.taskId} without manual cancellation: failing task"
                        )
                        return TaskStatus.failed
                    }
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
     * Returns true if [currentProgress] > [lastProgressUpdate] + 2% and
     * [now] > [nextProgressUpdateTime], or if there was progress and
     * [now] > [nextProgressUpdateTime] + 2 seconds
     */
    open fun shouldSendProgressUpdate(currentProgress: Double, now: Long): Boolean {
        return (currentProgress - lastProgressUpdate > 0.02 &&
                now > nextProgressUpdateTime) || (currentProgress > lastProgressUpdate &&
                now > nextProgressUpdateTime + 2000)
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
        NotificationService.updateNotification(
            this,
            TaskStatus.running,
            progress, timeRemaining
        )
        lastProgressUpdate = progress
        nextProgressUpdateTime = currentTimeMillis() + 500
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

    /**
     * Extract content type from [headers] and set [mimeType] and [charSet]
     */
    fun extractContentType(headers: MutableMap<String, MutableList<String>>) {
        val contentType = headers["content-type"]?.first()
        if (contentType != null) {
            val regEx = Regex("""(.*);\s*charset\s*=(.*)""")
            val match = regEx.find(contentType)
            if (match != null) {
                mimeType = match.groups[1]?.value
                charSet = match.groups[2]?.value
            } else {
                mimeType = contentType
            }
        }
    }

    /**
     * Extract headers from response [headers] and store in [responseHeaders]
     *
     * Required because the headers object has a List<String> for each key,
     * whereas the Dart convention separates values under the same key by
     * concatenating them, separated by a comma and a space.
     *
     * This method sets the global responseHeaders field based on the Dart
     * convention.
     */
    fun extractResponseHeaders(headers: MutableMap<String, MutableList<String>>) {
        responseHeaders = headers.mapValues { it.value.joinToString() }
    }
}

/** Return the map of tasks stored in preferences */
fun getTaskMap(prefs: SharedPreferences): MutableMap<String, Task> {
    val tasksMapJson = prefs.getString(BDPlugin.keyTasksMap, "{}") ?: "{}"
    return Json.decodeFromString(tasksMapJson)
}

/**
 * Returns a [task] that may be modified through callbacks
 *
 * Callbacks would be attached to the task via its [Task.options] property, and if
 * present will be invoked by starting a taskDispatcher on a background isolate, then
 * sending the callback request via the MethodChannel
 *
 * First test is for auth refresh (the onAuth callback), then the onStart callback. Both
 * callbacks run in a Dart isolate, and may return a modified task, which will be used
 * for the actual task execution
 */
suspend fun getModifiedTask(context: Context, task: Task): Task {
    var authTask: Task? = null
    val auth = task.options?.auth
    if (auth != null) {
        // Refresh token if needed
        if (auth.isTokenExpired() && auth.hasOnAuthCallback()) {
            Log.i(TAG, "onAuth callback for taskId ${task.taskId}")
            authTask = withContext(Dispatchers.IO) {
                Callbacks.invokeOnAuthCallback(context, task)
            }
        }
        authTask = authTask ?: task // Either original or newly authorized
        val newAuth = authTask.options?.auth ?: return authTask
        // Insert query parameters and headers
        val uri = newAuth.addOrUpdateQueryParams(
            url = authTask.url,
            queryParams = newAuth.getExpandedAccessQueryParams()
        )
        val headers =
            authTask.headers.toMutableMap().apply { putAll(newAuth.getExpandedAccessHeaders()) }
        authTask = authTask.copyWith(url = uri.toString(), headers = headers)
    }
    authTask = authTask ?: task
    if (task.options?.hasStartCallback() != true) {
        return authTask
    }
    // onStart callback
    Log.i(TAG, "onTaskStart callback for taskId ${authTask.taskId}")
    val modifiedTask = withContext(Dispatchers.IO) {
        Callbacks.invokeOnTaskStartCallback(context, authTask)
    }
    return modifiedTask ?: authTask
}
