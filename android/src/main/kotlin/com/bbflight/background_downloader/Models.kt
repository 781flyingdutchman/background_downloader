@file:Suppress("EnumEntryName")

package com.bbflight.background_downloader

import android.content.Context
import android.net.Uri
import android.util.Log
import com.bbflight.background_downloader.TaskWorker.Companion.TAG
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.Json
import java.io.File
import java.net.URLDecoder
import kotlin.math.absoluteValue
import kotlin.random.Random


/// Base directory in which files will be stored, based on their relative
/// path.
///
/// These correspond to the directories provided by the path_provider package
@Serializable(with = BaseDirectorySerializer::class)
enum class BaseDirectory {
    applicationDocuments,  // getApplicationDocumentsDirectory()
    temporary,  // getTemporaryDirectory()
    applicationSupport, // getApplicationSupportDirectory()
    applicationLibrary, // getApplicationSupportDirectory() subdir "Library"
    root // system root directory
}

private class BaseDirectorySerializer: EnumAsIntSerializer<BaseDirectory>(
    "BaseDirectory",
    { it.ordinal },
    { v -> BaseDirectory.entries.first { it.ordinal == v } }
)

/// Type of updates requested for a group of tasks
@Serializable(with = UpdatesSerializer::class)
enum class Updates {
    none,  // no status or progress updates
    status, // only calls upon change in DownloadTaskStatus
    progress, // only calls for progress
    statusAndProgress // calls also for progress along the way
}

private class UpdatesSerializer: EnumAsIntSerializer<Updates>(
    "Updates",
    { it.ordinal },
    { v -> Updates.entries.first { it.ordinal == v } }
)

/**
 * The Dart side Task
 *
 * A blend of UploadTask, DownloadTask and ParallelDownloadTask with [taskType] indicating what kind
 * of task this is
 */
