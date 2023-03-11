package com.bbflight.background_downloader

import android.content.Context
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
import kotlinx.coroutines.*
import java.lang.Long.min
import java.util.*
import java.util.concurrent.TimeUnit
import java.util.concurrent.locks.ReentrantReadWriteLock
import kotlin.concurrent.read
import kotlin.concurrent.schedule
import kotlin.concurrent.write

/**
 * Entry-point for Android native side of the plugin
 *
 * Manages the WorkManager task queue and the interface to Dart. Actual work is done in
 * [TaskWorker]
 */
class BackgroundDownloaderPlugin : FlutterPlugin, MethodCallHandler {
    private var channel: MethodChannel? = null
    lateinit var context: Context

    companion object {
        const val TAG = "BackgroundDownloader"
        const val keyTasksMap = "com.bbflight.background_downloader.taskMap"
        const val keyResumeDataMap = "com.bbflight.background_downloader.resumeDataMap"
        const val keyStatusUpdateMap = "com.bbflight.background_downloader.statusUpdateMap"
        const val keyProgressUpdateMap = "com.bbflight.background_downloader.progressUpdateMap"
        const val keyTempFilename = "tempFilename"
        const val keyStartByte = "startByte"
        var canceledTaskIds = HashMap<String, Long>() // <taskId, timeMillis>
        var pausedTaskIds = HashSet<String>() // <taskId>
        var backgroundChannel: MethodChannel? = null
        var backgroundChannelCounter = 0  // reference counter
        val prefsLock = ReentrantReadWriteLock()
        val gson = Gson()
        val jsonMapType = object : TypeToken<Map<String, Any>>() {}.type

        /**
         * Enqueue a WorkManager task based on the provided parameters
         */
        suspend fun doEnqueue(
                context: Context,
                taskJsonMapString: String,
                tempFilePath: String?,
                startByte: Long?,
                initialDelayMillis: Long = 0
        ): Boolean {
            val task =
                    Task(gson.fromJson(taskJsonMapString, jsonMapType))
            Log.i(TAG, "Enqueuing task with id ${task.taskId}")
            val dataBuilder =
                    Data.Builder().putString(TaskWorker.keyTask, taskJsonMapString)
            if (tempFilePath != null && startByte != null) {
                dataBuilder.putString(keyTempFilename, tempFilePath)
                        .putLong(keyStartByte, startByte)
            }
            val data = dataBuilder.build()
            val constraints = Constraints.Builder().setRequiredNetworkType(
                    if (task.requiresWiFi) NetworkType.UNMETERED else NetworkType.CONNECTED
            )
                    .build()
            val requestBuilder = OneTimeWorkRequestBuilder<TaskWorker>().setInputData(data)
                    .setConstraints(constraints).addTag(TAG)
                    .addTag("taskId=${task.taskId}")
                    .addTag("group=${task.group}")
            if (initialDelayMillis != 0L) {
                requestBuilder.setInitialDelay(initialDelayMillis, TimeUnit.MILLISECONDS)
            }
            val workManager = WorkManager.getInstance(context)
            val operation = workManager.enqueue(requestBuilder.build())
            try {
                operation.result.get()
                val prefs = PreferenceManager.getDefaultSharedPreferences(context)
                if (initialDelayMillis == 0L) {
                    TaskWorker.processStatusUpdate(task, TaskStatus
                            .enqueued,
                            prefs)
                } else {
                    delay(min(100L, initialDelayMillis))
                    TaskWorker.processStatusUpdate(task, TaskStatus.enqueued, prefs)
                }
            } catch (e: Throwable) {
                Log.w(
                        TAG,
                        "Unable to start background request for taskId ${task.taskId} in operation: $operation"
                )
                return false
            }
            // store Task in persistent storage, as Json representation keyed by taskId
            prefsLock.write {
                val prefs = PreferenceManager.getDefaultSharedPreferences(context)
                val jsonString = prefs.getString(keyTasksMap, "{}")
                val tasksMap =
                        gson.fromJson<Map<String, Any>>(jsonString, jsonMapType).toMutableMap()
                tasksMap[task.taskId] =
                        gson.toJson(task.toJsonMap())
                val editor = prefs.edit()
                editor.putString(keyTasksMap, gson.toJson(tasksMap))
                editor.apply()
            }
            return true
        }
    }

    /**
     * Attaches the plugin to the Flutter engine and performs initialization
     */
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
        context = flutterPluginBinding.applicationContext
        val workManager = WorkManager.getInstance(context)
        val prefs = PreferenceManager.getDefaultSharedPreferences(context)
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

    /** Processes the methodCall coming from Dart */
    override fun onMethodCall(call: MethodCall, result: Result) {
        runBlocking {
            when (call.method) {
                "enqueue" -> methodEnqueue(call, result)
                "reset" -> methodReset(call, result)
                "allTasks" -> methodAllTasks(call, result)
                "cancelTasksWithIds" -> methodCancelTasksWithIds(call, result)
                "taskForId" -> methodTaskForId(call, result)
                "pause" -> methodPause(call, result)
                "popResumeData" -> methodPopResumeData(result)
                "popStatusUpdates" -> methodPopStatusUpdates(result)
                "popProgressUpdates" -> methodPopProgressUpdates(result)
                "getTaskTimeout" -> methodGetTaskTimeout(result)
                else -> result.notImplemented()
            }
        }
    }

