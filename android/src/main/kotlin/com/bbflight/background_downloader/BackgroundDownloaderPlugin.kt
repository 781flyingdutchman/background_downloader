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
        const val TAG = "BackgroundDownloader"
        const val keyTasksMap = "com.bbflight.background_downloader.taskMap"
        var canceledTaskIds = HashMap<String, Long>() // <taskId, timeMillis>
        var backgroundChannel: MethodChannel? = null
        var backgroundChannelCounter = 0  // reference counter
        val prefsLock = ReentrantReadWriteLock()
        private lateinit var workManager: WorkManager
        lateinit var prefs: SharedPreferences
        val gson = Gson()
        val jsonMapType = object : TypeToken<Map<String, Any>>() {}.type
    }

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        backgroundChannelCounter++
        if (backgroundChannel == null) {
            // only set background channel once, as it has to be static field
            // and per https://github.com/firebase/flutterfire/issues/9689 other
            // plugins can create multiple instances of the plugin
            backgroundChannel = MethodChannel(
                flutterPluginBinding.binaryMessenger,
                "com.bbflight.background_downloader.background"
            )
        }
        channel = MethodChannel(
            flutterPluginBinding.binaryMessenger,
            "com.bbflight.background_downloader"
        )
        channel?.setMethodCallHandler(this)
        workManager = WorkManager.getInstance(flutterPluginBinding.applicationContext)
        prefs = PreferenceManager.getDefaultSharedPreferences(
            flutterPluginBinding.applicationContext
        )
        val allWorkInfos = workManager.getWorkInfosByTag(TAG).get()
        if (allWorkInfos.isEmpty()) {
            // remove persistent storage if no jobs found at all
            val editor = prefs.edit()
            editor.remove(keyTasksMap)
            editor.apply()
        }
    }

    /** Free up resources. BackgroundChannel is only released if no more references to an engine */
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        backgroundChannelCounter--
        if (backgroundChannelCounter == 0) {
            backgroundChannel = null
        }
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "enqueue" -> methodEnqueue(call, result)
            "reset" -> methodReset(call, result)
            "allTasks" -> methodAllTasks(call, result)
            "cancelTasksWithIds" -> methodCancelTasksWithIds(call, result)
            "taskForId" -> methodTaskForId(call, result)
            else -> result.notImplemented()
        }
    }

    /** Starts one task, passed as map of values representing a [Task]
     *
     *  Returns true if successful, and will emit a status update that the task is running
     */
    private fun methodEnqueue(call: MethodCall, result: Result) {
        val args = call.arguments as List<*>
        val taskJsonMapString = args[0] as String
        val task =
            Task(gson.fromJson(taskJsonMapString, jsonMapType))
        Log.i(TAG, "Starting task with id ${task.taskId}")
        val data =
            Data.Builder().putString(TaskWorker.keyTask, taskJsonMapString)
                .build()
        val constraints = Constraints.Builder().setRequiredNetworkType(
            if (task.requiresWiFi) NetworkType.UNMETERED else NetworkType.CONNECTED
        )
            .build()
        val request = OneTimeWorkRequestBuilder<TaskWorker>().setInputData(data)
            .setConstraints(constraints).addTag(TAG)
            .addTag("taskId=${task.taskId}")
            .addTag("group=${task.group}").build()
        val operation = workManager.enqueue(request)
        try {
            operation.result.get()
            TaskWorker.processStatusUpdate(task, TaskStatus.enqueued)
        } catch (e: Throwable) {
            Log.w(
                TAG,
                "Unable to start background request for taskId ${task.taskId} in operation: $operation"
            )
            result.success(false)
            return
        }
        // store Task in persistent storage, as Json representation keyed by taskId
        prefsLock.write {
            val jsonString = prefs.getString(keyTasksMap, "{}")
            val tasksMap =
                gson.fromJson<Map<String, Any>>(jsonString, jsonMapType).toMutableMap()
            tasksMap[task.taskId] =
                gson.toJson(task.toJsonMap())
            val editor = prefs.edit()
            editor.putString(keyTasksMap, gson.toJson(tasksMap))
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

    /** Returns a list of tasks for all tasks in progress, as a list of JSON strings */
    private fun methodAllTasks(call: MethodCall, result: Result) {
        val group = call.arguments as String
        val workInfos = workManager.getWorkInfosByTag(TAG).get()
            .filter { !it.state.isFinished && it.tags.contains("group=$group") }
        val tasksAsListOfJsonStrings = mutableListOf<String>()
        prefsLock.read {
            val jsonString = prefs.getString(keyTasksMap, "{}")
            val tasksMap = gson.fromJson<Map<String, Any>>(jsonString, jsonMapType)
            for (workInfo in workInfos) {
                val tags = workInfo.tags.filter { it.contains("taskId=") }
                if (tags.isNotEmpty()) {
                    val taskId = tags.first().substring(7)
                    tasksAsListOfJsonStrings.add(tasksMap[taskId] as String)
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
            val workInfos = workManager.getWorkInfosByTag("taskId=$taskId").get()
            if (workInfos.isEmpty()) {
                throw IllegalArgumentException("Not found")
            }
            val workInfo = workInfos.first()
            if (workInfo.state != WorkInfo.State.SUCCEEDED) {
                // send cancellation update for tasks that have not yet succeeded
                prefsLock.read {
                    val tasksMap = getTaskMap()
                    val taskJsonMap = tasksMap[taskId] as String?
                    if (taskJsonMap != null) {
                        val task = Task(
                            gson.fromJson(taskJsonMap, jsonMapType)
                        )
                        TaskWorker.processStatusUpdate(task, TaskStatus.canceled)
                    }
                    else {
                        Log.d(TAG, "Could not find taskId $taskId to cancel")
                    }
                }
            }
            val operation = workManager.cancelAllWorkByTag("taskId=$taskId")
            try {
                operation.result.get()
            } catch (e: Throwable) {
                Log.w(TAG, "Unable to cancel taskId $taskId in operation: $operation")
                result.success(false)
                return
            }
        }
        result.success(true)
    }

    /** Returns Task for this taskId, or nil */
    private fun methodTaskForId(call: MethodCall, result: Result) {
        val taskId = call.arguments as String
        Log.v(TAG, "Returning task for taskId $taskId")
        prefsLock.read {
            val jsonString = prefs.getString(keyTasksMap, "{}")
            val tasksMap =
                gson.fromJson<Map<String, Any>>(jsonString, jsonMapType).toMutableMap()
            result.success(tasksMap[taskId])
        }
    }
}


