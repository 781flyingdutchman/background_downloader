package com.bbflight.background_downloader

import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.storage.StorageManager
import android.util.Log
import androidx.core.net.toFile
import androidx.documentfile.provider.DocumentFile
import androidx.preference.PreferenceManager
import androidx.work.WorkerParameters
import com.bbflight.background_downloader.UriUtils.unpack
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.BufferedInputStream
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.RandomAccessFile
import java.net.HttpURLConnection
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import android.system.Os
import android.system.ErrnoException
import kotlin.math.absoluteValue
import kotlin.random.Random


class DownloadTaskWorker(applicationContext: Context, workerParams: WorkerParameters) :
    TaskWorker(applicationContext, workerParams) {

    private var eTagHeader: String? = null
    private var serverAcceptsRanges = false // if true, send resume data on fail
    private var tempFilePath = ""
    private var requiredStartByte = 0L // required start byte within the task range
    private var taskRangeStartByte = 0L // Start of the Task's download range

    private var eTag: String? = null

    /**
     * Make the request to the [connection] and process the [Task]
     *
     * Returns the [TaskStatus]
     * */
    override suspend fun connectAndProcess(connection: HttpURLConnection): TaskStatus {
        if (isResume) {
            val taskRangeHeader = task.headers["Range"] ?: ""
            val taskRange = parseRange(taskRangeHeader)
            taskRangeStartByte = taskRange.first
            val resumeRange = Pair(taskRangeStartByte + requiredStartByte, taskRange.second)
            val newRangeString = "bytes=${resumeRange.first}-${resumeRange.second ?: ""}"
            connection.setRequestProperty("Range", newRangeString)
        }
        val result = super.connectAndProcess(connection)
        if (result == TaskStatus.canceled) {
            deleteTempFile()
        }
        if (result == TaskStatus.failed) {
            prepResumeAfterFailure()
        }
        return result
    }

    /** Process the response to the GET or POST request on this [connection]
     *
     * Returns the [TaskStatus]
     */
    override suspend fun process(
        connection: HttpURLConnection,
    ): TaskStatus {
        val prefs = PreferenceManager.getDefaultSharedPreferences(applicationContext)

        // Check if the file should be skipped
        val skipThreshold = prefs.getInt(BDPlugin.keyConfigSkipExistingFiles, -1)
        if (skipThreshold != -1) {
            val filePath = task.filePath(applicationContext)
            val file = File(filePath)
            if (file.exists()) {
                val fileSize = file.length()
                if (fileSize > skipThreshold * 1024L * 1024L) {
                    responseStatusCode = 304
                    return TaskStatus.complete
                }
            }
        }

        val allowWeakETag = prefs.getBoolean(BDPlugin.keyConfigAllowWeakETag, false)

        responseStatusCode = connection.responseCode
        if (connection.responseCode in 200..206) {
            // determine if we are using Uri or not.  Uri means pause/resume not allowed
            val directoryUri = UriUtils.uriFromStringValue(task.directory)
            val usesUri = directoryUri != null
            eTagHeader = connection.headerFields["ETag"]?.first()
            val acceptRangesHeader = connection.headerFields["Accept-Ranges"]
            serverAcceptsRanges =
                acceptRangesHeader?.first() == "bytes" || connection.responseCode == 206
            if (task.allowPause && !usesUri) {
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
            if (isResume) {
                var resumeIsAllowed = false
                if (eTag == null || eTagHeader == null) {
                    resumeIsAllowed = true
                } else if (eTag?.subSequence(0, 1) == "W/") {
                    resumeIsAllowed = allowWeakETag && eTagHeader?.subSequence(0, 1) == "W/"
                } else {
                    resumeIsAllowed = eTag == eTagHeader
                }
                if (!resumeIsAllowed) {
                    deleteTempFile()
                    Log.i(TAG, "Cannot resume: ETag is not identical, or is weak")
                    taskException = TaskException(
                        ExceptionType.resume,
                        description = "Cannot resume: ETag is not identical, or is weak"
                    )
                    return TaskStatus.failed
                }
            }
            // Determine destination - either [destFilePath] or [destUri]
            // If no filename is set, get from headers or url, and update the task
            var destFilePath = task.filePath(applicationContext)
            var (uriFilename, destUri) = unpack(task.filename)
            if (!task.hasFilename()) {
                // If no filename is set, get from headers or url, and update the task
                if (usesUri) {
                    uriFilename = suggestFilename(connection.headerFields, task.url)
                    if (uriFilename.isEmpty()) {
                        uriFilename = "${Random.nextInt().absoluteValue}"
                    }
                    task = task.copyWith(
                        filename = if (destUri == null) uriFilename else UriUtils.pack(
                            uriFilename,
                            destUri
                        )
                    )
                } else {
                    destFilePath = destFilePath(connection)
                }
            }
            extractResponseHeaders(connection.headerFields)
            extractContentType(connection.headerFields)
            val contentLength = getContentLength(connection.headerFields, task)
            // determine tempFile, or set to null if Uri is used
            val tempFile = if (!usesUri) {
                val applicationSupportPath =
                    baseDirPath(applicationContext, BaseDirectory.applicationSupport)
                val cachePath = baseDirPath(applicationContext, BaseDirectory.temporary)
                if (applicationSupportPath == null || cachePath == null) {
                    throw IllegalStateException("External storage is requested but not available")
                }
                val tempDir =
                    when (PreferenceManager.getDefaultSharedPreferences(applicationContext)
                        .getInt(BDPlugin.keyConfigUseCacheDir, -2)) {
                        0 -> File(cachePath) // 'always'
                        -1 -> File(applicationSupportPath) // 'never'
                        else -> {
                            // 'whenAble' -> determine based on cache quota
                            val storageManager =
                                applicationContext.getSystemService(Context.STORAGE_SERVICE) as StorageManager
                            val cacheQuota = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                storageManager.getCacheQuotaBytes(
                                    storageManager.getUuidForPath(
                                        File(cachePath)
                                    )
                                )
                            } else {
                                50L shl (20)  // for older OS versions, assume 50MB
                            }
                            if (contentLength < cacheQuota / 2) File(cachePath) else File(
                                applicationSupportPath
                            )
                        }
                    }
                if (!tempDir.exists()) {
                    tempDir.mkdirs()
                }
                tempFilePath =
                    tempFilePath.ifEmpty { "${tempDir.absolutePath}/com.bbflight.background_downloader${Random.nextInt()}" }

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
                File(tempFilePath)
            } else {
                null
            }
            val outputStream = if (tempFile != null) {
                FileOutputStream(tempFile, isResume)
            } else {
                // no tempFile, because we have a Uri
                uriFilename = uriFilename ?: "unknown"
                if (directoryUri!!.scheme == "file") {
                    // fileUri is converted to a File, then to a FileOutputStream
                    if (destUri == null) {
                        // need to create file at directory
                        val dirObject = directoryUri.toFile()
                        val destFile = File(dirObject, uriFilename)
                        destUri = Uri.fromFile(destFile)
                        // Store destination Uri in task
                        task = task.copyWith(filename = UriUtils.pack(uriFilename, destUri))
                        FileOutputStream(destFile) // return outputStream
                    } else {
                        // use destination Uri that was set in previous attempt
                        FileOutputStream(destUri.toFile())
                    }
                } else {
                    // other URL scheme will be attempted to resolve using content resolver
                    val resolver = applicationContext.contentResolver
                    // create destination Uri if not already exists
                    val documentFile = DocumentFile.fromTreeUri(applicationContext, directoryUri)
                    destUri = destUri ?: documentFile?.createFile(task.mimeType, uriFilename)?.uri
                    if (destUri == null) {
                        val message =
                            "Failed to create document within directory with URI: $directoryUri"
                        Log.e(TAG, message)
                        taskException = TaskException(
                            ExceptionType.fileSystem,
                            description = message
                        )
                        return TaskStatus.failed
                    }
                    val newFilename = getFilenameFromUri(destUri)
                    if (newFilename.isNotEmpty()) {
                        uriFilename = newFilename
                    }
                    task = task.copyWith(filename = UriUtils.pack(uriFilename, destUri))
                    val os = resolver.openOutputStream(destUri)
                    if (os == null) {
                        val message = "Failed to open output stream for URI: $destUri"
                        Log.e(TAG, message)
                        taskException = TaskException(
                            ExceptionType.fileSystem,
                            description = message
                        )
                        return TaskStatus.failed
                    } else os
                }
            }
            BDPlugin.remainingBytesToDownload[task.taskId] = contentLength
            determineRunInForeground(task, contentLength) // sets 'runInForeground'
            // transfer the bytes from the server to the output stream
            val transferBytesResult: TaskStatus
            BufferedInputStream(connection.inputStream).use { inputStream ->
                transferBytesResult = transferBytes(
                    inputStream, outputStream, contentLength, task
                )
            }
            outputStream.flush()
            outputStream.close()
            // act on the result of the bytes transfer
            when (transferBytesResult) {
                TaskStatus.complete -> {
                    if (tempFile == null) {
                        Log.i(
                            TAG, "Successfully downloaded taskId ${task.taskId} to URI $destUri"
                        )
                    } else {
                        // move file from its temp location to the destination
                        val destFile = File(destFilePath)
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
                            setFileOwnership(destFile)
                        } else {
                            tempFile.copyTo(destFile, overwrite = true)
                            deleteTempFile()
                            setFileOwnership(destFile)
                        }
                        Log.i(
                            TAG, "Successfully downloaded taskId ${task.taskId} to $destFilePath"
                        )
                    }
                    return TaskStatus.complete
                }

                TaskStatus.canceled -> {
                    cleanup(usesUri, destUri)
                    Log.i(TAG, "Canceled taskId ${task.taskId}")
                    return TaskStatus.canceled
                }

                TaskStatus.paused -> {
                    BDPlugin.pausedTaskIds.remove(task.taskId)
                    if (taskCanResume) {
                        Log.i(TAG, "Task ${task.taskId} paused")
                        processResumeData(
                            ResumeData(
                                task, tempFilePath, bytesTotal + startByte, eTagHeader
                            ), prefs
                        )
                        return TaskStatus.paused
                    }
                    if (BDPlugin.tasksToReEnqueue.contains(task) && serverAcceptsRanges) {
                        // pause was triggered by re-enqueue request due to WiFi requirement change
                        // so we only store local resumeData without posting it
                        Log.i(TAG, "Task ${task.taskId} paused in order to re-enqueue")
                        BDPlugin.localResumeData[task.taskId] = ResumeData(
                            task, tempFilePath, bytesTotal + startByte, eTagHeader
                        )
                        return TaskStatus.paused
                    }
                    Log.i(TAG, "Task ${task.taskId} cannot resume, therefore pause failed")
                    taskException = TaskException(
                        ExceptionType.resume,
                        description = "Task was paused but cannot resume"
                    )
                    cleanup(usesUri, destUri)
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
                        BDPlugin.doEnqueue(
                            applicationContext,
                            task,
                            notificationConfigJsonString,
                            ResumeData(task, tempFilePath, start, eTag),
                            1000
                        )
                        return TaskStatus.paused
                    }
                    Log.i(TAG, "Task ${task.taskId} timed out and cannot pause/resume")
                    taskException =
                        TaskException(ExceptionType.connection, description = "Task timed out")
                    cleanup(usesUri, destUri)
                    return TaskStatus.failed
                }

                TaskStatus.failed -> {
                    prepResumeAfterFailure()
                    return TaskStatus.failed
                }

                else -> {
                    Log.e(TAG, "Unknown transferBytesResult $transferBytesResult")
                    cleanup(usesUri, destUri)
                    return TaskStatus.failed
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
     * Return destination filePath where the filename is set based on response headers, and
     * update the [task] accordingly
     */
    private fun destFilePath(connection: HttpURLConnection): String {
        val destFilePath = task.filePath(applicationContext)
        task = task.withSuggestedFilenameFromResponseHeaders(
            applicationContext,
            connection.headerFields,
            unique = true
        )
        val dirName = File(destFilePath).parent ?: ""
        return if (dirName.isEmpty()) task.filename else "$dirName/${task.filename}"
    }


    /**
     * Return true if this is a resume, and resume is possible,
     * given [tempFilePath] and [requiredStartByte]
     * */
    override fun determineIfResume(): Boolean {
        // set tempFilePath from resume data, or "" if a new tempFile is needed
        requiredStartByte = inputData.getLong(keyStartByte, 0)
        if (requiredStartByte == 0L) {
            return false
        }
        eTag = inputData.getString(keyETag)
        tempFilePath = if (requiredStartByte > 0) inputData.getString(keyResumeDataData) ?: ""
        else ""
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
            Log.i(
                TAG, "Could not " +
                        "process partial response Content-Range"
            )
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
        val tempFile = File(tempFilePath)
        val tempFileLength = tempFile.length()
        startByte = start - taskRangeStartByte // relative to start of range
        if (startByte > tempFileLength) {
            Log.i(TAG, "Offered range not feasible: $range with startByte $startByte")
            taskException = TaskException(
                ExceptionType.resume,
                description = "Offered range not feasible: $range with startByte $startByte"
            )
            return false
        }
        // resume possible, set start conditions
        try {
            RandomAccessFile(tempFilePath, "rw").use { it.setLength(startByte) }
        } catch (_: IOException) {
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
    private suspend fun prepResumeAfterFailure() {
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
     * Deletes the temp file associated with this download
     */
    private fun deleteTempFile() {
        if (tempFilePath.isNotEmpty()) {
            try {
                val tempFile = File(tempFilePath)
                tempFile.delete()
            } catch (_: IOException) {
                Log.i(TAG, "Could not delete temp file at $tempFilePath")
            }
        }
    }

    /**
     * Deletes the destination Uri at [uri]
     */
    private fun deleteDestinationUri(uri: Uri) {
        try {
            applicationContext.contentResolver.delete(uri, null, null)
        } catch (_: Exception) {
            Log.i(TAG, "Could not delete file at $uri")
        }
    }

    /**
     * Cleanup by deleting the temp file or destination uri
     */
    private fun cleanup(usesUri: Boolean, destUri: Uri?) {
        if (usesUri && destUri != null) {
            deleteDestinationUri(destUri)
        } else {
            deleteTempFile()
        }
    }

    /**
     * Sets the group ownership of the downloaded file.
     *
     * Determines the app's GID and then calls Os.chown. Logs success or failure.
     * Likely to fail if the file is in external storage.
     *
     * Reason for changing ownership os to unmark file as a cache file (issue #498)
     */
    private fun setFileOwnership(destFile: File) {
        try {
            val finalPath = destFile.absolutePath
            val gid = applicationContext.applicationInfo.uid // App's own GID
            Os.chown(finalPath, -1, gid) // -1 for UID means keep current owner
        } catch (e: ErrnoException) {
            // Log the error, common if the filesystem doesn't support chown or due to permissions.
            // Check OsConstants for specific errno values if needed.
            Log.w(
                TAG,
                "Failed to change group ownership for ${destFile.absolutePath}: ${e.message}"
            )
        }
    }

}
