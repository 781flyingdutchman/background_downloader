package com.bbflight.background_downloader

import android.content.Context
import android.util.Log
import androidx.work.WorkerParameters
import com.bbflight.background_downloader.BDPlugin.Companion.gson
import com.google.gson.reflect.TypeToken
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.util.Locale
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
        Log.wtf(TAG, "connectAndProcess result = $result")
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
                            chunks = createChunks(task, connection.headerFields)
                            Log.wtf(TAG, "chunks length = ${chunks.size}")
                            for (chunk in chunks) {
                                // Ask Dart side to enqueue the child task. Updates related to the child
                                // will be sent to this (parent) task (the child's metaData is the parent taskId).
                                Log.wtf(TAG, "enqueuing ${chunk.task.taskId}")
                                if (!postOnBackgroundChannel(
                                        "enqueueChild",
                                        task,
                                        gson.toJson(chunk.task.toJsonMap())
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
                            Log.i(TAG, "Invalid server response code ${connection.responseCode}")
                            taskException = TaskException(
                                ExceptionType.httpResponse,
                                connection.responseCode,
                                "Invalid server response code ${connection.responseCode}",
                            )
                            parallelTaskStatusUpdateCompleter.complete(TaskStatus.failed)
                        }
                    } else {
                        // resume: reconstruct [chunks] and wait for all chunk tasks to complete.
                        // The Dart side will resume each chunk task, so we just wait for the
                        // completer to complete
                        chunks = gson.fromJson(
                            chunksJsonString,
                            object : TypeToken<List<Chunk>>() {}.type
                        )
                        parallelDownloadContentLength = chunks.fold(0L) {
                            acc, chunk ->  acc + chunk.to - chunk.from + 1
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
                        if (BDPlugin.pausedTaskIds.contains(task.taskId)) {
                            pauseAllChunkTasks()
                            postOnBackgroundChannel("resumeData", task, gson.toJson(chunks.map { it.toJsonMap }))
                            parallelTaskStatusUpdateCompleter.complete(TaskStatus.paused)
                            break
                        }
                        delay(200)
                    }
                }
                // wait for all chunks to finish
                Log.wtf(TAG, "Waiting")
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
    suspend fun chunkStatusUpdate(chunkTaskId: String, status: TaskStatus) {
        val chunk = chunks.firstOrNull { it.task.taskId == chunkTaskId }
            ?: return // chunk is not part of this parent task
        val chunkTask = chunk.task
        Log.wtf(TAG, "Received $status for ${chunkTask.taskId}")
        // first check for fail -> retry
        if (status == TaskStatus.failed && chunkTask.retriesRemaining > 0) {
            chunkTask.retriesRemaining--
            val waitTimeSeconds = 2 shl (min(chunkTask.retries - chunkTask.retriesRemaining - 1, 8))
            Log.i(
                TAG,
                "Chunk task with taskId ${chunkTask.taskId} failed, waiting $waitTimeSeconds seconds before retrying. ${chunkTask.retriesRemaining} retries remaining"
            )
            delay(waitTimeSeconds * 1000L)
            postOnBackgroundChannel(
                "enqueueChild",
                task,
                gson.toJson(chunk.task.toJsonMap())
            )
        } else {
            // no retry
            val newStatusUpdate = updateChunkStatus(chunk, status)
            Log.w(TAG, "New parent status is $newStatusUpdate")
            if (newStatusUpdate != null) {
                when (newStatusUpdate) {
                    TaskStatus.complete -> {
                        val stitchResult = stitchChunks()
                        parallelTaskStatusUpdateCompleter.complete(stitchResult)
                    }

                    TaskStatus.failed -> {
                        taskException =
                            TaskException(ExceptionType.general, -1, "Chunk failed to download")
                        cancelAllChunkTasks()
                        parallelTaskStatusUpdateCompleter.complete(TaskStatus.failed)
                    }

                    TaskStatus.notFound -> {
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
     * task progress) and sends an updatre to the Dart isde and updates the
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
            (previousValue + c.progress) /
                    chunks.size;
        }
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
            gson.toJson(chunks.map { it.task.taskId })
        )
    }

    /**
     * Pause the tasks associated with each chunk
     *
     * Accomplished by sending a json ecoded list of tasks to cancel
     * to the NativeDownloader
     */
    private suspend fun pauseAllChunkTasks() {
        postOnBackgroundChannel("pauseTasks", task, gson.toJson(chunks.map { it.task.toJsonMap() }))
    }

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
                    for (chunk in chunks.sortedBy { it.from }) {
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


    private fun createChunks(
        task: Task,
        headers: MutableMap<String, MutableList<String>>
    ): List<Chunk> {
        val numChunks = task.urls.size * task.chunks
        val contentLength = headers.entries
            .first { it.key == "content-length" || it.key == "Content-Length" }
            .value
            .first().toLong()
        if (contentLength <= 0) {
            throw IllegalStateException("No content length")
        }
        Log.wtf(TAG, "content length = $contentLength")
        parallelDownloadContentLength = contentLength
        try {
            headers.entries
                .first { it.key?.lowercase(Locale.US) == "accept-ranges" && it.value.first() == "bytes" }
        } catch (e: NoSuchElementException) {
            throw IllegalStateException("Server does not support ranges")
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
    }
}

class Chunk( //TODO redo constructor such that it does not store parentTask
    var parentTask: Task,
    val url: String,
    val filename: String,
    val from: Long,
    val to: Long
) {

    val task = Task(
        url = url,
        filename = filename,
        headers = parentTask.headers + mapOf("Range" to "bytes=$from-$to"),
        httpRequestMethod = "GET",
        chunks = 1,
        post = null,
        fileField = "",
        mimeType = "",
        baseDirectory = BaseDirectory.temporary,
        group = TaskWorker.chunkGroup,
        updates = parentTask.updates,
        retries = parentTask.retries,
        retriesRemaining = parentTask.retries,
        requiresWiFi = parentTask.requiresWiFi,
        metaData = gson.toJson(
            mapOf("parentTaskId" to parentTask.taskId, "from" to from, "to" to to)),
        taskType = "DownloadTask"
    )

    val parentTaskId = task.taskId
    var status = TaskStatus.enqueued
    var progress = 0.0

    fun toJsonMap(): Map<String, Any?> {
        return mapOf(
        "parentTaskId" to parentTaskId,
            "url" to url,
            "filename" to filename,
            "from" to from,
            "to" to to,
            "statusUpdate" to st
        )
}
