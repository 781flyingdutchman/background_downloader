package com.bbflight.file_downloader

import android.content.SharedPreferences
import android.util.Log
import androidx.annotation.NonNull
import androidx.concurrent.futures.await
import androidx.preference.PreferenceManager
import androidx.work.*
import com.google.gson.Gson

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.util.Predicate
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import kotlin.coroutines.coroutineContext

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
            MethodChannel(flutterPluginBinding.binaryMessenger, "com.bbflight.file_downloader.background")
        channel?.setMethodCallHandler(this)
        workManager = WorkManager.getInstance(flutterPluginBinding.applicationContext)
        prefs = PreferenceManager.getDefaultSharedPreferences(flutterPluginBinding.applicationContext)
    }

    override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        backgroundChannel = null
    }

    override fun onMethodCall(@NonNull call: MethodCall, @NonNull result: Result) {
        Log.d(TAG, "method call: ${call.method}")
        when (call.method) {
            "reset" -> methodReset(call, result)
            "enqueueDownload" -> methodEnqueueDownload(call, result)
            "allTasks" -> methodAllTasks(call, result)
            "cancelTasksWithIds" -> methodCancelTasksWithIds(call, result)
            else -> result.notImplemented()
        }
    }


    /** Initialization: store the handler to the workerDispatcher and the debug mode */
    private fun methodReset(@NonNull call: MethodCall, @NonNull result: Result) {
        workManager.cancelAllWorkByTag(TAG)
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
            .addTag(downloadTask.taskId)
            .build()
        val operation = workManager.enqueue(request)
        Log.d(TAG, "Operation ${operation.result}")
        result.success(null)
    }

    /** Returns a ist of taskIds for all tasks in progress */
    private fun methodAllTasks(@NonNull call: MethodCall, @NonNull result: Result) {
        val workInfos = workManager.getWorkInfosByTag(TAG).get()
        val taskIds = mutableListOf<String>()
        for (workInfo in workInfos) {
            val tags = workInfo.tags.filter { it != TAG && it != "com.bbflight.file_downloader.DownloadWorker" }
            if (tags.isNotEmpty()) {
                taskIds.add(tags.first())
            }
        }
        result.success(taskIds);
    }

    /** Cancels ongoing tasks whose taskId is in the list provided with this call */
    private fun methodCancelTasksWithIds(@NonNull call: MethodCall, @NonNull result: Result) {
        val taskIds = call.arguments as List<*>
        Log.d(TAG, "Canceling $taskIds")
        for (taskId in taskIds) {
            workManager.cancelAllWorkByTag(taskId as String)
        }
        result.success(null)
    }
}


