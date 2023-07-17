package com.bbflight.background_downloader

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import android.util.Patterns
import androidx.core.app.ActivityCompat
import androidx.preference.PreferenceManager
import androidx.work.*
import com.bbflight.background_downloader.TaskWorker.Companion.keyNotificationConfig
import com.bbflight.background_downloader.TaskWorker.Companion.keyStartByte
import com.bbflight.background_downloader.TaskWorker.Companion.keyTempFilename
import com.google.gson.Gson
import com.google.gson.reflect.TypeToken
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import java.lang.Long.min
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.locks.ReentrantReadWriteLock
import kotlin.concurrent.read
import kotlin.concurrent.write
import kotlin.math.pow


/**
 * Entry-point for Android native side of the plugin
 *
 * Manages the WorkManager task queue and the interface to Dart. Actual work is done in
 * [TaskWorker]
 */
class BackgroundDownloaderPlugin : FlutterPlugin, MethodCallHandler, ActivityAware,
    PluginRegistry.RequestPermissionsResultListener {
    companion object {
        const val TAG = "BackgroundDownloader"
        const val keyTasksMap = "com.bbflight.background_downloader.taskMap"
        const val keyResumeDataMap = "com.bbflight.background_downloader.resumeDataMap"
        const val keyStatusUpdateMap = "com.bbflight.background_downloader.statusUpdateMap"
        const val keyProgressUpdateMap = "com.bbflight.background_downloader.progressUpdateMap"
        const val notificationChannel = "background_downloader"
        const val notificationPermissionRequestCode = 373921
        const val externalStoragePermissionRequestCode = 373922

        @SuppressLint("StaticFieldLeak")
        var activity: Activity? = null
        var canceledTaskIds = HashMap<String, Long>() // <taskId, timeMillis>
        var pausedTaskIds = HashSet<String>() // <taskId>
        var backgroundChannel: MethodChannel? = null
        var backgroundChannelCounter = 0  // reference counter
        var forceFailPostOnBackgroundChannel = false
        val prefsLock = ReentrantReadWriteLock()
        val gson = Gson()
        val jsonMapType = object : TypeToken<Map<String, Any>>() {}.type
        var requestingNotificationPermission = false
        var externalStoragePermissionCompleter = CompletableFuture<Boolean>()
        var localResumeData = HashMap<String, ResumeData>()

        /**
         * Enqueue a WorkManager task based on the provided parameters
         */
        suspend fun doEnqueue(
            context: Context,
            taskJsonMapString: String,
            notificationConfigJsonString: String?,
            tempFilePath: String?,
            startByte: Long?,
            initialDelayMillis: Long = 0
        ): Boolean {
            val task = Task(gson.fromJson(taskJsonMapString, jsonMapType))
            Log.i(TAG, "Enqueuing task with id ${task.taskId}")
            if (!Patterns.WEB_URL.matcher(task.url).matches()) {
                Log.i(TAG, "Invalid url: ${task.url}")
                return false
            }
            canceledTaskIds.remove(task.taskId)
            val dataBuilder = Data.Builder().putString(TaskWorker.keyTask, taskJsonMapString)
            if (notificationConfigJsonString != null) {
                dataBuilder.putString(keyNotificationConfig, notificationConfigJsonString)
            }
            if (tempFilePath != null && startByte != null) {
                dataBuilder.putString(keyTempFilename, tempFilePath)
                    .putLong(keyStartByte, startByte)
            }
            val data = dataBuilder.build()
            val constraints = Constraints.Builder().setRequiredNetworkType(
                if (task.requiresWiFi) NetworkType.UNMETERED else NetworkType.CONNECTED
            ).build()
            val requestBuilder = OneTimeWorkRequestBuilder<TaskWorker>().setInputData(data)
                .setConstraints(constraints).addTag(TAG).addTag("taskId=${task.taskId}")
                .addTag("group=${task.group}")
            if (initialDelayMillis != 0L) {
                requestBuilder.setInitialDelay(initialDelayMillis, TimeUnit.MILLISECONDS)
            }
            val workManager = WorkManager.getInstance(context)
            val operation = workManager.enqueue(requestBuilder.build())
            try {
                withContext(Dispatchers.IO) {
                    operation.result.get()
                }
                val prefs = PreferenceManager.getDefaultSharedPreferences(context)
                if (initialDelayMillis == 0L) {
                    TaskWorker.processStatusUpdate(
                        task, TaskStatus.enqueued, prefs
                    )
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
                tasksMap[task.taskId] = gson.toJson(task.toJsonMap())
                val editor = prefs.edit()
                editor.putString(keyTasksMap, gson.toJson(tasksMap))
                editor.apply()
            }
            return true
        }

        /**
         * Cancel task with [taskId] and return true if successful
         *
         * The [taskId] must be managed by the [workManager]
         */
        suspend fun cancelActiveTaskWithId(
            context: Context, taskId: String, workManager: WorkManager
        ): Boolean {
            val workInfos = withContext(Dispatchers.IO) {
                workManager.getWorkInfosByTag("taskId=$taskId").get()
            }
            if (workInfos.isEmpty()) {
                Log.d(TAG, "Could not find tasks to cancel")
                return false
            }
            for (workInfo in workInfos) {
                if (workInfo.state != WorkInfo.State.SUCCEEDED) {
                    // send cancellation update for tasks that have not yet succeeded
                    Log.d(TAG, "Canceling active task and sending status update")
                    prefsLock.write {
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
            }
            val operation = workManager.cancelAllWorkByTag("taskId=$taskId")
            try {
                withContext(Dispatchers.IO) {
                    operation.result.get()
                }
            } catch (e: Throwable) {
                Log.w(TAG, "Unable to cancel taskId $taskId in operation: $operation")
                return false
            }
            return true
        }

        /**
         * Cancel [task] that is not active
         *
         * Because this [task] is not managed by a [WorkManager] it is cancelled directly. This
         * is normally called from a notification when the task is paused (which is why it is
         * inactive), and therefore the caller must remove the notification that triggered the
         * cancellation. See [NotificationRcvr]
         */
        suspend fun cancelInactiveTask(context: Context, task: Task) {
            prefsLock.write {
                Log.d(TAG, "Canceling inactive task")
                val prefs = PreferenceManager.getDefaultSharedPreferences(context)
                TaskWorker.processStatusUpdate(task, TaskStatus.canceled, prefs)
            }
        }

        /**
         * Pause the task with this [taskId]
         *
         * Marks the task for pausing, actual pausing happens in [TaskWorker]
         */
        fun pauseTaskWithId(taskId: String): Boolean {
            Log.v(TAG, "Marking taskId $taskId for pausing")
            pausedTaskIds.add(taskId)
            return true
        }
    }

    private var channel: MethodChannel? = null
    private lateinit var applicationContext: Context
    private var pauseReceiver: NotificationRcvr? = null
    private var resumeReceiver: NotificationRcvr? = null
    private var scope: CoroutineScope? = null

    /**
     * Attaches the plugin to the Flutter engine and performs initialization
     */
    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        // create channels and handler
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
            flutterPluginBinding.binaryMessenger, "com.bbflight.background_downloader"
        )
        channel?.setMethodCallHandler(this)
        // set context and register notification broadcast receivers
        applicationContext = flutterPluginBinding.applicationContext
        // clear expired items
        val workManager = WorkManager.getInstance(applicationContext)
        val prefs = PreferenceManager.getDefaultSharedPreferences(applicationContext)
        val allWorkInfos = workManager.getWorkInfosByTag(TAG).get()
        if (allWorkInfos.isEmpty()) {
            // remove persistent storage if no jobs found at all
            val editor = prefs.edit()
            editor.remove(keyTasksMap)
            editor.apply()
        }
    }


    /**
     * Free up resources.
     *
     * BackgroundChannel is only released if no more references to an engine
     * */
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        backgroundChannelCounter--
        if (backgroundChannelCounter == 0) {
            backgroundChannel = null
        }
        if (pauseReceiver != null) {
            applicationContext.unregisterReceiver(pauseReceiver)
            pauseReceiver = null
        }
        if (resumeReceiver != null) {
            applicationContext.unregisterReceiver(resumeReceiver)
            resumeReceiver = null
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
                "killTaskWithId" -> methodKillTaskWithId(call, result)
                "taskForId" -> methodTaskForId(call, result)
                "pause" -> methodPause(call, result)
                "popResumeData" -> methodPopResumeData(result)
                "popStatusUpdates" -> methodPopStatusUpdates(result)
                "popProgressUpdates" -> methodPopProgressUpdates(result)
                "getTaskTimeout" -> methodGetTaskTimeout(result)
                "moveToSharedStorage" -> methodMoveToSharedStorage(call, result)
                "pathInSharedStorage" -> methodPathInSharedStorage(call, result)
                "openFile" -> methodOpenFile(call, result)
                "forceFailPostOnBackgroundChannel" -> methodForceFailPostOnBackgroundChannel(
                    call, result
                )

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
        // Arguments are a list of Task, NotificationConfig?, optionally followed
        // by tempFilePath and startByte if this enqueue is a resume from pause
        val args = call.arguments as List<*>
        val taskJsonMapString = args[0] as String
        val notificationConfigJsonString = args[1] as String?
        val isResume = args.size == 4
        val startByte: Long?
        val tempFilePath: String?
        if (isResume) {
            tempFilePath = args[2] as String
            startByte = if (args[3] is Long) args[3] as Long else (args[3] as Int).toLong()
        } else {
            tempFilePath = null
            startByte = null
        }
        result.success(
            doEnqueue(
                applicationContext,
                taskJsonMapString,
                notificationConfigJsonString,
                tempFilePath,
                startByte
            )
        )
    }


    /**
     * Resets the download worker by cancelling all ongoing download tasks for the group
     *
     * Returns the number of tasks canceled
     */
    private fun methodReset(call: MethodCall, result: Result) {
        val group = call.arguments as String
        var counter = 0
        val workManager = WorkManager.getInstance(applicationContext)
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
        val workManager = WorkManager.getInstance(applicationContext)
        val workInfos = workManager.getWorkInfosByTag(TAG).get()
            .filter { !it.state.isFinished && it.tags.contains("group=$group") }
        val tasksAsListOfJsonStrings = mutableListOf<String>()
        prefsLock.read {
            val prefs = PreferenceManager.getDefaultSharedPreferences(applicationContext)
            val jsonString = prefs.getString(keyTasksMap, "{}")
            val tasksMap = gson.fromJson<Map<String, Any>>(jsonString, jsonMapType)
            for (workInfo in workInfos) {
                val tags = workInfo.tags.filter { it.contains("taskId=") }
                if (tags.isNotEmpty()) {
                    val taskId = tags.first().substring(7)
                    val taskAsJsonString = tasksMap[taskId]
                    if (taskAsJsonString != null) {
                        tasksAsListOfJsonStrings.add(taskAsJsonString as String)
                    }
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
        @Suppress("UNCHECKED_CAST") val taskIds = call.arguments as List<String>
        val workManager = WorkManager.getInstance(applicationContext)
        Log.v(TAG, "Canceling taskIds $taskIds")
        var success = true
        for (taskId in taskIds) {
            success = success && cancelActiveTaskWithId(applicationContext, taskId, workManager)
        }
        result.success(success)
    }

    /**
     * Kills task with taskId provided as argument in call
     *
     * Killing differs from canceling in that it only removes the task from the WorkManager
     * schedule, without emitting any status updates. It is used to prevent the WorkManager from
     * rescheduling WorkManager tasks that are canceled because a constraint is no longer met, e.g.
     * network disconnect. We want to handle such errors ourselves, using our retry mechanism,
     * and not let the WorkManager reschedule those tasks.  The killTask method is therefore called
     * whenever a task emits a 'failed' update, as we have no way to determine if the task failed
     * with the worker 'SUCCESS' or with the worker 'CANCELED'
     */
    private fun methodKillTaskWithId(call: MethodCall, result: Result) {
        val taskId = call.arguments as String
        val workManager = WorkManager.getInstance(applicationContext)
        val operation = workManager.cancelAllWorkByTag("taskId=$taskId")
        try {
            operation.result.get()
        } catch (e: Throwable) {
            Log.w(
                TAG,
                "Could not kill task wih id $taskId in operation: $operation"
            )
        }
        result.success(null)
    }

    /** Returns Task for this taskId, or nil */
    private fun methodTaskForId(call: MethodCall, result: Result) {
        val taskId = call.arguments as String
        Log.v(TAG, "Returning task for taskId $taskId")
        prefsLock.read {
            val prefs = PreferenceManager.getDefaultSharedPreferences(applicationContext)
            val jsonString = prefs.getString(keyTasksMap, "{}")
            val tasksMap = gson.fromJson<Map<String, Any>>(jsonString, jsonMapType).toMutableMap()
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
        result.success(pauseTaskWithId(taskId))
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
     * Returns a JSON String of a map of [ResumeData], keyed by taskId, that has been stored
     * in local shared preferences because they could not be delivered to the Dart side.
     * Local storage of this map is then cleared
     */
    private fun methodPopProgressUpdates(result: Result) {
        popLocalStorage(keyProgressUpdateMap, result)
    }

    /**
     * Pops and returns locally stored map for this key as a JSON String, via the FlutterResult
     */
    private fun popLocalStorage(prefsKey: String, result: Result) {
        prefsLock.write {
            val prefs = PreferenceManager.getDefaultSharedPreferences(applicationContext)
            val jsonString = prefs.getString(prefsKey, "{}")
            val editor = prefs.edit()
            editor.remove(prefsKey)
            editor.apply()
            result.success(jsonString)
        }
    }

    /**
     * Move a file to Android scoped/shared storage and return the path to that file, or null
     *
     * Call arguments:
     * - filePath (String): full path to file to be moved
     * - destination (Int as index into [SharedStorage] enum)
     * - directory (String): subdirectory within scoped storage
     * - mimeType (String?): mimeType of the file, overrides derived mimeType
     */
    private fun methodMoveToSharedStorage(call: MethodCall, result: Result) {
        val args = call.arguments as List<*>
        val filePath = args[0] as String
        val destination = SharedStorage.values()[args[1] as Int]
        val directory = args[2] as String
        val mimeType = args[3] as String?
        // first check and potentially ask for permissions
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q && ActivityCompat.checkSelfPermission(
                applicationContext, Manifest.permission.WRITE_EXTERNAL_STORAGE
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            if (activity != null) {
                activity?.requestPermissions(
                    arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE),
                    externalStoragePermissionRequestCode
                )
                externalStoragePermissionCompleter.thenApplyAsync {
                    result.success(
                        moveToSharedStorage(
                            applicationContext, filePath, destination, directory, mimeType
                        )
                    )
                }
                return
            }
        }
        result.success(
            moveToSharedStorage(
                applicationContext,
                filePath,
                destination,
                directory,
                mimeType
            )
        )
    }

    /**
     * Returns path to file in Android scoped/shared storage, or null
     *
     * Call arguments:
     * - filePath (String): full path to file (only the name is used)
     * - destination (Int as index into [SharedStorage] enum)
     * - directory (String): subdirectory within scoped storage (ignored for Q+)
     *
     * For Android Q+ uses the MediaStore, matching on filename only, i.e. ignoring
     * the directory
     */
    private fun methodPathInSharedStorage(call: MethodCall, result: Result) {
        val args = call.arguments as List<*>
        val filePath = args[0] as String
        val destination = SharedStorage.values()[args[1] as Int]
        val directory = args[2] as String
        result.success(pathInSharedStorage(applicationContext, filePath, destination, directory))
    }

    /**
     * Open the file represented by the task, with optional mimeType
     *
     * Call arguments are [taskJsonMapString, filename, mimeType] with precondition that either
     * task or filename is not null
     */
    private fun methodOpenFile(call: MethodCall, result: Result) {
        val args = call.arguments as List<*>
        val taskJsonMapString = args[0] as String?
        val task = if (taskJsonMapString != null) Task(
            Gson().fromJson(taskJsonMapString, jsonMapType)
        ) else null
        val filePath = args[1] as String? ?: task!!.filePath(applicationContext)
        val mimeType = args[2] as String? ?: getMimeType(filePath)
        result.success(if (activity != null) doOpenFile(activity!!, filePath, mimeType) else false)
    }

    /**
     * Returns the [TaskWorker] timeout value in milliseconds
     *
     * For testing only
     */
    private fun methodGetTaskTimeout(result: Result) {
        result.success(TaskWorker.taskTimeoutMillis)
    }

    /**
     * Sets or resets flag to force failing posting on background channel
     *
     * For testing only
     */
    private fun methodForceFailPostOnBackgroundChannel(call: MethodCall, result: Result) {
        forceFailPostOnBackgroundChannel = call.arguments as Boolean
        result.success(null)
    }

    // ActivityAware implementation to capture Activity context needed for permissions and intents

    /**
     * Handle intent if received from tapping a notification
     *
     * This may be called on startup of the application and at that time the [backgroundChannel] and
     * its listener may not have been initialized yet. This function therefore includes retry logic.
     */
    private fun handleIntent(intent: Intent?): Boolean {
        if (intent != null && intent.action == NotificationRcvr.actionTap) {
            val taskJsonMapString =
                intent.extras?.getString(NotificationRcvr.bundleTask)
            val notificationTypeOrdinal =
                intent.getIntExtra(NotificationRcvr.bundleNotificationType, 0)
            scope?.launch {
                var retries = 0
                var success = false
                while (retries < 5 && !success) {
                    try {
                        if (backgroundChannel != null) {
                            backgroundChannel?.invokeMethod(
                                "notificationTap",
                                listOf(taskJsonMapString, notificationTypeOrdinal)
                            )
                            success = true
                        }
                    } catch (_: Exception) {
                    }
                    if (retries < 4 && !success) {
                        delay(timeMillis = 100 * 2.0.pow(retries).toLong())
                        retries++
                    }
                }
            }
            // check for 'tapOpensFile'
            if (notificationTypeOrdinal == NotificationType.complete.ordinal) {
                val task = Task(gson.fromJson(taskJsonMapString, jsonMapType))
                val notificationConfigJsonString =
                    intent.extras?.getString(NotificationRcvr.bundleNotificationConfig)
                val notificationConfig =
                    if (notificationConfigJsonString != null) gson.fromJson(
                        notificationConfigJsonString, NotificationConfig::class.java
                    ) else null
                if (notificationConfig?.tapOpensFile == true && activity != null) {
                    val filePath = task.filePath(activity!!)
                    doOpenFile(activity!!, filePath, getMimeType(filePath))
                }
            }
            return true
        }
        return false
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        scope = MainScope()
        binding.addRequestPermissionsResultListener(this)
        binding.addOnNewIntentListener(fun(intent: Intent?): Boolean {
            return handleIntent(intent)
        })
        handleIntent(binding.activity.intent)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivity() {
        activity = null
        scope?.cancel()
        scope = null
    }

    override fun onRequestPermissionsResult(
        requestCode: Int, permissions: Array<out String>, grantResults: IntArray
    ): Boolean {
        val granted =
            (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED)
        return when (requestCode) {
            notificationPermissionRequestCode -> {
                requestingNotificationPermission = false
                true
            }

            externalStoragePermissionRequestCode -> {
                externalStoragePermissionCompleter.complete(granted)
                true
            }

            else -> {
                false
            }
        }
    }
}
