package com.bbflight.background_downloader

import android.content.Context
import android.util.Log
import androidx.work.WorkerParameters
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.HttpURLConnection
import kotlin.math.absoluteValue
import kotlin.math.min
import kotlin.random.Random

/**
/ A ParallelDownloadTask pings the server to get the content-length of the
/ download, then creates a list of [Chunk]s, each representing a portion
/ of the download.  Each chunk-task has its group set to 'chunk' and
/ has the taskId of the parent ParallelDownloadTask in its
/ [Task.metaData] field.
/ The isolate sends 'enqueue' messages back to the NativeDownloader to
/ start each chunk-task, just like any other download task.
/ Messages with group 'chunk' are intercepted in the NativeDownloader,
/ where the sendPort for the isolate running the parent task is
/ looked up, and the update is sent to the isolate via that sendPort.
/ In the isolate, the update is processed and the new status/progress
/ of the ParallelDownloadTask is determined. If the status/progress has
/ changed, an update is sent and the status is processed (e.g., a complete
/ status triggers the piecing together of the downloaded file from
/ its chunk pieces).
/
/ Similarly, pause and cancel commands are sent to all chunk tasks before
/ updating the status of the parent ParallelDownloadTask
 */
class ParallelDownloadTaskWorker(applicationContext: Context, workerParams: WorkerParameters) :
    TaskWorker(applicationContext, workerParams) {

    private var parallelDownloadContentLength = -1L
    private var chunks: List<Chunk> = mutableListOf()
    private var chunksJsonString = ""
    private var parallelTaskStatusUpdateCompleter = CompletableDeferred<TaskStatus>()
    private var lastTaskStatus = TaskStatus.enqueued

    override fun determineIfResume(): Boolean {
        chunksJsonString = inputData.getString(keyResumeDataData) ?: ""
        return chunksJsonString.isNotEmpty()
    }

    override suspend fun connectAndProcess(connection: HttpURLConnection): TaskStatus {
        BDPlugin.parallelDownloadTaskWorkers[task.taskId] = this
        canRunInForeground = true
        runInForeground = notificationConfig?.running != null
        connection.requestMethod = "HEAD"
        val result = super.connectAndProcess(connection)
        BDPlugin.parallelDownloadTaskWorkers.remove(task.taskId)
        return result
    }

    override suspend fun process(
        connection: HttpURLConnection,
        filePath: String
    ): TaskStatus {
        return withContext(Dispatchers.Default) {
            var enqueueJob: Job? = null
            var testerJob: Job? = null
            try {
                enqueueJob = launch {
                    if (!isResume) {
                        // start the download by creating [Chunk]s and enqueuing chunk tasks
                        if (connection.responseCode in listOf(200, 201, 202, 203, 204, 205, 206)) {
                            // if no filename is set, get from headers or url, update task
                            if (!task.hasFilename()) {
                                task = task.withSuggestedFilenameFromResponseHeaders(
                                    applicationContext,
                                    connection.headerFields,
                                    unique = true
                                )
                                val dirName = File(filePath).parent ?: ""
                                Log.d(TAG, "Suggested filename for taskId ${task.taskId}: ${task.filename}")
                            }
                            extractContentType(connection.headerFields)
                            chunks = createChunks(task, connection.headerFields)
                            for (chunk in chunks) {
                                // Ask Dart side to enqueue the child task. Updates related to the child
                                // will be sent to this (parent) task (the child's metaData is the parent taskId).
                                if (!postOnBackgroundChannel(
                                        "enqueueChild",
                                        task,
                                        Json.encodeToString(chunk.task)
                                    )
                                ) {
                                    // failed to enqueue child
                                    cancelAllChunkTasks()
                                    Log.i(
                                        TAG,
                                        "Failed to enqueue chunk task with id ${chunk.task.taskId}"
                                    )
                                    taskException = TaskException(
                                        ExceptionType.general,
                                        description = "Failed to enqueue chunk task with id ${chunk.task.taskId}"
                                    )
                                    parallelTaskStatusUpdateCompleter.complete(TaskStatus.failed)
                                }
                            }
                        } else {
                            // HTTP response code not OK
                            Log.i(
                                TAG,
                                "Response code ${connection.responseCode} for taskId ${task.taskId}"
                            )
                            val errorContent = responseErrorContent(connection)
                            taskException = TaskException(
                                ExceptionType.httpResponse,
                                httpResponseCode = connection.responseCode,
                                description = if (errorContent?.isNotEmpty() == true) errorContent else connection.responseMessage
                            )
                            if (connection.responseCode == 404) {
                                responseBody = errorContent
                                parallelTaskStatusUpdateCompleter.complete(TaskStatus.notFound)
                            } else {
                                parallelTaskStatusUpdateCompleter.complete(TaskStatus.failed)
                            }
                        }
                    } else {
                        // resume: reconstruct [chunks] and wait for all chunk tasks to complete.
                        // The Dart side will resume each chunk task, so we just wait for the
                        // completer to complete
                        chunks = Json.decodeFromString(chunksJsonString)
                        parallelDownloadContentLength = chunks.fold(0L) { acc, chunk ->
                            acc + chunk.toByte - chunk.fromByte + 1
                        }
                    }
                }
                testerJob = launch {
                    while (isActive) {
                        // check if task is stopped (canceled), paused or timed out
                        if (isStopped) {
                            withContext(NonCancellable) {
                                cancelAllChunkTasks()
                                parallelTaskStatusUpdateCompleter.complete(TaskStatus.failed)
                            }
                            break
                        }
                        // 'pause' is signalled by adding the taskId to a static list
                        if (BDPlugin.pausedTaskIds.remove(task.taskId)) {
                            pauseAllChunkTasks()
                            postOnBackgroundChannel(
                                "resumeData",
                                task,
                                Json.encodeToString(chunks)
                            )
                            parallelTaskStatusUpdateCompleter.complete(TaskStatus.paused)
                            break
                        }
                        delay(200)
                    }
                }
                // wait for all chunks to finish
                return@withContext parallelTaskStatusUpdateCompleter.await()
            } catch (e: Exception) {

                Log.i(TAG, "Exception for taskId ${task.taskId}: $e")
                taskException = TaskException(
                    ExceptionType.general,
                    description = "Exception for taskId ${task.taskId}: $e"
                )
                return@withContext TaskStatus.failed
            } finally {
                enqueueJob?.cancelAndJoin()
                testerJob?.cancelAndJoin()
            }
        }
    }

    /**
     * Process incoming [status] update for a chunk with [chunkTaskId]
     */
    suspend fun chunkStatusUpdate(
        chunkTaskId: String,
        status: TaskStatus,
        taskException: TaskException?,
        responseBody: String?
    ) {
        val chunk = chunks.firstOrNull { it.task.taskId == chunkTaskId }
            ?: return // chunk is not part of this parent task
        val chunkTask = chunk.task
        // first check for fail -> retry
        if (status == TaskStatus.failed && chunkTask.retriesRemaining > 0) {
            chunkTask.retriesRemaining--
            val waitTimeSeconds = 2 shl (min(chunkTask.retries - chunkTask.retriesRemaining - 1, 8))
            Log.i(
                TAG,
                "Chunk task with taskId ${chunkTask.taskId} failed, waiting $waitTimeSeconds seconds before retrying. ${chunkTask.retriesRemaining} retries remaining"
            )
            delay(waitTimeSeconds * 1000L)
            if (!postOnBackgroundChannel(
                    "enqueueChild",
                    task,
                    Json.encodeToString(chunk.task)
                )
            ) {
                chunkStatusUpdate(chunkTaskId, TaskStatus.failed, taskException, responseBody)
            }
        } else {
            // no retry
            val newStatusUpdate = updateChunkStatus(chunk, status)
            if (newStatusUpdate != null) {
                when (newStatusUpdate) {
                    TaskStatus.complete -> {
                        val stitchResult = stitchChunks()
                        parallelTaskStatusUpdateCompleter.complete(stitchResult)
                    }

                    TaskStatus.failed -> {
                        this.taskException = taskException
                        cancelAllChunkTasks()
                        parallelTaskStatusUpdateCompleter.complete(TaskStatus.failed)
                    }

                    TaskStatus.notFound -> {
                        this.taskException = taskException
                        this.responseBody = responseBody
                        cancelAllChunkTasks()
                        parallelTaskStatusUpdateCompleter.complete(TaskStatus.notFound)
                    }

                    else -> {
                        // ignore all other status updates
                    }
                }
            }
        }
    }


    /**
     * Process incoming [progress] update for a chunk with [chunkTaskId].
     *
     * Recalculates overall task progress (based on the average of the chunk
     * task progress) and sends an update to the Dart side and updates the
     * notification at the appropriate interval
     */
    suspend fun chunkProgressUpdate(chunkTaskId: String, progress: Double) {
        val chunk = chunks.firstOrNull { it.task.taskId == chunkTaskId }
            ?: return // chunk is not part of this parent task
        if (progress > 0 && progress < 1) {
            val parentProgress = updateChunkProgress(chunk, progress)
            if (shouldSendProgressUpdate(parentProgress, System.currentTimeMillis())) {
                updateProgressAndNotify(parentProgress, parallelDownloadContentLength, task)
            }
        }
    }

    /**
     * Update the status for this chunk, and return the status for the parent task
     * as derived from the sum of the child tasks, or null if undefined
     *
     * The updates are received from the NativeDownloader, which intercepts
     * status updates for the chunkGroup
     */
    private fun updateChunkStatus(chunk: Chunk, status: TaskStatus): TaskStatus? {
        chunk.status = status
        val parentStatus = parentTaskStatus()
        if (parentStatus != null && parentStatus != lastTaskStatus) {
            lastTaskStatus = parentStatus
            return parentStatus
        }
        return null
    }

    /**
     * Returns the [TaskStatus] for the parent of this chunk, as derived from
     * the 'sum' of the child tasks, or null if undetermined
     *
     * The updates are received from the NativeDownloader, which intercepts
     * status updates for the chunkGroup
     */
    private fun parentTaskStatus(): TaskStatus? {
        val failed = chunks.firstOrNull { it.status == TaskStatus.failed }
        if (failed != null) {
            return TaskStatus.failed
        }

        val notFound = chunks.firstOrNull { it.status == TaskStatus.notFound }
        if (notFound != null) {
            return TaskStatus.notFound
        }

        val allComplete = chunks.all { it.status == TaskStatus.complete }
        if (allComplete) {
            return TaskStatus.complete
        }
        return null
    }


    /**
     * Updates the chunk's progress and returns the average progress
     *
     * Returns the [progress] for the parent of this chunk, as derived from
     * its children by averaging
     */
    private fun updateChunkProgress(chunk: Chunk, progress: Double): Double {
        chunk.progress = progress
        return chunks.fold(
            0.0
        ) { previousValue, c ->
            previousValue + c.progress
        } / chunks.size
    }

    /**
     * Cancel the tasks associated with each chunk
     *
     * Accomplished by sending list of taskIds to cancel to the NativeDownloader
     */
    suspend fun cancelAllChunkTasks() {
        postOnBackgroundChannel(
            "cancelTasksWithId",
            task,
            Json.encodeToString(chunks.map { it.task.taskId })
        )
    }

    /**
     * Pause the tasks associated with each chunk
     *
     * Accomplished by sending a json decoded list of tasks to cancel
     * to the NativeDownloader
     */
    private suspend fun pauseAllChunkTasks() {
        postOnBackgroundChannel("pauseTasks", task, Json.encodeToString(chunks.map { it.task }))
    }

    /**
     * Stitch all chunks together into one file
     */
    private suspend fun stitchChunks(): TaskStatus {
        withContext(Dispatchers.IO) {
            try {
                val dataBuffer = ByteArray(bufferSize)
                var numBytes: Int
                val outFile = File(task.filePath(applicationContext))
                if (outFile.exists()) {
                    outFile.delete()
                }
                FileOutputStream(outFile).use { outStream ->
                    for (chunk in chunks.sortedBy { it.fromByte }) {
                        val inFile = File(chunk.task.filePath(applicationContext))
                        if (!inFile.exists()) {
                            throw FileSystemException(inFile, reason = "Missing chunk file")
                        }
                        FileInputStream(inFile).use { inStream ->
                            while (inStream.read(
                                    dataBuffer, 0,
                                    bufferSize
                                )
                                    .also { numBytes = it } != -1
                            ) {
                                outStream.write(dataBuffer, 0, numBytes)
                            }
                        }
                    }
                    outStream.flush()
                }
            } catch (e: Exception) {
                Log.i(TAG, "Error stitching chunks: $e\n${e.stackTraceToString()}")
                taskException = TaskException(
                    ExceptionType.fileSystem,
                    description = "Error stitching chunks: $e"
                )
                return@withContext TaskStatus.failed
            } finally {
                for (chunk in chunks) {
                    try {
                        val file = File(chunk.task.filePath(applicationContext))
                        file.delete()
                    } catch (e: FileSystemException) {
                        // ignore
                    }
                }
            }
        }
        return TaskStatus.complete
    }


    /**
     * Returns a list of chunk information for this task, and sets
     * [parallelDownloadContentLength] to the total length of the download
     *
     * Throws a IllegalStateException if any information is missing, which should lead
     * to a failure of the ParallelDownloadTask
     */
    private fun createChunks(
        task: Task,
        headers: MutableMap<String, MutableList<String>>
    ): List<Chunk> {
        val numChunks = task.urls.size * task.chunks
        try {
            val contentLength = getContentLength(headers, task)
            if (contentLength <= 0) {
                throw IllegalStateException("Server does not provide content length - cannot chunk download. If you know the length, set Range or Known-Content-Length header")
            }
            parallelDownloadContentLength = contentLength
            try {
                headers.entries
                    .first { (it.key == "accept-ranges" || it.key == "Accept-Ranges") && it.value.first() == "bytes" }
            } catch (e: NoSuchElementException) {
                throw IllegalStateException("Server does not accept ranges - cannot chunk download")
            }
            val chunkSize = (contentLength / numChunks) + 1
            return (0 until numChunks).map { i ->
                Chunk(
                    parentTask = task,
                    url = task.urls[i % task.urls.size],
                    filename = "com.bbflight.background_downloader.${Random.nextInt().absoluteValue}",
                    from = i * chunkSize,
                    to = min(i * chunkSize + chunkSize - 1, contentLength - 1)
                )
            }
        } catch (e: NoSuchElementException) {
            throw IllegalStateException("Server does not provide content length - cannot chunk download. If you know the length, set Range or Known-Content-Length header")
        }
    }
}

