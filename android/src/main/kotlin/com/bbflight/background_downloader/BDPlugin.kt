package com.bbflight.background_downloader

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationManagerCompat
import androidx.preference.PreferenceManager
import androidx.work.*
import com.bbflight.background_downloader.TaskWorker.Companion.taskToJsonString
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
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.lang.Long.min
import java.net.MalformedURLException
import java.net.URL
import java.net.URLDecoder
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.locks.ReentrantReadWriteLock
import kotlin.concurrent.read
import kotlin.concurrent.write


/**
 * Entry-point for Android native side of the plugin
 *
 * Manages the WorkManager task queue and the interface to Dart. Actual work is done in
 * [TaskWorker]
 */
class BDPlugin : FlutterPlugin, MethodCallHandler, ActivityAware,
    PluginRegistry.RequestPermissionsResultListener {
    companion object {
        const val TAG = "BackgroundDownloader"
        const val keyTasksMap = "com.bbflight.background_downloader.taskMap.v2"
        const val keyResumeDataMap = "com.bbflight.background_downloader.resumeDataMap.v2"
        const val keyStatusUpdateMap = "com.bbflight.background_downloader.statusUpdateMap.v2"
        const val keyProgressUpdateMap = "com.bbflight.background_downloader.progressUpdateMap.v2"
        const val keyConfigForegroundFileSize =
            "com.bbflight.background_downloader.config.foregroundFileSize"
        const val keyConfigProxyAddress = "com.bbflight.background_downloader.config.proxyAddress"
        const val keyConfigProxyPort = "com.bbflight.background_downloader.config.proxyPort"
        const val keyConfigRequestTimeout =
            "com.bbflight.background_downloader.config.requestTimeout"
        const val keyConfigCheckAvailableSpace =
            "com.bbflight.background_downloader.config.checkAvailableSpace"
        const val keyConfigUseCacheDir = "com.bbflight.background_downloader.config.useCacheDir"
        const val keyConfigUseExternalStorage =
            "com.bbflight.background_downloader.config.useExternalStorage"

        @SuppressLint("StaticFieldLeak")
        var activity: Activity? = null
        var canceledTaskIds = HashMap<String, Long>() // <taskId, timeMillis>
        var pausedTaskIds = HashSet<String>() // <taskId>
        var parallelDownloadTaskWorkers = HashMap<String, ParallelDownloadTaskWorker>()
        var backgroundChannel: MethodChannel? = null
        var backgroundChannelCounter = 0  // reference counter
        var forceFailPostOnBackgroundChannel = false
        val prefsLock = ReentrantReadWriteLock()
        var localResumeData = HashMap<String, ResumeData>() // for pause notifications
        var remainingBytesToDownload = HashMap<String, Long>()
        var haveLoggedProxyMessage = false

        /**
         * Enqueue a WorkManager task based on the provided parameters
         */
        suspend fun doEnqueue(
            context: Context,
            task: Task,
            notificationConfigJsonString: String?,
            resumeData: ResumeData?,
            initialDelayMillis: Long = 0
        ): Boolean {
            Log.i(TAG, "Enqueuing task with id ${task.taskId}")
            // validate the task.url
            try {
                URL(task.url)
                withContext(Dispatchers.IO) {
                    URLDecoder.decode(task.url, "UTF-8")
                }
            } catch (e: MalformedURLException) {
                Log.i(TAG, "MalformedURLException for taskId ${task.taskId}")
                return false
            } catch (e: IllegalArgumentException) {
                Log.i(TAG, "Could not url-decode url for taskId ${task.taskId}")
                return false
            }
            canceledTaskIds.remove(task.taskId)
            val dataBuilder = Data.Builder().putString(TaskWorker.keyTask, taskToJsonString(task))
            if (notificationConfigJsonString != null) {
                dataBuilder.putString(
                    TaskWorker.keyNotificationConfig,
                    notificationConfigJsonString
                )
            }
            if (resumeData != null) {
                dataBuilder.putString(TaskWorker.keyResumeDataData, resumeData.data)
                    .putLong(TaskWorker.keyStartByte, resumeData.requiredStartByte)
                    .putString(TaskWorker.keyETag, resumeData.eTag)
            }
            val data = dataBuilder.build()
            val constraints = Constraints.Builder().setRequiredNetworkType(
                if (task.requiresWiFi) NetworkType.UNMETERED else NetworkType.CONNECTED
            ).build()
            val requestBuilder =
                if (task.isParallelDownloadTask())
                    OneTimeWorkRequestBuilder<ParallelDownloadTaskWorker>()
                else if (task.isDownloadTask()) OneTimeWorkRequestBuilder<DownloadTaskWorker>()
                else OneTimeWorkRequestBuilder<UploadTaskWorker>()
            requestBuilder.setInputData(data)
                .setConstraints(constraints).addTag(TAG).addTag("taskId=${task.taskId}")
                .addTag("group=${task.group}")
            if (initialDelayMillis != 0L) {
                requestBuilder.setInitialDelay(initialDelayMillis, TimeUnit.MILLISECONDS)
            }
            if (task.priority < 5 && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                requestBuilder.setExpedited(policy = OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
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
                val tasksMap = getTaskMap(prefs)
                tasksMap[task.taskId] = task
                val editor = prefs.edit()
                editor.putString(keyTasksMap, Json.encodeToString(tasksMap))
                editor.apply()
            }
            return true
        }

        /** cancel tasks with [taskIds] and return true if successful */
        suspend fun cancelTasksWithIds(context: Context, taskIds: Iterable<String>): Boolean {
            val workManager = WorkManager.getInstance(context)
            Log.v(TAG, "Canceling taskIds $taskIds")
            var success = true
            for (taskId in taskIds) {
                success = success && cancelActiveTaskWithId(context, taskId, workManager)
            }
            return success
        }

        /**
         * Cancel task with [taskId] and return true if successful
         *
         * The [taskId] must be managed by the [workManager]
         */
        suspend fun cancelActiveTaskWithId(
            context: Context, taskId: String, workManager: WorkManager
        ): Boolean {
            // cancel chunk tasks if this is a ParallelDownloadTask
            parallelDownloadTaskWorkers[taskId]?.cancelAllChunkTasks()
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
                    // and remove associated notification
                    prefsLock.write {
                        val prefs = PreferenceManager.getDefaultSharedPreferences(context)
                        val tasksMap = getTaskMap(prefs)
                        val task = tasksMap[taskId]
                        if (task != null) {
                            TaskWorker.processStatusUpdate(task, TaskStatus.canceled, prefs)
                            // remove outstanding notification for task or group
                            val notificationGroup =
                                NotificationService.groupNotificationWithTaskId(taskId)
                            with(NotificationManagerCompat.from(context)) {
                                if (notificationGroup == null) {
                                    cancel(task.taskId.hashCode())
                                } else {
                                    // update notification for group
                                    NotificationService.createUpdateNotificationWorker(
                                        context,
                                        Json.encodeToString(task),
                                        Json.encodeToString(notificationGroup.notificationConfig),
                                        TaskStatus.canceled.ordinal
                                    )
                                }
                            }
                        } else {
                            Log.d(TAG, "Could not find task with taskId $taskId to cancel")
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
                "updateNotification" -> methodUpdateNotification(call, result)
                "moveToSharedStorage" -> methodMoveToSharedStorage(call, result)
                "pathInSharedStorage" -> methodPathInSharedStorage(call, result)
                "openFile" -> methodOpenFile(call, result)
                // ParallelDownloadTask child updates
                "chunkStatusUpdate" -> methodUpdateChunkStatus(call, result)
                "chunkProgressUpdate" -> methodUpdateChunkProgress(call, result)
                // Permissions
                "permissionStatus" -> methodPermissionStatus(call, result)
                "requestPermission" -> methodRequestPermission(call, result)
                "shouldShowPermissionRationale" -> methodShouldShowPermissionRationale(call, result)
                // internal use
                "popResumeData" -> methodPopResumeData(result)
                "popStatusUpdates" -> methodPopStatusUpdates(result)
                "popProgressUpdates" -> methodPopProgressUpdates(result)
                "getTaskTimeout" -> methodGetTaskTimeout(result)
                // configuration
                "configForegroundFileSize" -> methodConfigForegroundFileSize(call, result)
                "configProxyAddress" -> methodConfigProxyAddress(call, result)
                "configProxyPort" -> methodConfigProxyPort(call, result)
                "configRequestTimeout" -> methodConfigRequestTimeout(call, result)
                "configBypassTLSCertificateValidation" -> methodConfigBypassTLSCertificateValidation(
                    result
                )

                "configCheckAvailableSpace" -> methodConfigCheckAvailableSpace(call, result)
                "configUseCacheDir" -> methodConfigUseCacheDir(call, result)
                "configUseExternalStorage" -> methodConfigUseExternalStorage(call, result)
                "platformVersion" -> methodPlatformVersion(result)
                "forceFailPostOnBackgroundChannel" -> methodForceFailPostOnBackgroundChannel(
                    call, result
                )

                "testSuggestedFilename" -> methodTestSuggestedFilename(call, result)
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
        // by tempFilePath, startByte and eTag if this enqueue is a resume from pause
        val args = call.arguments as List<*>
        val taskJsonMapString = args[0] as String
        val task = Json.decodeFromString<Task>(taskJsonMapString)
        val notificationConfigJsonString = args[1] as String?
        val isResume = args.size == 5
        val resumeData: ResumeData? = if (isResume) {
            val startByte = if (args[3] is Long) args[3] as Long else (args[3] as Int).toLong()
            val eTag = args[4] as String?
            ResumeData(task, args[2] as String, startByte, eTag)
        } else {
            null
        }
        result.success(
            doEnqueue(
                applicationContext,
                task,
                notificationConfigJsonString,
                resumeData,
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
            val tasksMap = getTaskMap(prefs)
            for (workInfo in workInfos) {
                val tags = workInfo.tags.filter { it.contains("taskId=") }
                if (tags.isNotEmpty()) {
                    val taskId = tags.first().substring(7)
                    val task = tasksMap[taskId]
                    if (task != null) {
                        tasksAsListOfJsonStrings.add(Json.encodeToString(task))
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
        result.success(cancelTasksWithIds(applicationContext, taskIds))
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
            val tasksMap = getTaskMap(prefs)
            val task = tasksMap[taskId]
            if (task != null) {
                result.success(Json.encodeToString(tasksMap[taskId]))
            } else {
                result.success(null)
            }
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
     * Update the notification for this task
     *
     * Args are:
     * - task
     * - notificationConfig (cannot be null)
     * - taskStatus as ordinal in TaskStatus enum. If null, delete the notification
     */
    private fun methodUpdateNotification(call: MethodCall, result: Result) {
        val args = call.arguments as List<*>
        val taskJsonMapString = args[0] as String
        val notificationConfigJsonString = args[1] as String
        val taskStatusOrdinal = args[2] as Int?
        NotificationService.createUpdateNotificationWorker(
            applicationContext,
            taskJsonMapString,
            notificationConfigJsonString,
            taskStatusOrdinal
        )
        result.success(null)
    }


    /**
     * Returns a JSON String of a map of [ResumeData], keyed by taskId, that has been stored
     * in local shared preferences because they could not be delivered to the Dart side.
     * Local storage of this map is then cleared
     */
    private fun methodPopResumeData(result: Result) {
        popLocalStorage(
            keyResumeDataMap,
            result
        )
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
     * Pops and returns locally stored data for this key as a JSON String, via the FlutterResult
     *
     * The Json string represents a Map, keyed by TaskId, where each item is a Json representation
     * of the object stored, e.g. a [TaskStatusUpdate]
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
        val status = PermissionsService.getPermissionStatus(
            applicationContext,
            PermissionType.androidSharedStorage
        )
        if (status == PermissionStatus.granted) {
            result.success(
                moveToSharedStorage(
                    applicationContext,
                    filePath,
                    destination,
                    directory,
                    mimeType
                )
            )
        } else {
            Log.i(TAG, "No permission to move to shared storage")
            result.success(false)
        }
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
        val task =
            if (taskJsonMapString != null) Json.decodeFromString<Task>(taskJsonMapString) else null
        val filePath = args[1] as String? ?: task!!.filePath(applicationContext)
        val mimeType = args[2] as String? ?: getMimeType(filePath)
        result.success(if (activity != null) doOpenFile(activity!!, filePath, mimeType) else false)
    }

    /**
     * Update the status of one chunk (part of a ParallelDownloadTask), and returns
     * the status of the parent task based on the 'sum' of its children, or null
     * if unchanged
     *
     * Arguments are the parent TaskId, chunk taskId, taskStatusOrdinal
     */
    private suspend fun methodUpdateChunkStatus(call: MethodCall, result: Result) {
        val args = call.arguments as List<*>
        val taskId = args[0] as String
        val chunkTaskId = args[1] as String
        val statusOrdinal = args[2] as Int
        val exceptionJson = args[3] as String?
        val exception = if (exceptionJson != null) {
            TaskException(
                Json.decodeFromString<Map<String, Any>>(exceptionJson)
            )
        } else null
        val responseBody = args[4] as String?
        parallelDownloadTaskWorkers[taskId]?.chunkStatusUpdate(
            chunkTaskId,
            TaskStatus.values()[statusOrdinal],
            exception,
            responseBody
        )
        result.success(null)
    }

    /**
     * Update the progress of one chunk (part of a ParallelDownloadTask), and returns
     * the progress of the parent task based on the average of its children
     *
     * Arguments are the parent [TaskId, chunk taskId, progress]
     */
    private suspend fun methodUpdateChunkProgress(call: MethodCall, result: Result) {
        val args = call.arguments as List<*>
        val taskId = args[0] as String
        val chunkTaskId = args[1] as String
        val progress = args[2] as Double
        parallelDownloadTaskWorkers[taskId]?.chunkProgressUpdate(
            chunkTaskId,
            progress
        )
        result.success(null)
    }

    /**
     * Return [PermissionStatus] for this [PermissionType]
     */
    private fun methodPermissionStatus(call: MethodCall, result: Result) {
        val permissionType = PermissionType.values()[call.arguments as Int]
        result.success(
            PermissionsService.getPermissionStatus(
                applicationContext,
                permissionType
            ).ordinal
        )
    }

    /**
     * Request permission for this [PermissionType]
     *
     * Returns true if request was submitted successfully, and the
     * Flutter side should wait for completion via the background
     * channel method "permissionRequestResult"
     */
    private fun methodRequestPermission(call: MethodCall, result: Result) {
        val permissionType = PermissionType.values()[call.arguments as Int]
        result.success(PermissionsService.requestPermission(permissionType))
    }

    /**
     * Returns true if you should show a rationale for this [PermissionType]
     */
    private fun methodShouldShowPermissionRationale(call: MethodCall, result: Result) {
        val permissionType = PermissionType.values()[call.arguments as Int]
        result.success(PermissionsService.shouldShowRequestPermissionRationale(permissionType))
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
     * Store foregroundFileSize in shared preferences
     *
     * The value is in MB, or -1 to disable foreground always, and
     * is retrieved in [TaskWorker.doWork]
     */
    private fun methodConfigForegroundFileSize(call: MethodCall, result: Result) {
        val fileSize = call.arguments as Int
        updateSharedPreferences(keyConfigForegroundFileSize, fileSize)
        val msg = when (fileSize) {
            0 -> "Enabled foreground mode for all tasks"
            -1 -> "Disabled foreground mode for all tasks"
            else -> "Set foreground file size threshold to $fileSize MB"
        }
        Log.v(TAG, msg)
        result.success(null)
    }

    /**
     * Store the proxy address config in shared preferences
     */
    private fun methodConfigProxyAddress(call: MethodCall, result: Result) {
        PreferenceManager.getDefaultSharedPreferences(applicationContext).edit().apply {
            val address = call.arguments as String?
            if (address != null) {
                putString(keyConfigProxyAddress, address)
            } else {
                remove(keyConfigProxyAddress)
            }
            apply()
        }
        result.success(null)
    }

    /**
     * Store the proxy port config in shared preferences
     */
    private fun methodConfigProxyPort(call: MethodCall, result: Result) {
        updateSharedPreferences(keyConfigProxyPort, call.arguments as Int?)
        result.success(null)
    }

    /**
     * Store the requestTimeout config in shared preferences
     */
    private fun methodConfigRequestTimeout(call: MethodCall, result: Result) {
        updateSharedPreferences(keyConfigRequestTimeout, call.arguments as Int?)
        result.success(null)
    }

    /**
     * Bypass the certificate validation
     */
    private fun methodConfigBypassTLSCertificateValidation(result: Result) {
        acceptUntrustedCertificates()
        result.success(null)
    }

    /**
     * Store the availableSpace config in shared preferences
     */
    private fun methodConfigCheckAvailableSpace(call: MethodCall, result: Result) {
        updateSharedPreferences(keyConfigCheckAvailableSpace, call.arguments as Int?)
        result.success(null)
    }

    /**
     * Store the useCacheDir config in shared preferences
     */
    private fun methodConfigUseCacheDir(call: MethodCall, result: Result) {
        updateSharedPreferences(keyConfigUseCacheDir, call.arguments as Int?)
        result.success(null)
    }

    /**
     * Store the useExternalStorage config in shared preferences
     */
    private fun methodConfigUseExternalStorage(call: MethodCall, result: Result) {
        updateSharedPreferences(keyConfigUseExternalStorage, call.arguments as Int?)
        result.success(null)
    }

    /**
     * Return the Android API version integer as a String
     */
    private fun methodPlatformVersion(result: Result) {
        result.success("${Build.VERSION.SDK_INT}")
    }


    /**
     * Sets or resets flag to force failing posting on background channel
     *
     * For testing only
     * Arguments are
     * - task as Json String
     * - content disposition, or empty for none
     *
     * Returns suggested filename for this task, based on the task & content disposition
     */
    private fun methodForceFailPostOnBackgroundChannel(call: MethodCall, result: Result) {
        forceFailPostOnBackgroundChannel = call.arguments as Boolean
        result.success(null)
    }

    /**
     * Tests the content-disposition and url translation
     *
     * For testing only
     *
     */
    private suspend fun methodTestSuggestedFilename(call: MethodCall, result: Result) {
        val args = call.arguments as List<*>
        val taskJsonMapString = args[0] as String
        val contentDisposition = args[1] as String
        val task = Json.decodeFromString<Task>(taskJsonMapString)
        val h = if (contentDisposition.isNotEmpty()) mutableMapOf(
            "Content-Disposition" to mutableListOf(contentDisposition)
        ) else mutableMapOf("" to mutableListOf())
        val t = task.withSuggestedFilenameFromResponseHeaders(applicationContext, h)
        result.success(t.filename)
    }

    /**
     * Helper function to update or delete the [value] in shared preferences under [key]
     *
     * If [value] is null, the [key] is deleted
     */
    private fun updateSharedPreferences(key: String, value: Int?) {
        PreferenceManager.getDefaultSharedPreferences(applicationContext).edit().apply {
            if (value != null) {
                putInt(key, value)
            } else {
                remove(key)
            }
            apply()
        }
        Log.d(TAG, "Setting preference key $key to $value")
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
            val taskJsonMapString = intent.getStringExtra(NotificationRcvr.keyTask)
            val notificationTypeOrdinal =
                intent.getIntExtra(NotificationRcvr.keyNotificationType, 0)
            val notificationId = intent.getIntExtra(NotificationRcvr.keyNotificationId, 0)
            CoroutineScope(Dispatchers.Default).launch {
                var retries = 0
                var success = false
                while (retries < 5 && !success) {
                    try {
                        if (backgroundChannel != null && scope != null) {
                            val resultCompleter = CompletableFuture<Boolean>()
                            val resultHandler = ResultHandler(resultCompleter)
                            scope?.launch {
                                backgroundChannel?.invokeMethod(
                                    "notificationTap",
                                    listOf(taskJsonMapString, notificationTypeOrdinal),
                                    resultHandler
                                )
                            }
                            success = resultCompleter.join()
                        }
                    } catch (e: Exception) {
                        Log.v(TAG, "Exception in handleIntent: $e")
                    }
                    if (!success) {
                        delay(timeMillis = 100L shl (retries))
                        retries++
                    }
                }
            }
            // check for 'tapOpensFile'
            if (notificationTypeOrdinal == NotificationType.complete.ordinal) {
                val task = Json.decodeFromString<Task>(taskJsonMapString!!)
                val notificationConfigJsonString =
                    intent.extras?.getString(NotificationRcvr.keyNotificationConfig)
                val notificationConfig =
                    if (notificationConfigJsonString != null) Json.decodeFromString<NotificationConfig>(
                        notificationConfigJsonString
                    )
                    else null
                if (notificationConfig?.tapOpensFile == true && activity != null) {
                    val filePath = task.filePath(activity!!)
                    doOpenFile(activity!!, filePath, getMimeType(filePath))
                }
            }
            // dismiss notification if it is a 'complete' or 'error' notification
            if (notificationId != 0 &&
                (notificationTypeOrdinal == NotificationType.complete.ordinal || notificationTypeOrdinal == NotificationType.error.ordinal)
            ) {
                with(NotificationManagerCompat.from(applicationContext)) {
                    cancel(notificationId)
                }
            }
            return true
        }
        return false
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        attach(binding)
        handleIntent(binding.activity.intent)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        detach()
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        attach(binding)
    }

    override fun onDetachedFromActivity() {
        detach()
    }


    /**
     * Attach to activity
     */
    private fun attach(binding: ActivityPluginBinding) {
        detach()
        activity = binding.activity
        scope = MainScope()
        binding.addRequestPermissionsResultListener(this)
        binding.addOnNewIntentListener(fun(intent: Intent?): Boolean {
            return handleIntent(intent)
        })
    }

    /**
     * Detach from activity
     */
    private fun detach() {
        activity = null
        scope?.cancel()
        scope = null
    }

    /**
     * Receives onRequestPermissionsResult and passes this to the
     * [PermissionsService]
     */

    override fun onRequestPermissionsResult(
        requestCode: Int, permissions: Array<out String>, grantResults: IntArray
    ): Boolean {
        return PermissionsService.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }
}

/**
 * Simple Flutter result handler, completes the [completer] with the result
 * of the MethodChannel call
 */
class ResultHandler(private val completer: CompletableFuture<Boolean>) : Result {

    override fun success(result: Any?) {
        completer.complete(result == true)
    }

    override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
        Log.i(BDPlugin.TAG, "Flutter result error $errorCode: $errorMessage")
        completer.complete(false)
    }

    override fun notImplemented() {
        Log.i(BDPlugin.TAG, "Flutter method not implemented")
        completer.complete(false)
    }

}