    /**
     * Starts one task, passed as map of values representing a [Task]
     *
     * Returns true if successful, and will emit a status update that the task is running.
     */
    private suspend fun methodEnqueue(call: MethodCall, result: Result) {
        val args = call.arguments as List<*>
        val taskJsonMapString = args[0] as String
        val isResume = args.size > 1
        val startByte: Long?
        val tempFilePath: String?
        if (isResume) {
            tempFilePath = args[1] as String
            startByte = if (args[2] is Long) args[2] as Long else (args[2] as Int).toLong()
        } else {
            tempFilePath = null
            startByte = null
        }
        result.success(doEnqueue(context, taskJsonMapString, tempFilePath, startByte))
    }


    /**
     * Resets the download worker by cancelling all ongoing download tasks for the group
     *
     * Returns the number of tasks canceled
     */
    private fun methodReset(call: MethodCall, result: Result) {
        val group = call.arguments as String
        var counter = 0
        val workManager = WorkManager.getInstance(context)
        val workInfos = workManager.getWorkInfosByTag(TAG).get()
                .filter { !it.state.isFinished && it.tags.contains("group=$group") }
        for (workInfo in workInfos) {
            workManager.cancelWorkById(workInfo.id)
            counter++
        }
        Log.v(TAG, "methodReset removed $counter unfinished tasks in group $group")
        result.success(counter)
    }

    /**
     * Returns a list of tasks for all tasks in progress, as a list of JSON strings
     */
    private fun methodAllTasks(call: MethodCall, result: Result) {
        val group = call.arguments as String
        val workManager = WorkManager.getInstance(context)
        val workInfos = workManager.getWorkInfosByTag(TAG).get()
                .filter { !it.state.isFinished && it.tags.contains("group=$group") }
        val tasksAsListOfJsonStrings = mutableListOf<String>()
        prefsLock.read {
            val prefs = PreferenceManager.getDefaultSharedPreferences(context)
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

    /**
     * Cancels ongoing tasks whose taskId is in the list provided with this call
     *
     * Returns true if all cancellations were successful
     */
    private suspend fun methodCancelTasksWithIds(call: MethodCall, result: Result) {
        val taskIds = call.arguments as List<*>
        val workManager = WorkManager.getInstance(context)
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
                    val prefs = PreferenceManager.getDefaultSharedPreferences(context)
                    val tasksMap = getTaskMap(prefs)
                    val taskJsonMap = tasksMap[taskId] as String?
                    if (taskJsonMap != null) {
                        val task = Task(
                                gson.fromJson(taskJsonMap, jsonMapType)
                        )
                        TaskWorker.processStatusUpdate(task, TaskStatus.canceled, prefs)
                    } else {
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
            val prefs = PreferenceManager.getDefaultSharedPreferences(context)
            val jsonString = prefs.getString(keyTasksMap, "{}")
            val tasksMap =
                    gson.fromJson<Map<String, Any>>(jsonString, jsonMapType).toMutableMap()
            result.success(tasksMap[taskId])
        }
    }

    /**
     * Marks the taskId for pausing
     *
     * The pause action is taken in the [TaskWorker]
     */
    private fun methodPause(call: MethodCall, result: Result) {
        val taskId = call.arguments as String
        Log.v(TAG, "Marking taskId $taskId for pausing")
        pausedTaskIds.add(taskId)
        result.success(true)
    }

    /**
     * Returns a JSON String of a map of [ResumeData], keyed by taskId, that has been stored
     * in local shared preferences because they could not be delivered to the Dart side.
     * Local storage of this map is then cleared
     */
    private fun methodPopResumeData(result: Result) {
        popLocalStorage(keyResumeDataMap, result)
    }

    /**
     * Returns a JSON String of a map of [Task] and [TaskStatus], keyed by taskId, stored
     * in local shared preferences because they could not be delivered to the Dart side.
     * Local storage of this map is then cleared
     */
    private fun methodPopStatusUpdates(result: Result) {
        popLocalStorage(keyStatusUpdateMap, result)
    }

    /**
     * Returns a JSON String of a map of [ResumeData], keyed by taskId, that has veen stored
     * in local shared preferences because they could not be delivered to the Dart side.
     * Local storage of this map is then cleared
     */
    private fun methodPopProgressUpdates(result: Result) {
        popLocalStorage(keyProgressUpdateMap, result)
    }

    /**
     * Pops and return locally stored map for this key
     */
    private fun popLocalStorage(prefsKey: String, result: Result) {
        prefsLock.write {
            val prefs = PreferenceManager.getDefaultSharedPreferences(context)
            val jsonString = prefs.getString(prefsKey, "{}")
            val editor = prefs.edit()
            editor.remove(prefsKey)
            editor.apply()
            result.success(jsonString)
        }
    }

    /**
     * Returns the [TaskWorker] timeout value in milliseconds
     */
    private fun methodGetTaskTimeout(result: Result) {
        result.success(TaskWorker.taskTimeoutMillis)
    }
}


