@file:Suppress("EnumEntryName")

package com.bbflight.background_downloader

/// Base directory in which files will be stored, based on their relative
/// path.
///
/// These correspond to the directories provided by the path_provider package
enum class BaseDirectory {
    applicationDocuments,  // getApplicationDocumentsDirectory()
    temporary,  // getTemporaryDirectory()
    applicationSupport, // getApplicationSupportDirectory()
    applicationLibrary // getApplicationSupportDirectory() subdir "Library"
}

/// Type of updates requested for a group of tasks
enum class Updates {
    none,  // no status or progress updates
    statusChange, // only calls upon change in DownloadTaskStatus
    progressUpdates, // only calls for progress
    statusChangeAndProgressUpdates // calls also for progress along the way
}

/**
 * The Dart side Task
 *
 * A blend of UploadTask and DownloadTask, with [taskType] indicating what kind
 * of task this is
 */

class Task(
    val taskId: String,
    val url: String,
    val filename: String,
    val headers: Map<String, String>,
    val post: String?,
    val fileField: String,
    val mimeType: String,
    val fields: Map<String, String>,
    val directory: String,
    val baseDirectory: BaseDirectory,
    val group: String,
    val updates: Updates,
    val requiresWiFi: Boolean,
    val retries: Int,
    val retriesRemaining: Int,
    val allowPause: Boolean,
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
        fileField = jsonMap["fileField"] as String? ?: "",
        mimeType = jsonMap["mimeType"] as String? ?: "",
        fields = jsonMap["fields"] as Map<String, String>? ?: mutableMapOf<String, String>(),
        directory = jsonMap["directory"] as String? ?: "",
        baseDirectory = BaseDirectory.values()[(jsonMap["baseDirectory"] as Double?
            ?: 0).toInt()],
        group = jsonMap["group"] as String? ?: "",
        updates = Updates.values()[(jsonMap["updates"] as Double? ?: 0).toInt()],
        requiresWiFi = jsonMap["requiresWiFi"] as Boolean? ?: false,
        retries = (jsonMap["retries"] as Double? ?: 0).toInt(),
        retriesRemaining = (jsonMap["retriesRemaining"] as Double? ?: 0).toInt(),
        allowPause = (jsonMap["allowPause"] as Boolean? ?: false),
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
            "fileField" to fileField,
            "mimeType" to mimeType,
            "fields" to fields,
            "directory" to directory,
            "baseDirectory" to baseDirectory.ordinal, // stored as int
            "group" to group,
            "updates" to updates.ordinal,
            "requiresWiFi" to requiresWiFi,
            "retries" to retries,
            "retriesRemaining" to retriesRemaining,
            "allowPause" to allowPause,
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
    waitingToRetry,
    paused;

    fun isNotFinalState(): Boolean {
        return this == enqueued || this == running || this == waitingToRetry || this == paused
    }

    fun isFinalState(): Boolean {
        return !isNotFinalState()
    }
}

/// Holds data associated with a resume
class ResumeData(val task: Task, val data: String, val requiredStartByte: Long) {
    fun toJsonMap(): MutableMap<String, Any?> {
        return mutableMapOf(
            "task" to task.toJsonMap(),
            "data" to data,
            "requiredStartByte" to requiredStartByte
        )
    }
}