@Serializable
class Chunk private constructor(
    private val parentTaskId: String,
    private val url: String,
    private val filename: String,
    val task: Task,
    val fromByte: Long,
    val toByte: Long,
    var status: TaskStatus = TaskStatus.enqueued,
    var progress: Double = 0.0
) {
    companion object {
        /**
         * Returns [Updates] that is based on the [parentTask]
         */
        fun updatesBasedOnParent(parentTask: Task): Updates {
            return when (parentTask.updates) {
                Updates.none, Updates.status -> Updates.status
                Updates.progress, Updates.statusAndProgress -> Updates.statusAndProgress
            }
        }
    }

    /**
     * Constructor that also creates the [Task] associated with this [Chunk]
     */
    constructor(parentTask: Task, url: String, filename: String, from: Long, to: Long) : this(
        parentTaskId = parentTask.taskId,
        url,
        filename,
        task = Task(
            url = url,
            filename = filename,
            headers = parentTask.headers + mapOf("Range" to "bytes=$from-$to"),
            httpRequestMethod = "GET",
            chunks = 1,
            post = null,
            fileField = "",
            mimeType = "",
            baseDirectory = BaseDirectory.applicationDocuments,
            group = TaskWorker.chunkGroup,
            updates = updatesBasedOnParent(parentTask),
            retries = parentTask.retries,
            retriesRemaining = parentTask.retries,
            requiresWiFi = parentTask.requiresWiFi,
            allowPause = parentTask.allowPause,
            priority = parentTask.priority,
            metaData = Json.encodeToString(ChunkTaskMetaData(parentTask.taskId, from, to)),
            taskType = "DownloadTask"
        ),
        from,
        to
    )
}

@Serializable
/// Holder for metaData for [Task] related to a [Chunk]
data class ChunkTaskMetaData(val parentTaskId: String, val from: Long, val to: Long)
