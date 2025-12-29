package com.bbflight.background_downloader

import android.app.Notification
import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import androidx.preference.PreferenceManager
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
import kotlinx.serialization.json.Json
import java.io.DataOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.lang.Double.min as doubleMin
import java.lang.System.currentTimeMillis
import java.net.HttpURLConnection
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.SocketException
import java.net.URL
import kotlin.concurrent.read
import kotlin.concurrent.write
import androidx.core.content.edit

interface TaskServer {
    val applicationContext: Context
    val isStopped: Boolean
    suspend fun makeForeground(notificationId: Int, notification: Notification)
}

/**
 * The executor to execute one task
 *
 * Processes DownloadTask, UploadTask or MultiUploadTask
 */
abstract class TaskExecutor(
    val server: TaskServer,
    var task: Task,
    var notificationConfigJsonString: String?,
    var resumeData: ResumeData? = null
) {
    // companion object constants from TaskWorker moved/duplicated or referenced?
    // We'll reference TaskWorker constants where possible or duplicate if private

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
    var notificationConfig: NotificationConfig? = null
    var notificationId = 0
    var notificationProgress = 2.0 // indeterminate

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

    val applicationContext: Context get() = server.applicationContext
    lateinit var prefs: SharedPreferences

    /**
     * Executor execution entrypoint
     */
    suspend fun run() {
        prefs = PreferenceManager.getDefaultSharedPreferences(applicationContext)
        runInForegroundFileSize =
            prefs.getInt(BDPlugin.keyConfigForegroundFileSize, -1)
        withContext(Dispatchers.IO) {
            CoroutineScope(Dispatchers.Default).launch {
                delay(TaskWorker.taskTimeoutMillis)
                isTimedOut = true
            }
            if (task.options?.hasBeforeStartCallback() == true) {
                val statusUpdate = Callbacks.invokeBeforeTaskStartCallback(applicationContext, task)
                if (statusUpdate != null) {
                    Log.i(
                        TaskWorker.TAG,
                        "TaskId ${task.taskId} interrupted by beforeTaskStart callback"
                    )
                    TaskWorker.processStatusUpdate(
                        task,
                        statusUpdate.taskStatus,
                        prefs,
                        taskException = statusUpdate.exception,
                        responseBody = statusUpdate.responseBody,
                        responseHeaders = statusUpdate.responseHeaders,
                        responseStatusCode = statusUpdate.responseStatusCode,
                        context = applicationContext
                    )
                    BDPlugin.holdingQueue?.taskFinished(task)
                    return@withContext
                }
            }
            task = getModifiedTask(
                context = applicationContext,
                task = task
            )
            notificationConfig =
                if (notificationConfigJsonString != null) Json.decodeFromString(
                    notificationConfigJsonString!!
                ) else null
            canRunInForeground = runInForegroundFileSize >= 0 &&
                    notificationConfig?.running != null // must have notification
            // resume data provided in constructor
            requiredStartByte = resumeData?.requiredStartByte ?: 0L
            isResume = determineIfResume()
            Log.i(
                TaskWorker.TAG,
                "${if (isResume) "Resuming" else "Starting"} task with taskId ${task.taskId}"
            )
            TaskWorker.processStatusUpdate(task, TaskStatus.running, prefs, context = applicationContext)
            if (!isResume) {
                TaskWorker.processProgressUpdate(task, 0.0, prefs)
            }
            NotificationService.updateNotification(this@TaskExecutor, TaskStatus.running)
            val status = doTask()
            withContext(NonCancellable) {
                // NonCancellable to make sure we complete the status and notification
                // updates even if the job is being cancelled
                TaskWorker.processStatusUpdate(
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
                    NotificationService.updateNotification(this@TaskExecutor, status)
                }
                if (status != TaskStatus.canceled) {
                    // let the holdingQueue know this task is no longer active
                    // except TaskStatus.canceled is handled directly in cancellation and reset methods
                    BDPlugin.holdingQueue?.taskFinished(task)
                }
            }
        }
    }

    // Abstract or open methods to be overridden by subclasses

    /** Return true if resume is possible - defaults to false */
    open fun determineIfResume(): Boolean {
        return false
    }

    // Required property for determineIfResume used by DownloadTaskExecutor
    open var requiredStartByte = 0L

    /**
     * Do the task
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
                    TaskWorker.TAG,
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
                    // For UploadTask, copy headers unless it's "Range" or "Content-Disposition".
                    // For other task types, copy all headers.
                    if (!task.isUploadTask() ||
                        (!header.key.equals("Range", ignoreCase = true) &&
                                !header.key.equals("Content-Disposition", ignoreCase = true))
                    ) {
                        setRequestProperty(header.key, header.value)
                    }
                }
                return connectAndProcess(this)
            }
        } catch (e: Exception) {
            Log.w(
                TaskWorker.TAG, "Error for taskId ${task.taskId}: $e\n${e.stackTraceToString()}"
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
        try {
            if ((task.isDownloadTask() || task.isDataTask()) && task.post != null) {
                val bytes = task.post!!.toByteArray()
                connection.doOutput = true
                connection.setFixedLengthStreamingMode(bytes.size)
                DataOutputStream(connection.outputStream).use {
                    it.write(bytes)
                    it.flush()
                }
            }
            return process(connection)
        } catch (e: Exception) {
            setTaskException(e)
            when (e) {
                is FileSystemException -> Log.w(
                    TaskWorker.TAG,
                    "Filesystem exception for taskId ${task.taskId}: ${e.message}"
                )

                is SocketException -> Log.i(
                    TaskWorker.TAG,
                    "Socket exception for taskId ${task.taskId}: ${e.message}"
                )

                is CancellationException -> {
                    if (BDPlugin.cancelUpdateSentForTaskId.contains(task.taskId)) {
                        Log.i(
                            TaskWorker.TAG,
                            "Canceled task with id ${task.taskId}: ${e.message}"
                        )
                        return TaskStatus.canceled
                    } else {
                        Log.i(
                            TaskWorker.TAG,
                            "WorkManager/JobService CancellationException for task with id ${task.taskId} without manual cancellation: failing task"
                        )
                        return TaskStatus.failed
                    }
                }

                else -> {
                    Log.w(
                        TaskWorker.TAG,
                        "Error for taskId ${task.taskId}: ${e.message}\n${e.stackTraceToString()}"
                    )
                    taskException = TaskException(
                        ExceptionType.general, description =
                            "Error for url ${task.url}: ${e.message}"
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
        connection: HttpURLConnection
    ): TaskStatus {
        throw NotImplementedError()
    }

    /**
     * Transfer all bytes from [inputStream] to [outputStream] and provide
     * progress updates for the [task]
     */
    suspend fun transferBytes(
        inputStream: InputStream, outputStream: OutputStream, contentLength: Long, task: Task
    ): TaskStatus {
        val dataBuffer = ByteArray(TaskWorker.bufferSize)
        var numBytes: Int
        return withContext(Dispatchers.Default) {
            var readerJob: Job? = null
            var testerJob: Job? = null
            val doneCompleter = CompletableDeferred<TaskStatus>()
            try {
                readerJob = launch(Dispatchers.IO) {
                    while (inputStream.read(
                            dataBuffer, 0,
                            TaskWorker.bufferSize
                        )
                            .also { numBytes = it } != -1
                    ) {
                        if (!server.isStopped) { // check if stopped via server interface
                            // continue
                        } else {
                             doneCompleter.complete(TaskStatus.failed)
                             break
                        }
                        // double check isActive (coroutine state)
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
                        if (server.isStopped) {
                            // Log logic for stop reason if needed (omitted for simplicity or can implement in Server)
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
                Log.i(TaskWorker.TAG, "Exception for taskId ${task.taskId}: $e")
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
        TaskWorker.processProgressUpdate(
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
            Log.i(TaskWorker.TAG, "TaskId ${task.taskId} will run in foreground")
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
                TaskWorker.TAG,
                "Could not read response error content from httpResponseCode ${connection.responseCode}: $e"
            )
        }
        return null
    }

    /**
     * Set the [taskException] variable based on Exception [e]
     */
    fun setTaskException(e: Any) {
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
     */
    fun extractResponseHeaders(headers: MutableMap<String, MutableList<String>>) {
        responseHeaders = headers.mapValues { it.value.joinToString() }
    }
}
