package com.bbflight.background_downloader

import kotlinx.serialization.InternalSerializationApi
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

@Suppress("unused")
@OptIn(InternalSerializationApi::class)
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
@OptIn(InternalSerializationApi::class)
/// Holder for metaData for [Task] related to a [Chunk]
data class ChunkTaskMetaData(val parentTaskId: String, val from: Long, val to: Long)
