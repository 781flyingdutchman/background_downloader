package com.bbflight.background_downloader

import android.content.Context
import android.util.Log
import androidx.work.WorkerParameters
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.DataOutputStream
import java.io.File
import java.io.FileInputStream
import java.net.HttpURLConnection

class UploadTaskWorker(applicationContext: Context, workerParams: WorkerParameters) :
    TaskWorker(applicationContext, workerParams) {

    companion object {
        private val asciiOnlyRegEx = Regex("^[\\x00-\\x7F]+$")
        private val newlineRegEx = Regex("\r\n|\r|\n")
        const val boundary = "-----background_downloader-akjhfw281onqciyhnIk"
        const val lineFeed = "\r\n"
    }

    /**
     * Process the upload of the file
     *
     * If the [Task.post] field is set to "binary" then the file will be uploaded as a byte stream POST
     *
     * If the [Task.post] field is not "binary" then the file(s) will be uploaded as a multipart POST
     *
     * Note that the [Task.post] field is just used to set whether this is a binary or multipart
     * upload. The bytes that will be posted are derived from the file to be uploaded.
     *
     * Returns the [TaskStatus]
     */
    override suspend fun process(
        connection: HttpURLConnection, filePath: String
    ): TaskStatus {
        connection.doOutput = true
        val transferBytesResult =
            if (task.post?.lowercase() == "binary") {
                processBinaryUpload(connection, filePath)
            } else {
                processMultipartUpload(connection, filePath)
            }
        when (transferBytesResult) {
            TaskStatus.canceled -> {
                Log.i(TAG, "Canceled taskId ${task.taskId} for $filePath")
                return TaskStatus.canceled
            }

            TaskStatus.failed -> {
                return TaskStatus.failed
            }

            TaskStatus.complete -> {
                responseBody = responseBodyContent(connection)
                if (connection.responseCode in 200..206) {
                    Log.i(
                        TAG, "Successfully uploaded taskId ${task.taskId} from $filePath"
                    )
                    return TaskStatus.complete
                }
                Log.i(
                    TAG,
                    "Response code ${connection.responseCode} for upload of $filePath to ${task.url}"
                )
                val errorContent = responseErrorContent(connection)
                taskException = TaskException(
                    ExceptionType.httpResponse, httpResponseCode = connection.responseCode,
                    description = if (errorContent?.isNotEmpty() == true) errorContent else connection.responseMessage
                )
                return if (connection.responseCode == 404) {
                    TaskStatus.notFound
                } else {
                    TaskStatus.failed
                }
            }

            else -> {
                return TaskStatus.failed
            }
        }
    }

    /**
     * Process the binary upload of the file
     *
     * Content-Disposition will be set to "attachment" with filename [Task.filename], and the
     * mime-type will be set to [Task.mimeType]
     *
     * Returns the [TaskStatus]
     */
    private suspend fun processBinaryUpload(
        connection: HttpURLConnection, filePath: String
    ): TaskStatus {
        val file = File(filePath)
        if (!file.exists() || !file.isFile) {
            Log.w(TAG, "File $filePath does not exist or is not a file")
            taskException = TaskException(
                ExceptionType.fileSystem,
                description = "File to upload does not exist: $filePath"
            )
            return TaskStatus.failed
        }
        val fileSize = file.length()
        if (fileSize <= 0) {
            Log.w(TAG, "File $filePath has 0 length")
            taskException = TaskException(
                ExceptionType.fileSystem,
                description = "File $filePath has 0 length"
            )
            return TaskStatus.failed
        }
        determineRunInForeground(task, fileSize)
        // binary file upload posts file bytes directly
        // set Content-Type based on file extension
        Log.d(TAG, "Binary upload for taskId ${task.taskId}")
        connection.setRequestProperty("Content-Type", task.mimeType)
        connection.setRequestProperty(
            "Content-Disposition", "attachment; filename=\"" + task.filename + "\""
        )
        connection.setRequestProperty("Content-Length", fileSize.toString())
        connection.setFixedLengthStreamingMode(fileSize)
        return withContext(Dispatchers.IO) {
            FileInputStream(file).use { inputStream ->
                DataOutputStream(connection.outputStream.buffered()).use { outputStream ->
                    return@withContext transferBytes(inputStream, outputStream, fileSize, task)
                }
            }
        }
    }

    /**
     * Process the multi-part upload of one or more files, and potential form fields
     *
     * Form fields are taken from [Task.fields]. If only one file is to be uploaded,
     * then the [filePath] determines the file, and [Task.fileField] and [Task.mimeType]
     * are used to set the file field name and mime type respectively.
     * If [filePath] is empty, then the list of fileField, filePath and mimeType are
     * extracted from the [Task.fileField], [Task.filename] and [Task.mimeType] (which
     * for MultiUploadTasks contain a JSON encoded list of strings).
     *
     * The total content length is calculated from the sum of all parts, the connection
     * is set up, and the bytes for each part are transferred to the host.
     *
     * Returns the [TaskStatus]
     */
    private suspend fun processMultipartUpload(
        connection: HttpURLConnection,
        filePath: String
    ): TaskStatus {
        // field portion of the multipart
        var fieldsString = ""
        for (entry in task.fields.entries) {
            fieldsString += fieldEntry(entry.key, entry.value)
        }
        // File portion of the multi-part
        // Assumes list of files. If only one file, that becomes a list of length one.
        // For each file, determine contentDispositionString, contentTypeString
        // and file length, so that we can calculate total size of upload
        val separator = "$lineFeed--$boundary$lineFeed" // between files
        val terminator = "$lineFeed--$boundary--$lineFeed" // after last file
        val filesData = if (filePath.isNotEmpty()) {
            listOf(
                Triple(task.fileField, filePath, task.mimeType)
            )
        } else {
            task.extractFilesData(applicationContext)
        }
        val contentDispositionStrings = ArrayList<String>()
        val contentTypeStrings = ArrayList<String>()
        val fileLengths = ArrayList<Long>()
        for ((fileField, path, mimeType) in filesData) {
            val file = File(path)
            if (!file.exists() || !file.isFile) {
                Log.w(TAG, "File at $path does not exist")
                taskException = TaskException(
                    ExceptionType.fileSystem,
                    description = "File to upload does not exist: $path"
                )
                return TaskStatus.failed
            }
            contentDispositionStrings.add(
                "Content-Disposition: form-data; name=\"${browserEncode(fileField)}\"; " +
                        "filename=\"${browserEncode(file.name)}\"$lineFeed"
            )
            contentTypeStrings.add("Content-Type: $mimeType$lineFeed$lineFeed")
            fileLengths.add(file.length())
        }
        val fileDataLength =
            contentDispositionStrings.sumOf { string: String -> lengthInBytes(string) } +
                    contentTypeStrings.sumOf { string: String -> string.length } +
                    fileLengths.sum() + separator.length * contentDispositionStrings.size + 2
        val contentLength =
            lengthInBytes(fieldsString) + "--$boundary$lineFeed".length + fileDataLength
        determineRunInForeground(task, contentLength)
        // setup the connection
        connection.setRequestProperty("Accept-Charset", "UTF-8")
        connection.setRequestProperty("Connection", "Keep-Alive")
        connection.setRequestProperty("Cache-Control", "no-cache")
        connection.setRequestProperty(
            "Content-Type", "multipart/form-data; boundary=$boundary"
        )
        connection.setRequestProperty("Content-Length", contentLength.toString())
        connection.setFixedLengthStreamingMode(contentLength)
        connection.useCaches = false
        // transfer the bytes
        return withContext(Dispatchers.IO) {
            DataOutputStream(connection.outputStream).use { outputStream ->
                val writer = outputStream.writer()
                // write form fields
                writer.append(fieldsString).append("--${boundary}").append(lineFeed)
                // write each file
                for (i in filesData.indices) {
                    FileInputStream(filesData[i].second).use { inputStream ->
                        writer.append(contentDispositionStrings[i])
                            .append(contentTypeStrings[i]).flush()
                        val transferBytesResult =
                            transferBytes(inputStream, outputStream, contentLength, task)
                        if (transferBytesResult == TaskStatus.complete) {
                            if (i < filesData.size - 1) {
                                writer.append(separator)
                            } else
                                writer.append(terminator)
                        } else {
                            return@withContext transferBytesResult
                        }
                    }
                }
                writer.close()
            }
            return@withContext TaskStatus.complete
        }
    }

    /**
     * Return the response's body content as a String, or null if unable
     */
    private fun responseBodyContent(connection: HttpURLConnection): String? {
        try {
            return connection.inputStream.bufferedReader().readText()
        } catch (e: Exception) {
            Log.i(
                TAG,
                "Could not read response body from httpResponseCode ${connection.responseCode}: $e"
            )
        }
        return null
    }

    /**
     * Returns the multipart entry for one field name/value pair
     */
    private fun fieldEntry(name: String, value: String): String {
        return "--$boundary$lineFeed${headerForField(name, value)}$value$lineFeed"
    }

    /**
     * Returns the header string for a field
     *
     * The return value is guaranteed to contain only ASCII characters
     */
    private fun headerForField(name: String, value: String): String {
        var header = "content-disposition: form-data; name=\"${browserEncode(name)}\""
        if (!isPlainAscii(value)) {
            header = "$header\r\n" +
                    "content-type: text/plain; charset=utf-8\r\n" +
                    "content-transfer-encoding: binary"
        }
        return "$header\r\n\r\n"
    }

    /**
     * Returns whether [string] is composed entirely of ASCII-compatible characters
     */
    private fun isPlainAscii(string: String): Boolean {
        return asciiOnlyRegEx.matches(string)
    }

    /**
     * Encode [value] in the same way browsers do
     */
    private fun browserEncode(value: String): String {
        // http://tools.ietf.org/html/rfc2388 mandates some complex encodings for
        // field names and file names, but in practice user agents seem not to
        // follow this at all. Instead, they URL-encode `\r`, `\n`, and `\r\n` as
        // `\r\n`; URL-encode `"`; and do nothing else (even for `%` or non-ASCII
        // characters). We follow their behavior.
        return value.replace(newlineRegEx, "%0D%0A").replace("\"", "%22")
    }

    /**
     * Returns the length of the [string] in bytes when utf-8 encoded
     */
    private fun lengthInBytes(string: String): Int {
        return string.toByteArray().size
    }
}
