package com.bbflight.background_downloader

import android.content.Context
import android.util.Log
import androidx.work.WorkerParameters
import java.net.HttpURLConnection

class DataTaskWorker(applicationContext: Context, workerParams: WorkerParameters) :
    TaskWorker(applicationContext, workerParams) {

    /** Process the response to the GET or POST request on this [connection]
     *
     * Returns the [TaskStatus]
     */
    override suspend fun process(
        connection: HttpURLConnection,
    ): TaskStatus {
        responseStatusCode = connection.responseCode
        if (connection.responseCode in 200..206) {
            extractResponseHeaders(connection.headerFields)
            extractContentType(connection.headerFields)
            // transfer the bytes from the server to the temp file
            return try {
                responseBody = connection.inputStream.bufferedReader().readText()
                TaskStatus.complete
            } catch (e: Exception) {
                Log.i(
                    TAG,
                    "Could not read response content: $e"
                )
                taskException = TaskException(ExceptionType.connection, description = "Could not read response content: $e")
                TaskStatus.failed
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
}
