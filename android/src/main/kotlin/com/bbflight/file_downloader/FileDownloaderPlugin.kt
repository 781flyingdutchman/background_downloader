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
        Log.d(TAG, "method call: ${call.method}")
        when (call.method) {
            "reset" -> methodReset(result)
            "enqueueDownload" -> methodEnqueueDownload(call, result)
            "allTasks" -> methodAllTasks(result)
            "cancelTasksWithIds" -> methodCancelTasksWithIds(call, result)
            else -> result.notImplemented()
        }
    }


    /** Initialization: store the handler to the workerDispatcher and the debug mode */
    private fun methodReset(@NonNull result: Result) {
        var counter = 0
        val workInfos = workManager.getWorkInfosByTag(TAG).get().filter { !it.state.isFinished }
        for (workInfo in workInfos) {
            workManager.cancelWorkById(workInfo.id)
            counter++
        }
        Log.v(TAG, "methodReset removed $counter unfinished tasks")
        result.success(null)
    }

    /** Enqueues the downloadTask */
    private fun methodEnqueueDownload(@NonNull call: MethodCall, @NonNull result: Result) {
        val downloadTaskJsonString = call.arguments as String
        val gson = Gson()
        val downloadTask = gson.fromJson(
            downloadTaskJsonString,
            BackgroundDownloadTask::class.java
        )
        Log.d(TAG, "Enqueueing task  $downloadTaskJsonString")
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
        Log.d(TAG, "Operation ${operation.result}")
        result.success(null)
    }

    /** Returns a ist of taskIds for all tasks in progress */
    private fun methodAllTasks(@NonNull result: Result) {
        Log.d(TAG, "In methodAllTasks")
        val workInfos = workManager.getWorkInfosByTag(TAG).get().filter { !it.state.isFinished }
        val taskIds = mutableListOf<String>()
        for (workInfo in workInfos) {
            val tags = workInfo.tags.filter { it.contains("taskId=") }
            if (tags.isNotEmpty()) {
                taskIds.add(tags.first().substring(7))
            }
        }
        Log.d(TAG, "methodAllTasks returns ${taskIds.size} unfinished tasks: $taskIds")
        result.success(taskIds)
    }

    /** Cancels ongoing tasks whose taskId is in the list provided with this call */
    private fun methodCancelTasksWithIds(@NonNull call: MethodCall, @NonNull result: Result) {
        val taskIds = call.arguments as List<*>
        Log.d(TAG, "Canceling $taskIds")
        for (taskId in taskIds) {
            workManager.cancelAllWorkByTag("taskId=$taskId")
        }
        result.success(null)
    }
}