@Suppress("SameParameterValue")
@Serializable
class Task(
    val taskId: String = "${Random.nextInt().absoluteValue}",
    val url: String,
    val urls: List<String> = listOf(),
    val filename: String,
    val headers: Map<String, String>,
    val httpRequestMethod: String = "GET",
    val chunks: Int = 1,
    val post: String? = null,
    val fileField: String = "",
    val mimeType: String = "",
    val fields: Map<String, String> = mapOf(),
    private val directory: String = "",
    val baseDirectory: BaseDirectory,
    val group: String,
    val updates: Updates,
    val requiresWiFi: Boolean = false,
    val retries: Int = 0,
    var retriesRemaining: Int = 0,
    val allowPause: Boolean = false,
    val priority: Int = 5,
    val metaData: String = "",
    val displayName: String = "",
    private val creationTime: Long = System.currentTimeMillis(), // untouched, so kept as integer on Android side
    val taskType: String
) {

    /**
     * Returns a copy of the [Task] with optional changes to specific fields
     */
    private fun copyWith(
        taskId: String? = null,
        url: String? = null,
        urls: List<String>? = null,
        filename: String? = null,
        headers: Map<String, String>? = null,
        httpRequestMethod: String? = null,
        chunks: Int? = null,
        post: String? = null,
        fileField: String? = null,
        mimeType: String? = null,
        fields: Map<String, String>? = null,
        directory: String? = null,
        baseDirectory: BaseDirectory? = null,
        group: String? = null,
        updates: Updates? = null,
        requiresWiFi: Boolean? = null,
        retries: Int? = null,
        retriesRemaining: Int? = null,
        allowPause: Boolean? = null,
        priority: Int? = null,
        metaData: String? = null,
        displayName: String? = null,
        creationTime: Long? = null,
        taskType: String? = null
    ): Task {
        return Task(
            taskId = taskId ?: this.taskId,
            url = url ?: this.url,
            urls = urls ?: this.urls,
            filename = filename ?: this.filename,
            headers = headers ?: this.headers,
            httpRequestMethod = httpRequestMethod ?: this.httpRequestMethod,
            chunks = chunks ?: this.chunks,
            post = post ?: this.post,
            fileField = fileField ?: this.fileField,
            mimeType = mimeType ?: this.mimeType,
            fields = fields ?: this.fields,
            directory = directory ?: this.directory,
            baseDirectory = baseDirectory ?: this.baseDirectory,
            group = group ?: this.group,
            updates = updates ?: this.updates,
            requiresWiFi = requiresWiFi ?: this.requiresWiFi,
            retries = retries ?: this.retries,
            retriesRemaining = retriesRemaining ?: this.retriesRemaining,
            allowPause = allowPause ?: this.allowPause,
            priority = priority ?: this.priority,
            metaData = metaData ?: this.metaData,
            displayName = displayName ?: this.displayName,
            creationTime = creationTime ?: this.creationTime,
            taskType = taskType ?: this.taskType
        )
    }

    /** True if this task expects to provide progress updates */
    fun providesProgressUpdates(): Boolean {
        return updates == Updates.progress ||
                updates == Updates.statusAndProgress
    }

    /** True if this task expects to provide status updates */
    fun providesStatusUpdates(): Boolean {
        return updates == Updates.status ||
                updates == Updates.statusAndProgress
    }

    /** True if this task is a DownloadTask or ParallelDownloadTask */
    fun isDownloadTask(): Boolean {
        return taskType == "DownloadTask" || taskType == "ParallelDownloadTask"
    }

    /** True if this task is a ParallelDownloadTask */
    fun isParallelDownloadTask(): Boolean {
        return taskType == "ParallelDownloadTask"
    }

    /** True if this task is a MultiUploadTask */
    private fun isMultiUploadTask(): Boolean {
        return taskType == "MultiUploadTask"
    }

    /**
     * Returns full path (String) to the file,
     * based on [withFilename] or the [Task.filename] (default)
     *
     * If the task is a MultiUploadTask and no [withFilename] is given,
     * returns the empty string, as there is no single path that can be
     * returned.
     */
    fun filePath(context: Context, withFilename: String? = null): String {
        if (isMultiUploadTask() && withFilename == null) {
            return ""
        }
        val filenameToUse = withFilename ?: filename
        val baseDirPath = baseDirPath(context, baseDirectory)
            ?: throw IllegalStateException("External storage is requested but not available")
        return if (directory.isEmpty()) "$baseDirPath/${filenameToUse}" else
            "$baseDirPath/${directory}/${filenameToUse}"
    }

    /**
     * Returns a copy of the task with the [Task.filename] property changed
     * to the filename suggested by the server, or derived from the url, or
     * unchanged.
     *
     * If [unique] is true, the filename is guaranteed not to already exist. This
     * is accomplished by adding a suffix to the suggested filename with a number,
     * e.g. "data (2).txt"
     *
     * The server-suggested filename is obtained from the  [responseHeaders] entry
     * "Content-Disposition"
     */
    suspend fun withSuggestedFilenameFromResponseHeaders(
        context: Context,
        responseHeaders: MutableMap<String, MutableList<String>>,
        unique: Boolean = false
    ): Task {
        // Returns [Task] with a filename similar to the one
        // supplied, but unused.
        //
        // If [unique], filename will sequence up in "filename (8).txt" format,
        // otherwise returns the [task]
        fun uniqueFilename(task: Task, unique: Boolean): Task {
            if (!unique) {
                return task
            }
            val sequenceRegEx = Regex("""\((\d+)\)\.?[^.]*$""")
            val extensionRegEx = Regex("""\.[^.]*$""")
            var newTask = task
            var filePath = task.filePath(context)
            var exists = File(filePath).exists()
            while (exists) {
                val extension = extensionRegEx.find(newTask.filename)?.value ?: ""
                val match = sequenceRegEx.find(newTask.filename)
                val newSequence = (match?.groupValues?.get(1)?.toIntOrNull() ?: 0) + 1
                val newFilename = when (match) {
                    null -> "${getBasenameWithoutExtension(File(newTask.filename))} ($newSequence)$extension"
                    else -> "${
                        newTask.filename.substring(
                            0,
                            match.range.first - 1
                        )
                    } ($newSequence)$extension"
                }
                newTask = newTask.copyWith(filename = newFilename)
                filePath = newTask.filePath(context)
                exists = File(filePath).exists()
            }
            return newTask
        }

        // start of main method
        try {
            val disposition = (responseHeaders["Content-Disposition"]
                ?: responseHeaders["content-disposition"])?.get(0)
            if (disposition != null) {
                // Try filename*=UTF-8'language'"encodedFilename"
                val encodedFilenameRegEx =
                    Regex("""filename\*=\s*([^']+)'([^']*)'"?([^"]+)"?""", RegexOption.IGNORE_CASE)
                var match = encodedFilenameRegEx.find(disposition)
                if (match != null && match.groupValues[1].isNotEmpty() && match.groupValues[3].isNotEmpty()) {
                    try {
                        val suggestedFilename = if (match.groupValues[1].uppercase() == "UTF-8") {
                            withContext(Dispatchers.IO) {
                                URLDecoder.decode(match!!.groupValues[3], "UTF-8")
                            }
                        } else {
                            match.groupValues[3]
                        }
                        return uniqueFilename(this.copyWith(filename = suggestedFilename), true)
                    } catch (e: IllegalArgumentException) {
                        Log.d(
                            TAG,
                            "Could not interpret suggested filename (UTF-8 url encoded) ${match.groupValues[3]}"
                        )
                    }
                }
                // Try filename="filename"
                val plainFilenameRegEx =
                    Regex("""filename=\s*"?([^"]+)"?.*$""", RegexOption.IGNORE_CASE)
                match = plainFilenameRegEx.find(disposition)
                if (match != null && match.groupValues[1].isNotEmpty()) {
                    return uniqueFilename(this.copyWith(filename = match.groupValues[1]), unique)
                }
            }
        } catch (_: Throwable) {
        }
        Log.d(TAG, "Could not determine suggested filename from server")
        // Try filename derived from last path segment of the url
        try {
            val uri = Uri.parse(url)
            val suggestedFilename = uri.lastPathSegment
            if (suggestedFilename != null) {
                return uniqueFilename(this.copyWith(filename = suggestedFilename), unique)
            }
        } catch (_: Throwable) {
        }
        Log.d(TAG, "Could not parse URL pathSegment for suggested filename")
        // if everything fails, return the task with unchanged filename
        // except for possibly making it unique
        return uniqueFilename(this, unique)
    }

    /**
     * Returns a list of fileData elements, one for each file to upload.
     * Each element is a triple containing fileField, full filePath, mimeType
     *
     * The lists are stored in the similarly named String fields as a JSON list,
     * with each list the same length. For the filenames list, if a filename refers
     * to a file that exists (i.e. it is a full path) then that is the filePath used,
     * otherwise the filename is appended to the [Task.baseDirectory] and [Task.directory]
     * to form a full file path
     */
    fun extractFilesData(context: Context): List<Triple<String, String, String>> {
        val fileFields = Json.decodeFromString<List<String>>(fileField)
        val filenames = Json.decodeFromString<List<String>>(filename)
        val mimeTypes = Json.decodeFromString<List<String>>(mimeType)
        val result = ArrayList<Triple<String, String, String>>()
        for (i in fileFields.indices) {
            if (File(filenames[i]).exists()) {
                result.add(Triple(fileFields[i], filenames[i], mimeTypes[i]))
            } else {
                result.add(
                    Triple(
                        fileFields[i],
                        filePath(context, withFilename = filenames[i]),
                        mimeTypes[i]
                    )
                )
            }
        }
        return result
    }

    fun hasFilename() = filename != "?"

    override fun toString(): String {
        return "Task(taskId='$taskId', url='$url', filename='$filename', headers=$headers, httpRequestMethod=$httpRequestMethod, post=$post, fileField='$fileField', mimeType='$mimeType', fields=$fields, directory='$directory', baseDirectory=$baseDirectory, group='$group', updates=$updates, requiresWiFi=$requiresWiFi, retries=$retries, retriesRemaining=$retriesRemaining, allowPause=$allowPause, metaData='$metaData', creationTime=$creationTime, taskType='$taskType')"
    }

    /**
     * An equality test on a [Task] is a test on the [taskId] only
     */
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (javaClass != other?.javaClass) return false

        other as Task

        return taskId == other.taskId
    }

    override fun hashCode(): Int {
        return taskId.hashCode()
    }


}

