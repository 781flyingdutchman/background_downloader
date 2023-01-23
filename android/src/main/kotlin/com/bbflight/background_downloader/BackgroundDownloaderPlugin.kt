package com.bbflight.background_downloader

import android.content.SharedPreferences
import android.util.Log
import androidx.preference.PreferenceManager
import androidx.work.*
import com.google.gson.Gson
import com.google.gson.reflect.TypeToken
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.util.concurrent.locks.ReentrantReadWriteLock
import kotlin.concurrent.read
import kotlin.concurrent.write

/** BackgroundDownloaderPlugin */
class BackgroundDownloaderPlugin : FlutterPlugin, MethodCallHandler {
    private var channel: MethodChannel? = null

    companion object {
        const val TAG = "BackgroundDownloaderPlugin"
        const val keyTasksMap = "com.bbflight.background_downloader.taskMap"
        var backgroundChannel: MethodChannel? = null
        val prefsLock = ReentrantReadWriteLock()
        private lateinit var workManager: WorkManager
        lateinit var prefs: SharedPreferences
        val gson = Gson()
        val mapType = object : TypeToken<Map<String, Any>>() {}.type
    }

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        if (backgroundChannel == null) {
            // only set background channel once, as it has to be static field
            // and per https://github.com/firebase/flutterfire/issues/9689 other
            // plugins can create multiple instances of the plugin
            backgroundChannel = MethodChannel(flutterPluginBinding.binaryMessenger,
                    "com.bbflight.background_downloader.background")
        }
        channel = MethodChannel(flutterPluginBinding.binaryMessenger,
                "com.bbflight.background_downloader")
        channel?.setMethodCallHandler(this)
        workManager = WorkManager.getInstance(flutterPluginBinding.applicationContext)
        prefs = PreferenceManager.getDefaultSharedPreferences(
                flutterPluginBinding.applicationContext)
        val allWorkInfos = workManager.getWorkInfosByTag(TAG).get()
        if (allWorkInfos.isEmpty()) {
            // remove persistent storage if no jobs found at all
            val editor = prefs.edit()
            editor.remove(keyTasksMap)
            editor.apply()
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "enqueue" -> methodEnqueue(call, result)
            "reset" -> methodReset(call, result)
            "allTaskIds" -> methodAllTaskIds(call, result)
            "allTasks" -> methodAllTasks(call, result)
            "cancelTasksWithIds" -> methodCancelTasksWithIds(call, result)
            "taskForId" -> methodTaskForId(call, result)
            else -> result.notImplemented()
        }
    }

    /** Starts the download for one task, passed as map of values representing a
     * [BackgroundDownloadTask]
     *
     *  Returns true if successful, but will emit a status update that the background task is running
     */
    private fun methodEnqueue(call: MethodCall, result: Result) {
        val args = call.arguments as List<*>
        val downloadTaskJsonMapString = args[0] as String
        val backgroundDownloadTask =
                BackgroundDownloadTask(gson.fromJson(downloadTaskJsonMapString, mapType))
        Log.v(TAG, "Starting task with id ${backgroundDownloadTask.taskId}")
        val data =
                Data.Builder().putString(DownloadWorker.keyDownloadTask, downloadTaskJsonMapString)
                        .build()
        val constraints = Constraints.Builder().setRequiredNetworkType(
                if (backgroundDownloadTask.requiresWiFi) NetworkType.UNMETERED else NetworkType.CONNECTED)
                .build()
        val request = OneTimeWorkRequestBuilder<DownloadWorker>().setInputData(data)
                .setConstraints(constraints).addTag(TAG)
                .addTag("taskId=${backgroundDownloadTask.taskId}")
                .addTag("group=${backgroundDownloadTask.group}").build()
        val operation = workManager.enqueue(request)
        try {
            operation.result.get()
            DownloadWorker.processStatusUpdate(backgroundDownloadTask, DownloadTaskStatus.running)
        } catch (e: Throwable) {
            Log.w(TAG,
                    "Unable to start background request for taskId ${backgroundDownloadTask.taskId} in operation: $operation")
            result.success(false)
            return
        }
        // store Task in persistent storage, as Json representation keyed by taskId
        prefsLock.write {
            val jsonString = prefs.getString(keyTasksMap, "{}")
            val backgroundDownloadTaskMap =
                    gson.fromJson<Map<String, Any>>(jsonString, mapType).toMutableMap()
            backgroundDownloadTaskMap[backgroundDownloadTask.taskId] =
                    gson.toJson(backgroundDownloadTask.toJsonMap())
            val editor = prefs.edit()
            editor.putString(keyTasksMap, gson.toJson(backgroundDownloadTaskMap))
            editor.apply()
        }
        result.success(true)
    }

    /** Resets the download worker by cancelling all ongoing download tasks for the group
     *
     *  Returns the number of tasks canceled
     */
    private fun methodReset(call: MethodCall, result: Result) {
        val group = call.arguments as String
        var counter = 0
        val workInfos = workManager.getWorkInfosByTag(TAG).get()
                .filter { !it.state.isFinished && it.tags.contains("group=$group") }
        for (workInfo in workInfos) {
            workManager.cancelWorkById(workInfo.id)
            counter++
        }
        Log.v(TAG, "methodReset removed $counter unfinished tasks in group $group")
        result.success(counter)
    }

    /** Returns a list of taskIds for all tasks in progress */
    private fun methodAllTaskIds(call: MethodCall, result: Result) {
        val group = call.arguments as String
        val workInfos = workManager.getWorkInfosByTag(TAG).get()
                .filter { !it.state.isFinished && it.tags.contains("group=$group") }
        val taskIds = mutableListOf<String>()
        for (workInfo in workInfos) {
            val tags = workInfo.tags.filter { it.contains("taskId=") }
            if (tags.isNotEmpty()) {
                taskIds.add(tags.first().substring(7))
            }
        }
        Log.v(TAG, "Returning ${taskIds.size} unfinished tasks in group $group: $taskIds")
        result.success(taskIds)
    }

    /** Returns a list of tasks for all tasks in progress, as a list of JSON strings */
    private fun methodAllTasks(call: MethodCall, result: Result) {
        val group = call.arguments as String
        val workInfos = workManager.getWorkInfosByTag(TAG).get()
                .filter { !it.state.isFinished && it.tags.contains("group=$group") }
        val tasksAsListOfJsonStrings = mutableListOf<String>()
        prefsLock.read {
            val jsonString = prefs.getString(keyTasksMap, "{}")
            val backgroundDownloadTaskMap = gson.fromJson<Map<String, Any>>(jsonString, mapType)
            for (workInfo in workInfos) {
                val tags = workInfo.tags.filter { it.contains("taskId=") }
                if (tags.isNotEmpty()) {
                    val taskId = tags.first().substring(7)
                    tasksAsListOfJsonStrings.add(backgroundDownloadTaskMap[taskId] as String)
                }
            }
        }
        Log.v(TAG, "Returning ${tasksAsListOfJsonStrings.size} unfinished tasks in group $group")
        result.success(tasksAsListOfJsonStrings)
    }

    /** Cancels ongoing tasks whose taskId is in the list provided with this call
     *
     * Returns true if all cancellations were successful
     * */
    private fun methodCancelTasksWithIds(call: MethodCall, result: Result) {
        val taskIds = call.arguments as List<*>
        Log.v(TAG, "Canceling taskIds $taskIds")
        for (taskId in taskIds) {
            val operation = workManager.cancelAllWorkByTag("taskId=$taskId")
            try {
                operation.result.get()
            } catch (e: Throwable) {
                Log.w(TAG, "Unable to cancel taskId $taskId in operation: $operation")
                result.success(false)
            }
        }
        result.success(true)
    }

    /** Returns BackgroundDownloadTask for this taskId, or nil */
    private fun methodTaskForId(call: MethodCall, result: Result) {
        val taskId = call.arguments as String
        Log.v(TAG, "Returning task for taskId $taskId")
        prefsLock.read {
            val jsonString = prefs.getString(keyTasksMap, "{}")
            val backgroundDownloadTaskMap =
                    gson.fromJson<Map<String, Any>>(jsonString, mapType).toMutableMap()
            result.success(backgroundDownloadTaskMap[taskId])
        }
    }
}


