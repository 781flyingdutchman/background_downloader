@file:Suppress("EnumEntryName")

package com.bbflight.background_downloader

import android.content.Context
import android.os.Build
import kotlin.io.path.Path
import kotlin.io.path.pathString

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
    val httpRequestMethod: String,
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
        httpRequestMethod = jsonMap["httpRequestMethod"] as String? ?: "GET",
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
            "httpRequestMethod" to httpRequestMethod,
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

    /**
     * Returns full path (String) to the file to be downloaded
     */
    fun filePath(context: Context): String {
        if (Build.VERSION.SDK_INT >= 26) {
            val baseDirPath = when (baseDirectory) {
                BaseDirectory.applicationDocuments -> Path(
                    context.dataDir.path, "app_flutter"
                ).pathString

                BaseDirectory.temporary -> context.cacheDir.path
                BaseDirectory.applicationSupport -> context.filesDir.path
                BaseDirectory.applicationLibrary -> Path(
                    context.filesDir.path, "Library"
                ).pathString
            }
            val path = Path(baseDirPath, directory)
            return Path(path.pathString, filename).pathString
        } else {
            val baseDirPath = when (baseDirectory) {
                BaseDirectory.applicationDocuments -> "${context.dataDir.path}/app_flutter"
                BaseDirectory.temporary -> context.cacheDir.path
                BaseDirectory.applicationSupport -> context.filesDir.path
                BaseDirectory.applicationLibrary -> "${context.filesDir.path}/Library"
            }
            return if (directory.isEmpty()) "$baseDirPath/${filename}" else
                "$baseDirPath/${directory}/${filename}"
        }
    }

    override fun toString(): String {
        return "Task(taskId='$taskId', url='$url', filename='$filename', headers=$headers, httpRequestMethod=$httpRequestMethod, post=$post, fileField='$fileField', mimeType='$mimeType', fields=$fields, directory='$directory', baseDirectory=$baseDirectory, group='$group', updates=$updates, requiresWiFi=$requiresWiFi, retries=$retries, retriesRemaining=$retriesRemaining, allowPause=$allowPause, metaData='$metaData', creationTime=$creationTime, taskType='$taskType')"
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


/**
 * The type of a [TaskException]
 *
 * Exceptions are handled differently on the Kotlin side because they are only a vehicle to message
 * to the Flutter side. An exception class hierarchy is therefore not required in Kotlin, and the
 * single [TaskException] class has a field for the [TaskException.type] of exception, as well as all possible
 * exception fields.
 * The [TaskException.type] (as a String using the enum's [ExceptionType.typeString]) is used on the
 * Flutter side to create the approrpriate Exception subclass.
 */
enum class ExceptionType(val typeString: String) {
    /// General error
    general("TaskException"),

    /// Could not save or find file, or create directory
    fileSystem("TaskFileSystemException"),

    /// URL incorrect
    url("TaskUrlException"),

    /// Connection problem, eg host not found, timeout
    connection("TaskConnectionException"),

    /// Could not resume or pause task
    resume("TaskResumeException"),

    /// Invalid HTTP response
    httpResponse("TaskHttpException")
}

/**
 * Contains error information associated with a failed [Task]
 *
 * The [type] categorizes the exception, used to create the appropriate subclass on the Flutter side
 * The [httpResponseCode] is only valid if >0 and may offer details about the
 * nature of the error
 * The [description] is typically taken from the platform-generated
 * error message, or from the plugin. The localization is undefined
 */
class TaskException(
    val type: ExceptionType,
    val httpResponseCode: Int = -1,
    val description: String = ""
)