/** Defines a set of possible states which a [Task] can be in.
 *
 * Must match the Dart equivalent enum, as value are passed as ordinal/index integer
 */
@Serializable(with = TaskStatusSerializer::class)
enum class TaskStatus {
    enqueued,
    running,
    complete,
    notFound,
    failed,
    canceled,
    waitingToRetry,
    paused;

    private fun isNotFinalState(): Boolean {
        return this == enqueued || this == running || this == waitingToRetry || this == paused
    }

    fun isFinalState(): Boolean {
        return !isNotFinalState()
    }
}

private class TaskStatusSerializer: EnumAsIntSerializer<TaskStatus>(
    "TaskStatus",
    { it.ordinal },
    { v -> TaskStatus.entries.first { it.ordinal == v } }
)

@Serializable
/** Holds data associated with a task status update, for local storage */
data class TaskStatusUpdate(val task: Task, val taskStatus: TaskStatus)

@Serializable
/** Holds data associated with a task progress update, for local storage */
data class TaskProgressUpdate(val task: Task, val progress: Double, val expectedFileSize: Long)

/// Holds data associated with a resume
@Serializable
data class ResumeData(val task: Task, val data: String, val requiredStartByte: Long, val eTag: String?)

/**
 * The type of a [TaskException]
 *
 * Exceptions are handled differently on the Kotlin side because they are only a vehicle to message
 * to the Flutter side. An exception class hierarchy is therefore not required in Kotlin, and the
 * single [TaskException] class has a field for the [TaskException.type] of exception, as well as all possible
 * exception fields.
 * The [TaskException.type] (as a String using the enum's [ExceptionType.typeString]) is used on the
 * Flutter side to create the appropriate Exception subclass.
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
) {
    constructor(jsonMap: Map<String, Any?>) : this(
        type = when (jsonMap["type"] as String) {
            "TaskFileSystemException" -> ExceptionType.fileSystem
            "TaskUrlException" -> ExceptionType.url
            "TaskConnectionException" -> ExceptionType.connection
            "TaskResumeException" -> ExceptionType.resume
            "TaskHttpException" -> ExceptionType.httpResponse

            else -> ExceptionType.general
        }, httpResponseCode = (jsonMap["httpResponseCode"] as Double? ?: -1).toInt(),
        description = jsonMap["description"] as String? ?: ""
    )
}

/**
 * Wifi requirement modes at the application level
 */
enum class RequireWiFi {
    asSetByTask,
    forAllTasks,
    forNoTasks
}

/**
 * Serializer for enums, such that they are encoded as an Int representing
 * the ordinal (index) of the value, instead of the String representation of
 * the value.
 */
open class EnumAsIntSerializer<T:Enum<*>>(
    serialName: String,
    val serialize: (v: T) -> Int,
    val deserialize: (v: Int) -> T
) : KSerializer<T> {
    override val descriptor: SerialDescriptor = PrimitiveSerialDescriptor(serialName, PrimitiveKind.INT)

    override fun serialize(encoder: Encoder, value: T) {
        encoder.encodeInt(serialize(value))
    }

    override fun deserialize(decoder: Decoder): T {
        val v = decoder.decodeInt()
        return deserialize(v)
    }
}
