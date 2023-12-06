package com.bbflight.background_downloader

import android.content.Context
import android.os.Build
import android.os.storage.StorageManager
import android.util.Log
import androidx.preference.PreferenceManager
import androidx.work.WorkerParameters
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
        filePath: String
    ): TaskStatus {
        if (connection.responseCode in 200..206) {
            // ok response, check if resume is possible
            eTagHeader = connection.headerFields["ETag"]?.first()
            val acceptRangesHeader = connection.headerFields["Accept-Ranges"]
            serverAcceptsRanges =
                acceptRangesHeader?.first() == "bytes" || connection.responseCode == 206
            if (task.allowPause) {
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
            if (isResume && (eTagHeader != eTag || eTag?.subSequence(0, 1) == "W/")) {
                deleteTempFile()
                Log.i(TAG, "Cannot resume: ETag is not identical, or is weak")
                taskException = TaskException(
                    ExceptionType.resume,
                    description = "Cannot resume: ETag is not identical, or is weak"
                )
                return TaskStatus.failed
            }
            // if no filename is set, get from headers or url, update task and set new destFilePath
            var destFilePath = filePath
            if (!task.hasFilename()) {
                task = task.withSuggestedFilenameFromResponseHeaders(
                    applicationContext,
                    connection.headerFields,
                    unique = true
                )
                val dirName = File(filePath).parent ?: ""
                destFilePath = "$dirName/${task.filename}"
                Log.d(TAG, "Suggested filename for taskId ${task.taskId}: ${task.filename}")
            }
            extractContentType(connection.headerFields)
            // determine tempFile
            val contentLength = getContentLength(connection.headerFields, task)
            val applicationSupportPath =
                baseDirPath(applicationContext, BaseDirectory.applicationSupport)
            val cachePath = baseDirPath(applicationContext, BaseDirectory.temporary)
            if (applicationSupportPath == null || cachePath == null) {
                throw IllegalStateException("External storage is requested but not available")
            }
            val tempDir = when (PreferenceManager.getDefaultSharedPreferences(applicationContext)
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
            val tempFile = File(tempFilePath)
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
            BDPlugin.remainingBytesToDownload[task.taskId] = contentLength
            determineRunInForeground(task, contentLength) // sets 'runInForeground'
            // transfer the bytes from the server to the temp file
            val transferBytesResult: TaskStatus
            BufferedInputStream(connection.inputStream).use { inputStream ->
                FileOutputStream(tempFile, isResume).use { outputStream ->
                    transferBytesResult = transferBytes(
                        inputStream, outputStream, contentLength, task
                    )
                }
            }
            // act on the result of the bytes transfer
            when (transferBytesResult) {
                TaskStatus.complete -> {
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
                    } else {
                        tempFile.copyTo(destFile, overwrite = true)
                        deleteTempFile()
                    }
                    Log.i(
                        TAG, "Successfully downloaded taskId ${task.taskId} to $destFilePath"
                    )
                    return TaskStatus.complete
                }

                TaskStatus.canceled -> {
                    deleteTempFile()
                    Log.i(TAG, "Canceled taskId ${task.taskId} for $destFilePath")
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
                    Log.i(TAG, "Task ${task.taskId} cannot resume, therefore pause failed")
                    taskException = TaskException(
                        ExceptionType.resume,
                        description = "Task was paused but cannot resume"
                    )
                    deleteTempFile()
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
                    deleteTempFile()
                    return TaskStatus.failed
                }

                TaskStatus.failed -> {
                    prepResumeAfterFailure()
                    return TaskStatus.failed
                }

                else -> {
                    Log.e(TAG, "Unknown transferBytesResult $transferBytesResult")
                    deleteTempFile()
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
     * Return true if this is a resume, and resume is possible,
     * given [tempFilePath] and [requiredStartByte]
     * */
    override fun determineIfResume(): Boolean {
        // set tempFilePath from resume data, or "" if a new tempFile is needed
        requiredStartByte = inputData.getLong(keyStartByte, 0)
        tempFilePath = if (requiredStartByte > 0) inputData.getString(keyResumeDataData) ?: ""
        else ""
        eTag = inputData.getString(keyETag)

        if (requiredStartByte == 0L) {
            return false
        }
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
            Log.i(TAG, "Could not process partial response Content-Range")
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
        val end = matchResult.groups[2]?.value?.toLong()!!
        val total = matchResult.groups[3]?.value?.toLong()!!
        val tempFile = File(tempFilePath)
        val tempFileLength = tempFile.length()
        Log.d(
            TAG,
            "Resume start=$start, end=$end of total=$total bytes, tempFile = $tempFileLength bytes"
        )
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
        } catch (e: IOException) {
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

    private fun deleteTempFile() {
        if (tempFilePath.isNotEmpty()) {
            try {
                val tempFile = File(tempFilePath)
                tempFile.delete()
            } catch (e: IOException) {
                Log.i(TAG, "Could not delete temp file at $tempFilePath")
            }
        }
    }


}
