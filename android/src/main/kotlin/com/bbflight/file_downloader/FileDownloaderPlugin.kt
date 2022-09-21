package com.bbflight.file_downloader

import android.content.SharedPreferences
import android.util.Log
import androidx.annotation.NonNull
import androidx.preference.PreferenceManager
import androidx.work.*
import com.google.gson.Gson
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

/** FlutterDownloaderPlugin */
class FileDownloaderPlugin : FlutterPlugin, MethodCallHandler {
    companion object {
        const val TAG = "FileDownloaderPlugin"
        private var channel: MethodChannel? = null
        var backgroundChannel: MethodChannel? = null
        private lateinit var workManager: WorkManager
        private lateinit var prefs: SharedPreferences
    }

    override fun onAttachedToEngine(@NonNull flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        channel =
            MethodChannel(flutterPluginBinding.binaryMessenger, "com.bbflight.file_downloader")
        backgroundChannel =
            MethodChannel(
                flutterPluginBinding.binaryMessenger,
                "com.bbflight.file_downloader.background"
            )
        channel?.setMethodCallHandler(this)
        workManager = WorkManager.getInstance(flutterPluginBinding.applicationContext)
        prefs =
            PreferenceManager.getDefaultSharedPreferences(flutterPluginBinding.applicationContext)
    }

    override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        backgroundChannel = null
    }

    override fun onMethodCall(@NonNull call: MethodCall, @NonNull result: Result) {
        when (call.method) {
            "reset" -> methodReset(result)
            "enqueueDownload" -> methodEnqueueDownload(call, result)
            "allTasks" -> methodAllTasks(result)
            "cancelTasksWithIds" -> methodCancelTasksWithIds(call, result)
            else -> result.notImplemented()
        }
    }


    /** Resets the downloadworker by cancelling all ongoing download tasks
     *
     *  Returns the number of tasks canceled
     */
    private fun methodReset(@NonNull result: Result) {
        var counter = 0
        val workInfos = workManager.getWorkInfosByTag(TAG).get().filter { !it.state.isFinished }
        for (workInfo in workInfos) {
            workManager.cancelWorkById(workInfo.id)
            counter++
        }
        Log.v(TAG, "methodReset removed $counter unfinished tasks")
        result.success(counter)
    }

    /** Starts the download for one task, passed as JSON String representing a BackgroundDownloadTasks
     *
     *  Returns true if successful, but will emit a status update that the background task is running
     */
    private fun methodEnqueueDownload(@NonNull call: MethodCall, @NonNull result: Result) {
        val downloadTaskJsonString = call.arguments as String
        val gson = Gson()
        val downloadTask = gson.fromJson(
            downloadTaskJsonString,
            BackgroundDownloadTask::class.java
        )
        Log.d(TAG, "Starting task with id ${downloadTask.taskId}")
        val data = Data.Builder()
            .putString(DownloadWorker.keyDownloadTask, downloadTaskJsonString)
            .build()
        val constraints = Constraints.Builder()
            .setRequiredNetworkType(NetworkType.CONNECTED)
            .build()
        val request = OneTimeWorkRequestBuilder<DownloadWorker>()
            .setInputData(data)
            .setConstraints(constraints)
            .addTag(TAG)
            .addTag("taskId=${downloadTask.taskId}")
            .build()
        val operation = workManager.enqueue(request)
        try {
            operation.result.get()
            DownloadWorker.sendStatusUpdate(downloadTask, DownloadTaskStatus.running)
        } catch (e: Throwable) {
            Log.w(
                TAG,
                "Unable to start background request for taskId ${downloadTask.taskId} in operation: $operation"
            )
            result.success(false)
        }
        result.success(true)
    }

    /** Returns a ist of taskIds for all tasks in progress */
    private fun methodAllTasks(@NonNull result: Result) {
        val workInfos = workManager.getWorkInfosByTag(TAG).get().filter { !it.state.isFinished }
        val taskIds = mutableListOf<String>()
        for (workInfo in workInfos) {
            val tags = workInfo.tags.filter { it.contains("taskId=") }
            if (tags.isNotEmpty()) {
                taskIds.add(tags.first().substring(7))
            }
        }
        Log.d(TAG, "Returning ${taskIds.size} unfinished tasks: $taskIds")
        result.success(taskIds)
    }

    /** Cancels ongoing tasks whose taskId is in the list provided with this call */
    private fun methodCancelTasksWithIds(@NonNull call: MethodCall, @NonNull result: Result) {
        val taskIds = call.arguments as List<*>
        Log.d(TAG, "Canceling taskIds $taskIds")
        for (taskId in taskIds) {
            workManager.cancelAllWorkByTag("taskId=$taskId")
        }
        result.success(null)
    }
}


