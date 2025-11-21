package com.bbflight.background_downloader

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.edit
import androidx.preference.PreferenceManager
import androidx.work.Constraints
import androidx.work.Data
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy
import androidx.work.WorkInfo
import androidx.work.WorkManager
import com.bbflight.background_downloader.BDPlugin.Companion.backgroundChannel
import com.bbflight.background_downloader.TaskWorker.Companion.processStatusUpdate
import com.bbflight.background_downloader.TaskWorker.Companion.taskToJsonString
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.lang.Long.min
import java.net.MalformedURLException
import java.net.URL
import java.net.URLDecoder
import java.util.Collections
import java.util.concurrent.TimeUnit
import java.util.concurrent.locks.ReentrantReadWriteLock
import kotlin.concurrent.read
import kotlin.concurrent.write
import androidx.work.OneTimeWorkRequest


/**
 * Custom exception for method call errors
 */
class MethodCallException(val errorCode: String, val errorMessage: String?, val errorDetails: Any?) :
    Exception(errorMessage)

/**
 * Entry-point for Android native side of the plugin
 *
 * Manages the WorkManager task queue and the interface to Dart. Actual work is done in
 * [TaskWorker]
 */
@Suppress("ConstPropertyName")
class BDPlugin : FlutterPlugin, MethodCallHandler, ActivityAware,
    PluginRegistry.ActivityResultListener,
    PluginRegistry.RequestPermissionsResultListener {
    companion object {
        const val TAG = "BackgroundDownloader"
        const val keyTasksMap = "com.bbflight.background_downloader.taskMap.v2"
        const val keyResumeDataMap = "com.bbflight.background_downloader.resumeDataMap.v2"
        const val keyStatusUpdateMap = "com.bbflight.background_downloader.statusUpdateMap.v2"
        const val keyProgressUpdateMap = "com.bbflight.background_downloader.progressUpdateMap.v2"
        const val keyRequireWiFi =
            "com.bbflight.background_downloader.requireWifi"
        const val keyCallbackDispatcherRawHandle =
            "com.bbflight.background_downloader.callbackDispatcherRawHandle"
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
        const val keyConfigAllowWeakETag =
            "com.bbflight.background_downloader.config.allowWeakETag"
        const val keyConfigSkipExistingFiles =
            "com.bbflight.background_downloader.config.skipExistingFiles"


        @SuppressLint("StaticFieldLeak")
        var notificationButtonText =
            Collections.synchronizedMap(mutableMapOf<String, String>()) // for localization
        var firstBackgroundChannel: MethodChannel? = null
        var bgChannelByTaskId = Collections.synchronizedMap(mutableMapOf<String, MethodChannel>())
        var flutterEngineByTaskId =
            Collections.synchronizedMap(mutableMapOf<String, FlutterEngine>())
        var requireWifi = RequireWiFi.asSetByTask // global setting
        val localResumeData =
            Collections.synchronizedMap(mutableMapOf<String, ResumeData>()) // by taskId, for pause notifications
        var cancelUpdateSentForTaskId =
            Collections.synchronizedMap(mutableMapOf<String, Long>()) // <taskId, timeMillis>
        val pausedTaskIds =
            Collections.synchronizedSet(mutableSetOf<String>()) // <taskId>, acts as flag
        val canceledTaskIds =
            Collections.synchronizedSet(mutableSetOf<String>()) // <taskId>, acts as flag
        val parallelDownloadTaskWorkers =
            Collections.synchronizedMap(HashMap<String, ParallelDownloadTaskWorker>()) //Was a HashMap
        val tasksToReEnqueue =
            Collections.synchronizedSet(mutableSetOf<Task>()) // for when WiFi requirement changes
        val taskIdsRequiringWiFi =
            Collections.synchronizedSet(mutableSetOf<String>()) // ensures correctness when enqueueing task
        val notificationConfigJsonStrings =
            Collections.synchronizedMap(mutableMapOf<String, String>()) // by taskId
        var forceFailPostOnBackgroundChannel = false
        val prefsLock = ReentrantReadWriteLock()
        val remainingBytesToDownload =
            Collections.synchronizedMap(mutableMapOf<String, Long>()) // <taskId, size>
        var haveLoggedProxyMessage = false
        var holdingQueue: HoldingQueue? = null

        /**
         * Enqueue a WorkManager task based on the provided parameters
         */
        suspend fun doEnqueue(
            context: Context,
            task: Task,
            notificationConfigJsonString: String?,
            resumeData: ResumeData?,
            initialDelayMillis: Long = 0,
            plugin: BDPlugin? = null
        ): Boolean {
            Log.i(TAG, "Enqueuing task with id ${task.taskId}")
            // store backgroundChannel to be used by this task
            val bgChannel = backgroundChannel(plugin)
            if (bgChannel != null) {
                bgChannelByTaskId[task.taskId] = bgChannel
            } else {
                Log.w(TAG, "Could not find backgroundChannel for taskId ${task.taskId}")
            }
            holdingQueue?.hostByTaskId?.set(
                task.taskId,
                task.host()
            ) // store host if we have a HoldingQueue
            canceledTaskIds.remove(task.taskId) // reset flag
            cancelUpdateSentForTaskId.remove(task.taskId) // reset flag
            val dataBuilder = Data.Builder().putString(TaskWorker.keyTask, taskToJsonString(task))
            if (notificationConfigJsonString != null) {
                dataBuilder.putString(
                    TaskWorker.keyNotificationConfig,
                    notificationConfigJsonString
                )
                notificationConfigJsonStrings[task.taskId] = notificationConfigJsonString
            }
            if (resumeData != null) {
                dataBuilder.putString(TaskWorker.keyResumeDataData, resumeData.data)
                    .putLong(TaskWorker.keyStartByte, resumeData.requiredStartByte)
                    .putString(TaskWorker.keyETag, resumeData.eTag)
            }
            val data = dataBuilder.build()
            val taskRequiresWifi = taskRequiresWifi(task)
            if (taskRequiresWifi) {
                taskIdsRequiringWiFi.add(task.taskId)
            }
            val constraints = Constraints.Builder().setRequiredNetworkType(
                if (taskRequiresWifi) NetworkType.UNMETERED else NetworkType.CONNECTED
            ).build()
            val requestBuilder: OneTimeWorkRequest.Builder =
                createRequestBuilder(task, data, constraints) ?: return false
            if (initialDelayMillis != 0L) {
                requestBuilder.setInitialDelay(initialDelayMillis, TimeUnit.MILLISECONDS)
            }
            val expedited = task.priority < 5 && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S
            if (expedited) {
                requestBuilder.setExpedited(policy = OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
            }
            val workManager = WorkManager.getInstance(context)
            val operation = try {
                workManager.enqueue(requestBuilder.build())
            } catch (e: IllegalStateException) {
                if (expedited) {
                    // known to happen on some devices, fallback to non-expedited
                    Log.i(TAG, "Could not enqueue expedited task, falling back to non-expedited")
                    val nonExpeditedRequestBuilder =
                        createRequestBuilder(task, data, constraints) ?: return false
                    if (initialDelayMillis != 0L) {
                        nonExpeditedRequestBuilder.setInitialDelay(
                            initialDelayMillis,
                            TimeUnit.MILLISECONDS
                        )
                    }
                    workManager.enqueue(nonExpeditedRequestBuilder.build())
                } else {
                    throw e
                }
            }
            try {
                withContext(Dispatchers.IO) {
                    operation.result.get()
                }
                val prefs = PreferenceManager.getDefaultSharedPreferences(context)
                if (initialDelayMillis != 0L) {
                    delay(min(100L, initialDelayMillis))
                }
                if (holdingQueue?.enqueuedTaskIds?.contains(task.taskId) != true)
                    processStatusUpdate(task, TaskStatus.enqueued, prefs, context = context)
            } catch (_: Throwable) {
                Log.w(
                    TAG,
                    "Unable to start background request for taskId ${task.taskId}"
                )
                return false
            }
            // Register the enqueue with the NotificationService
            NotificationService.registerEnqueue(
                EnqueueItem(
                    context = context,
                    task = task,
                    notificationConfigJsonString = notificationConfigJsonString
                ), success = true
            )
            // store Task in persistent storage, as Json representation keyed by taskId
            prefsLock.write {
                val prefs = PreferenceManager.getDefaultSharedPreferences(context)
                val tasksMap = getTaskMap(prefs)
                tasksMap[task.taskId] = task
                prefs.edit {
                    putString(keyTasksMap, Json.encodeToString(tasksMap))
                }
            }
            return true
        }

        /** True if task requires WiFi, based on global and task-specific settings */
        fun taskRequiresWifi(task: Task): Boolean {
            return (requireWifi == RequireWiFi.forAllTasks || (requireWifi == RequireWiFi.asSetByTask && task.requiresWiFi))
        }

        /**
         * Create a [OneTimeWorkRequestBuilder] for the given [task], [data] and [constraints]
         *
         * Returns the builder, or null if the task type is unknown
         */
        private fun createRequestBuilder(
            task: Task,
            data: Data,
            constraints: Constraints
        ): OneTimeWorkRequest.Builder? {
            val requestBuilder = when (task.taskType) {
                "ParallelDownloadTask" -> OneTimeWorkRequestBuilder<ParallelDownloadTaskWorker>()
                "DownloadTask" -> OneTimeWorkRequestBuilder<DownloadTaskWorker>()
                "UriDownloadTask" -> OneTimeWorkRequestBuilder<DownloadTaskWorker>()
                "UploadTask" -> OneTimeWorkRequestBuilder<UploadTaskWorker>()
                "UriUploadTask" -> OneTimeWorkRequestBuilder<UploadTaskWorker>()
                "MultiUploadTask" -> OneTimeWorkRequestBuilder<UploadTaskWorker>()
                "DataTask" -> OneTimeWorkRequestBuilder<DataTaskWorker>()
                else -> {
                    Log.w(TAG, "Unknown taskType: ${task.taskType}")
                    return null
                }
            }
            requestBuilder.setInputData(data)
                .setConstraints(constraints).addTag(TAG).addTag("taskId=${task.taskId}")
                .addTag("group=${task.group}")
            return requestBuilder
        }

        /** cancel tasks with [taskIds] and return true if successful */
        suspend fun cancelTasksWithIds(context: Context, taskIds: Iterable<String>): Boolean {
            val workManager = WorkManager.getInstance(context)
            Log.v(TAG, "Canceling taskIds $taskIds")
            holdingQueue?.stateMutex?.lock()
            val taskIdsRemovedFromHoldingQueue =
                holdingQueue?.cancelTasksWithIds(context, taskIds) ?: listOf()
            val taskIdsRemaining = taskIds.filter { !taskIdsRemovedFromHoldingQueue.contains(it) }
            var success = true
            for (taskId in taskIdsRemaining) {
                success = success && cancelActiveTaskWithId(context, taskId, workManager)
            }
            holdingQueue?.stateMutex?.unlock()
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
            // get the workInfos for the task (should be only one)
            val workInfos = withContext(Dispatchers.IO) {
                workManager.getWorkInfosByTag("taskId=$taskId").get()
            }
            if (workInfos.isEmpty()) {
                Log.d(TAG, "Could not find tasks to cancel")
                return false
            }
            // send cancel update and remove notification
            val prefs = PreferenceManager.getDefaultSharedPreferences(context)
            val tasksMap = getTaskMap(prefs)
            for (workInfo in workInfos) {
                if (workInfo.state != WorkInfo.State.SUCCEEDED) {
                    // send cancellation update for tasks that have not yet succeeded
                    // and remove associated notification
                    val task = tasksMap[taskId]
                    if (task != null) {
                        canceledTaskIds.add(task.taskId)
                        processStatusUpdate(
                            task,
                            TaskStatus.canceled,
                            prefs,
                            context = context
                        )
                        holdingQueue?.taskFinished(task)
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
                val operation = workManager.cancelAllWorkByTag("taskId=$taskId")
                try {
                    withContext(Dispatchers.IO) {
                        operation.result.get()
                    }
                } catch (_: Throwable) {
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
         * cancellation. See [NotificationReceiver]
         */
        suspend fun cancelInactiveTask(context: Context, task: Task) {
            Log.d(TAG, "Canceling inactive task")
            val prefs = PreferenceManager.getDefaultSharedPreferences(context)
            val notificationConfigJsonString = notificationConfigJsonStrings[task.taskId]
            if (notificationConfigJsonString != null) {
                // update the notification via an UpdateNotificationWorker
                NotificationService.createUpdateNotificationWorker(
                    context,
                    Json.encodeToString(task),
                    notificationConfigJsonString,
                    TaskStatus.canceled.ordinal
                )
            }
            processStatusUpdate(task, TaskStatus.canceled, prefs, context = context)
        }

        /**
         * Pause the task with this [taskId]
         *
         * Marks the task for pausing, actual pausing happens in [TaskWorker]
         */
        @Suppress("SameReturnValue")
        fun pauseTaskWithId(taskId: String): Boolean {
            pausedTaskIds.add(taskId)
            return true
        }

        /**
         * Return the backgroundChannel for the given [plugin] or [taskId]
         *
         * If no channel can be found, returns null
         *
         * Will attempt to match on [plugin] first
         */
        fun backgroundChannel(
            plugin: BDPlugin? = null,
            taskId: String = "bgd_non_existent_id"
        ): MethodChannel? {
            return plugin?.backgroundChannel ?: bgChannelByTaskId[taskId] ?: firstBackgroundChannel
        }
    }

    private var channel: MethodChannel? = null
    private var backgroundChannel: MethodChannel? = null
    private lateinit var applicationContext: Context
    private lateinit var mainScope: CoroutineScope
    private lateinit var ioScope: CoroutineScope
    private var binaryMessenger: BinaryMessenger? = null
    var activity: Activity? = null


    /**
     * Attaches the plugin to the Flutter engine and performs initialization
     */
    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = flutterPluginBinding.applicationContext
        mainScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
        ioScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        binaryMessenger = flutterPluginBinding.binaryMessenger
        backgroundChannel =
            MethodChannel(
                flutterPluginBinding.binaryMessenger,
                "com.bbflight.background_downloader.background"
            )
        if (firstBackgroundChannel == null) {
            firstBackgroundChannel = backgroundChannel
        }
        channel = MethodChannel(
            flutterPluginBinding.binaryMessenger, "com.bbflight.background_downloader"
        )
        channel?.setMethodCallHandler(this)
        val uriUtilsChannel = MethodChannel(
            flutterPluginBinding.binaryMessenger,
            "com.bbflight.background_downloader.uriutils"
        )
        uriUtilsChannel.setMethodCallHandler(UriUtilsMethodCallHelper(this))
        // clear expired items
        val prefs = PreferenceManager.getDefaultSharedPreferences(applicationContext)
        val workManager = WorkManager.getInstance(applicationContext)
        val allWorkInfos = workManager.getWorkInfosByTag(TAG).get()
        if (allWorkInfos.isEmpty()) {
            prefsLock.write {
                // remove persistent storage if no jobs found at all
                prefs.edit {
                    remove(keyTasksMap)
                }
            }
        }
        requireWifi = RequireWiFi.entries[prefs.getInt(keyRequireWiFi, 0)]
    }


    /**
     * Free up resources.
     *
     * BinaryMessenger and Plugin references are set to null and removed.
     * BackgroundChannel is set to null, and references to it removed if it no longer in use anywhere
     * */
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        mainScope.cancel()
        ioScope.cancel()
        channel?.setMethodCallHandler(null)
        channel = null
        bgChannelByTaskId =
            bgChannelByTaskId.filter { it.value != backgroundChannel } as MutableMap
        if (firstBackgroundChannel == backgroundChannel) {
            firstBackgroundChannel = null
        }
        backgroundChannel = null
        binaryMessenger = null
    }

    /** Processes the methodCall coming from Dart */
    override fun onMethodCall(call: MethodCall, result: Result) {
        mainScope.launch {
            try {
                val res: Any? = when (call.method) {
                    "enqueue" -> methodEnqueue(call)
                    "enqueueAll" -> methodEnqueueAll(call)
                    "reset" -> methodReset(call)
                    "allTasks" -> methodAllTasks(call)
                    "cancelTasksWithIds" -> methodCancelTasksWithIds(call)
                    "killTaskWithId" -> methodKillTaskWithId(call)
                    "taskForId" -> methodTaskForId(call)
                    "pause" -> methodPause(call)
                    "pauseAll" -> methodPauseAll(call)
                    "updateNotification" -> methodUpdateNotification(call)
                    "moveToSharedStorage" -> methodMoveToSharedStorage(call)
                    "pathInSharedStorage" -> methodPathInSharedStorage(call)
                    "openFile" -> methodOpenFile(call)
                    "requireWiFi" -> methodRequireWiFi(call)
                    "getRequireWiFiSetting" -> methodGetRequireWiFiSetting()
                    // ParallelDownloadTask child updates
                    "chunkStatusUpdate" -> methodUpdateChunkStatus(call)
                    "chunkProgressUpdate" -> methodUpdateChunkProgress(call)
                    // Permissions
                    "permissionStatus" -> methodPermissionStatus(call)
                    "requestPermission" -> methodRequestPermission(call)
                    "shouldShowPermissionRationale" -> methodShouldShowPermissionRationale(call)
                    // internal use
                    "popResumeData" -> methodPopResumeData()
                    "popStatusUpdates" -> methodPopStatusUpdates()
                    "popProgressUpdates" -> methodPopProgressUpdates()
                    "getTaskTimeout" -> methodGetTaskTimeout()
                    "registerCallbackDispatcher" -> methodRegisterCallbackDispatcher(call)
                    // configuration
                    "configForegroundFileSize" -> methodConfigForegroundFileSize(call)
                    "configProxyAddress" -> methodConfigProxyAddress(call)
                    "configProxyPort" -> methodConfigProxyPort(call)
                    "configRequestTimeout" -> methodConfigRequestTimeout(call)
                    "configBypassTLSCertificateValidation" -> methodConfigBypassTLSCertificateValidation()
                    "configCheckAvailableSpace" -> methodConfigCheckAvailableSpace(call)
                    "configUseCacheDir" -> methodConfigUseCacheDir(call)
                    "configUseExternalStorage" -> methodConfigUseExternalStorage(call)
                    "configHoldingQueue" -> methodConfigHoldingQueue(call)
                    "configAllowWeakETag" -> methodConfigAllowWeakETag(call)
                    "configSkipExistingFiles" -> methodConfigSkipExistingFiles(call)
                    "platformVersion" -> methodPlatformVersion()
                    "forceFailPostOnBackgroundChannel" -> methodForceFailPostOnBackgroundChannel(
                        call
                    )

                    "testSuggestedFilename" -> methodTestSuggestedFilename(call)

                    else -> throw MethodCallException(
                        "notImplemented",
                        "Method ${call.method} not implemented",
                        null
                    )
                }
                result.success(res)
            } catch (e: MethodCallException) {
                result.error(e.errorCode, e.errorMessage, e.errorDetails)
            }
        }
    }


    /**
     * Starts one task, passed as map of values representing a [Task]
     *
     * Returns true if successful, and will emit a status update that the task is running.
     */
    private suspend fun methodEnqueue(call: MethodCall): Boolean =
        withContext(ioScope.coroutineContext) {
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
            // validate the task.url
            try {
                URL(task.url)
                URLDecoder.decode(task.url, "UTF-8")
            } catch (_: MalformedURLException) {
                Log.i(TAG, "MalformedURLException for taskId ${task.taskId}")
                return@withContext false
            } catch (_: IllegalArgumentException) {
                Log.i(TAG, "Could not url-decode url for taskId ${task.taskId}")
                return@withContext false
            }
            // enqueue or add to HoldingQueue
            if (holdingQueue == null) {
                doEnqueue(
                    applicationContext,
                    task,
                    notificationConfigJsonString,
                    resumeData,
                    plugin = this@BDPlugin
                )
            } else {
                Log.i(TAG, "Enqueueing task with id ${task.taskId} to the HoldingQueue")
                holdingQueue?.add(
                    EnqueueItem(
                        context = applicationContext,
                        task = task,
                        notificationConfigJsonString = notificationConfigJsonString,
                        resumeData = resumeData,
                        plugin = this@BDPlugin
                    )
                )
                processStatusUpdate(
                    task,
                    TaskStatus.enqueued,
                    PreferenceManager.getDefaultSharedPreferences(applicationContext),
                    context = applicationContext
                )
                true
            }
        }

    /**
     * Starts a list of tasks, passed as a JSON string representing a list of [Task] objects.
     *
     * Returns a list of booleans indicating the success of each individual enqueue operation.
     */
    private suspend fun methodEnqueueAll(call: MethodCall): List<Boolean> =
        withContext(ioScope.coroutineContext) {
            val plugin = this@BDPlugin
            val args = call.arguments as List<*>
            val taskListJsonString = args[0] as String
            val notificationConfigListJsonString = args[1] as String
            try {
                val tasks = Json.decodeFromString<List<Task>>(taskListJsonString)
                val notificationConfigs =
                    Json.decodeFromString<List<NotificationConfig?>>(
                        notificationConfigListJsonString
                    )
                val results = mutableListOf<Boolean>()
                for ((index, task) in tasks.withIndex()) {
                    val notificationConfig = notificationConfigs.getOrNull(index)
                    val notificationConfigJsonString =
                        notificationConfig?.let { Json.encodeToString(it) }
                    var success = false
                    try {
                        try {
                            URL(task.url)
                            URLDecoder.decode(task.url, "UTF-8")
                        } catch (_: MalformedURLException) {
                            Log.i(TAG, "MalformedURLException for taskId ${task.taskId}")
                        results.add(false)
                        continue
                    } catch (_: IllegalArgumentException) {
                        Log.i(TAG, "Could not url-decode url for taskId ${task.taskId}")
                        results.add(false)
                        continue
                    }
                    // Enqueue or add to HoldingQueue
                    success = if (holdingQueue == null) {
                        doEnqueue(
                            applicationContext,
                            task,
                            notificationConfigJsonString,
                            resumeData = null,
                            plugin = plugin
                        )
                    } else {
                        Log.i(TAG, "Enqueueing task with id ${task.taskId} to the HoldingQueue")
                        holdingQueue?.add(
                            EnqueueItem(
                                context = applicationContext,
                                task = task,
                                notificationConfigJsonString = notificationConfigJsonString,
                                resumeData = null,
                                plugin = plugin
                            )
                        )
                        processStatusUpdate(
                            task,
                            TaskStatus.enqueued,
                            PreferenceManager.getDefaultSharedPreferences(applicationContext),
                            context = applicationContext
                        )
                        true
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "Error processing task ${task.taskId}: ${e.message}")
                }
                results.add(success)
            }
            results
        } catch (e: Exception) {
            Log.e(TAG, "Error decoding JSON: ${e.message}")
            emptyList() // Return an empty list on error
        }
    }

    /**
     * Resets the download worker by cancelling all ongoing download tasks for the group
     *
     * Returns the number of tasks canceled
     */
    private suspend fun methodReset(call: MethodCall): Int = withContext(ioScope.coroutineContext) {
        val group = call.arguments as String
        holdingQueue?.stateMutex?.lock()
        var counter = holdingQueue?.cancelAllTasks(applicationContext, group) ?: 0
        val tasksMap: MutableMap<String, Task>
        val prefs = PreferenceManager.getDefaultSharedPreferences(applicationContext)
        prefsLock.read {
            tasksMap = getTaskMap(prefs)
        }
        val workManager = WorkManager.getInstance(applicationContext)
        val workInfos = workManager.getWorkInfosByTag(TAG).get()
            .filter { !it.state.isFinished && it.tags.contains("group=$group") }
        for (workInfo in workInfos) {
            val tags = workInfo.tags.filter { it.contains("taskId=") }
            if (tags.isNotEmpty()) {
                val taskId = tags.first().substring(7)
                val task = tasksMap[taskId]
                if (task != null) {
                    canceledTaskIds.add(task.taskId)
                    processStatusUpdate(
                        task,
                        TaskStatus.canceled,
                        prefs,
                        context = applicationContext
                    )
                    holdingQueue?.taskFinished(task)
                }
            }
            workManager.cancelWorkById(workInfo.id)
            counter++
        }
        holdingQueue?.stateMutex?.unlock()
        Log.v(TAG, "methodReset removed $counter unfinished tasks in group $group")
        counter
    }

    /**
     * Returns a list of tasks for all tasks in progress, as a list of JSON strings,
     * optionally filtered by group
     */
    private suspend fun methodAllTasks(call: MethodCall): List<String> =
        withContext(ioScope.coroutineContext) {
            val group = call.arguments as String?
            val tasksAsListOfJsonStrings = mutableListOf<String>()
            holdingQueue?.stateMutex?.lock()
            holdingQueue?.allTasks(group)
                ?.forEach { tasksAsListOfJsonStrings.add(Json.encodeToString(it)) }
            val workManager = WorkManager.getInstance(applicationContext)
            val workInfos = workManager.getWorkInfosByTag(TAG).get()
                .filter { !it.state.isFinished && (group == null || it.tags.contains("group=$group")) }
            val tasksMap: MutableMap<String, Task>
            val prefs = PreferenceManager.getDefaultSharedPreferences(applicationContext)
            prefsLock.read {
                tasksMap = getTaskMap(prefs)
            }
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
            holdingQueue?.stateMutex?.unlock()
            Log.v(
                TAG,
                "Returning ${tasksAsListOfJsonStrings.size} unfinished tasks in group $group"
            )
            tasksAsListOfJsonStrings
        }

    /**
     * Cancels ongoing tasks whose taskId is in the list provided with this call
     *
     * Returns true if all cancellations were successful
     */
    private suspend fun methodCancelTasksWithIds(call: MethodCall): Boolean =
        withContext(ioScope.coroutineContext) {
            @Suppress("UNCHECKED_CAST") val taskIds = call.arguments as List<String>
            cancelTasksWithIds(applicationContext, taskIds)
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
    private suspend fun methodKillTaskWithId(call: MethodCall): Any? {
        val taskId = call.arguments as String
        withContext(ioScope.coroutineContext) {
            val workManager = WorkManager.getInstance(applicationContext)
            val operation = workManager.cancelAllWorkByTag("taskId=$taskId")
            try {
                operation.result.get()
            } catch (_: Throwable) {
                Log.w(
                    TAG,
                    "Could not kill task wih id $taskId in operation: $operation"
                )
            }
        }
        return null
    }

    /** Returns Task for this taskId, or nil */
    private suspend fun methodTaskForId(call: MethodCall): String? =
        withContext(ioScope.coroutineContext) {
            val taskId = call.arguments as String
            Log.v(TAG, "Returning task for taskId $taskId")
            holdingQueue?.stateMutex?.lock()
            var foundTask = holdingQueue?.taskForId(taskId)
            if (foundTask == null) {
                prefsLock.read {
                    val prefs = PreferenceManager.getDefaultSharedPreferences(applicationContext)
                    val tasksMap = getTaskMap(prefs)
                    foundTask = tasksMap[taskId]
                }
            }
            holdingQueue?.stateMutex?.unlock()
            foundTask?.let { Json.encodeToString(it) }
        }

    /**
     * Marks the taskId for pausing
     *
     * The pause action is taken in the [TaskWorker]
     */
    private fun methodPause(call: MethodCall): Boolean {
        val taskId = call.arguments as String
        return pauseTaskWithId(taskId)
    }

    /**
     * Marks all taskIds for pausing
     */
    private fun methodPauseAll(call: MethodCall): List<Boolean> {
        val taskIds = call.arguments as? List<*> ?: throw MethodCallException(
            "INVALID_ARGUMENT",
            "Expected a list of task IDs",
            null
        )
        return taskIds.map { taskId ->
            if (taskId is String) {
                pauseTaskWithId(taskId)
            } else {
                false
            }
        }
    }

    /**
     * Update the notification for this task
     *
     * Args are:
     * - task
     * - notificationConfig (cannot be null)
     * - taskStatus as ordinal in TaskStatus enum. If null, delete the notification
     */
    private suspend fun methodUpdateNotification(call: MethodCall): Any? =
        withContext(ioScope.coroutineContext) {
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
            null
        }


    /**
     * Returns a JSON String of a map of [ResumeData], keyed by taskId, that has been stored
     * in local shared preferences because they could not be delivered to the Dart side.
     * Local storage of this map is then cleared
     */
    private suspend fun methodPopResumeData(): String {
        return withContext(ioScope.coroutineContext) {
            popLocalStorage(keyResumeDataMap)
        }
    }

    /**
     * Returns a JSON String of a map of [Task] and [TaskStatus], keyed by taskId, stored
     * in local shared preferences because they could not be delivered to the Dart side.
     * Local storage of this map is then cleared
     */
    private suspend fun methodPopStatusUpdates(): String {
        return withContext(ioScope.coroutineContext) {
            popLocalStorage(keyStatusUpdateMap)
        }
    }

    /**
     * Returns a JSON String of a map of [ResumeData], keyed by taskId, that has been stored
     * in local shared preferences because they could not be delivered to the Dart side.
     * Local storage of this map is then cleared
     */
    private suspend fun methodPopProgressUpdates(): String {
        return withContext(ioScope.coroutineContext) {
            popLocalStorage(keyProgressUpdateMap)
        }
    }

    /**
     * Pops and returns locally stored data for this key as a JSON String
     *
     * The Json string represents a Map, keyed by TaskId, where each item is a Json representation
     * of the object stored, e.g. a [TaskStatusUpdate]
     */
    private fun popLocalStorage(prefsKey: String): String {
        return prefsLock.write {
            val prefs = PreferenceManager.getDefaultSharedPreferences(applicationContext)
            val jsonString = prefs.getString(prefsKey, "{}")
            prefs.edit {
                remove(prefsKey)
            }
            jsonString ?: "{}"
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
     * - asUriString (Boolean): if set, returns the path not as a filePath but as a Uri
     */
    private suspend fun methodMoveToSharedStorage(call: MethodCall): String? =
        withContext(ioScope.coroutineContext) {
            val args = call.arguments as List<*>
            val filePath = args[0] as String
            val destination = SharedStorage.entries[args[1] as Int]
            val directory = args[2] as String
            val mimeType = args[3] as String?
            val asUriString = args[4] as Boolean
            // first check and potentially ask for permissions
            val status = PermissionsService.getPermissionStatus(
                applicationContext,
                PermissionType.androidSharedStorage
            )
            if (status == PermissionStatus.granted) {
                moveToSharedStorage(
                    applicationContext,
                    filePath,
                    destination,
                    directory,
                    mimeType,
                    asUriString
                )
            } else {
                Log.i(TAG, "No permission to move to shared storage")
                null
            }
        }

    /**
     * Returns path to file in Android scoped/shared storage, or null
     *
     * If asAndroidUri is true, returns the URI if possible, otherwise falls back to file path
     *
     * Call arguments:
     * - filePath (String): full path to file (only the name is used)
     * - destination (Int as index into [SharedStorage] enum)
     * - directory (String): subdirectory within scoped storage (ignored for Q+)
     * - asUriString (Boolean): if true, returns the URI instead of the path
     *
     * For Android Q+ uses the MediaStore, matching on filename only, i.e. ignoring
     * the directory
     */
    private suspend fun methodPathInSharedStorage(call: MethodCall): String? {
        val args = call.arguments as List<*>
        val filePath = args[0] as String
        val destination = SharedStorage.entries[args[1] as Int]
        val directory = args[2] as String
        val asUriString = args[3] as Boolean
        return withContext(ioScope.coroutineContext) {
            pathInSharedStorage(
                applicationContext,
                filePath,
                destination,
                directory,
                asUriString
            )
        }
    }

    /**
     * Open the file represented by the task, with optional mimeType
     *
     * Call arguments are [taskJsonMapString, filename, mimeType] with precondition that either
     * task or filename is not null
     */
    private fun methodOpenFile(call: MethodCall): Boolean {
        val args = call.arguments as List<*>
        val taskJsonMapString = args[0] as String?
        val task =
            if (taskJsonMapString != null) Json.decodeFromString<Task>(taskJsonMapString) else null
        val filePath = args[1] as String? ?: task!!.filePath(applicationContext)
        val mimeType = args[2] as String? ?: getMimeType(filePath)
        return if (activity != null) doOpenFile(activity!!, filePath, mimeType) else false
    }

    /**
     * Set WiFi requirement globally, based on requirement.
     *
     * Affects future tasks and reschedules enqueued, inactive tasks
     * with the new setting.
     * Reschedules active tasks if rescheduleRunning is true,
     * otherwise leaves those running with their prior setting
     *
     * - requirement is first argument (enum)
     * - rescheduleRunning is second argument (bool)
     *
     * Returns true always
     */
    private suspend fun methodRequireWiFi(call: MethodCall): Boolean = withContext(ioScope.coroutineContext) {
        val args = call.arguments as List<*>
        val newRequireWiFi = RequireWiFi.entries[args[0] as Int]
        val rescheduleRunning = args[1] as Boolean
        WiFi.requireWiFiChange(
            RequireWiFiChange(
                applicationContext,
                newRequireWiFi,
                rescheduleRunning
            )
        )
        true
    }

    /**
     * Returns the current global setting for 'requireWiFi', as an ordinal
     */
    private suspend fun methodGetRequireWiFiSetting(): Int {
        return withContext(ioScope.coroutineContext) {
            PreferenceManager.getDefaultSharedPreferences(applicationContext).getInt(
                keyRequireWiFi, 0
            )
        }
    }

    /**
     * Update the status of one chunk (part of a ParallelDownloadTask), and returns
     * the status of the parent task based on the 'sum' of its children, or null
     * if unchanged
     *
     * Arguments are the parent TaskId, chunk taskId, taskStatusOrdinal
     */
    private suspend fun methodUpdateChunkStatus(call: MethodCall): Any? = withContext(ioScope.coroutineContext) {
        val args = call.arguments as List<*>
        val taskId = args[0] as String
        val chunkTaskId = args[1] as String
        val statusOrdinal = args[2] as Int
        val exceptionJson = args[3] as String?
        try {
            val exception = if (exceptionJson != null) {
                Json.decodeFromString<TaskException>(exceptionJson)
            } else null
            val responseBody = args[4] as String?
            parallelDownloadTaskWorkers[taskId]?.chunkStatusUpdate(
                chunkTaskId,
                TaskStatus.entries[statusOrdinal],
                exception,
                responseBody
            )
        } catch (e: Exception) {
            Log.w(TAG, "Exception $e")
            Log.w(TAG, "exceptionJson = $exceptionJson")
            e.printStackTrace()
        }
        null
    }

    /**
     * Update the progress of one chunk (part of a ParallelDownloadTask), and returns
     * the progress of the parent task based on the average of its children
     *
     * Arguments are the parent [TaskId, chunk taskId, progress]
     */
    private suspend fun methodUpdateChunkProgress(call: MethodCall): Any? = withContext(ioScope.coroutineContext) {
        val args = call.arguments as List<*>
        val taskId = args[0] as String
        val chunkTaskId = args[1] as String
        val progress = args[2] as Double
        parallelDownloadTaskWorkers[taskId]?.chunkProgressUpdate(
            chunkTaskId,
            progress
        )
        null
    }

    /**
     * Return [PermissionStatus] for this [PermissionType]
     */
    private fun methodPermissionStatus(call: MethodCall): Int {
        val permissionType = PermissionType.entries[call.arguments as Int]
        return PermissionsService.getPermissionStatus(
            applicationContext,
            permissionType
        ).ordinal
    }

    /**
     * Request permission for this [PermissionType]
     *
     * Returns true if request was submitted successfully, and the
     * Flutter side should wait for completion via the background
     * channel method "permissionRequestResult"
     */
    private fun methodRequestPermission(call: MethodCall): Boolean {
        val permissionType = PermissionType.entries[call.arguments as Int]
        return PermissionsService.requestPermission(this, permissionType)
    }

    /**
     * Returns true if you should show a rationale for this [PermissionType]
     */
    private fun methodShouldShowPermissionRationale(call: MethodCall): Boolean {
        val permissionType = PermissionType.entries[call.arguments as Int]
        return PermissionsService.shouldShowRequestPermissionRationale(
            this,
            permissionType
        )
    }

    /**
     * Returns the [TaskWorker] timeout value in milliseconds
     *
     * For testing only
     */
    private fun methodGetTaskTimeout(): Long {
        return TaskWorker.taskTimeoutMillis
    }

    /**
     * Store rawHandle for callbackDispatcher in shared preferences
     *
     * Dispatcher is called just before passing callback via methodChannel, to ensure
     * that Dart is listening to the methodChannel before calling the callback.
     */
    private suspend fun methodRegisterCallbackDispatcher(call: MethodCall): Any? {
        withContext(ioScope.coroutineContext) {
            PreferenceManager.getDefaultSharedPreferences(applicationContext).edit().apply {
                val handle = call.arguments as Long?
                if (handle != null) {
                    Log.d(TAG, "Registering callbackDispatcher handle $handle")
                    putLong(keyCallbackDispatcherRawHandle, handle)
                } else {
                    remove(keyConfigProxyAddress)
                }
                apply()
            }
        }
        return null
    }


    /**
     * Store foregroundFileSize in shared preferences
     *
     * The value is in MB, or -1 to disable foreground always, and
     * is retrieved in [TaskWorker.doWork]
     */
    private suspend fun methodConfigForegroundFileSize(call: MethodCall): Any? {
        withContext(ioScope.coroutineContext) {
            val fileSize = call.arguments as Int
            updateSharedPreferences(keyConfigForegroundFileSize, fileSize)
            val msg = when (fileSize) {
                0 -> "Enabled foreground mode for all tasks"
                -1 -> "Disabled foreground mode for all tasks"
                else -> "Set foreground file size threshold to $fileSize MB"
            }
            Log.v(TAG, msg)
        }
        return null
    }

    /**
     * Store the proxy address config in shared preferences
     */
    private suspend fun methodConfigProxyAddress(call: MethodCall): Any? {
        withContext(ioScope.coroutineContext) {
            updateSharedPreferences(keyConfigProxyAddress, call.arguments as String?)
        }
        return null
    }

    /**
     * Store the proxy port config in shared preferences
     */
    private suspend fun methodConfigProxyPort(call: MethodCall): Any? {
        withContext(ioScope.coroutineContext) {
            updateSharedPreferences(keyConfigProxyPort, call.arguments)
        }
        return null
    }

    /**
     * Store the requestTimeout config in shared preferences
     */
    private suspend fun methodConfigRequestTimeout(call: MethodCall): Any? {
        withContext(ioScope.coroutineContext) {
            updateSharedPreferences(keyConfigRequestTimeout, call.arguments)
        }
        return null
    }

    /**
     * Bypass the certificate validation
     */
    private suspend fun methodConfigBypassTLSCertificateValidation(): Any? {
        withContext(ioScope.coroutineContext) {
            acceptUntrustedCertificates()
        }
        return null
    }

    /**
     * Store the availableSpace config in shared preferences
     */
    private suspend fun methodConfigCheckAvailableSpace(call: MethodCall): Any? {
        withContext(ioScope.coroutineContext) {
            updateSharedPreferences(keyConfigCheckAvailableSpace, call.arguments)
        }
        return null
    }

    /**
     * Store the useCacheDir config in shared preferences
     */
    private suspend fun methodConfigUseCacheDir(call: MethodCall): Any? {
        withContext(ioScope.coroutineContext) {
            updateSharedPreferences(keyConfigUseCacheDir, call.arguments)
        }
        return null
    }

    /**
     * Store the useExternalStorage config in shared preferences
     */
    private suspend fun methodConfigUseExternalStorage(call: MethodCall): Any? {
        withContext(ioScope.coroutineContext) {
            updateSharedPreferences(keyConfigUseExternalStorage, call.arguments)
        }
        return null
    }


    /**
     * Configure the holding queue
     */
    private fun methodConfigHoldingQueue(call: MethodCall): Any? {
        val arguments = call.arguments as List<*>
        if (arguments.isEmpty()) { // deactivate the holding queue
            holdingQueue = null
        } else {
            holdingQueue = holdingQueue ?: HoldingQueue(WorkManager.getInstance(applicationContext))
            holdingQueue?.maxConcurrent = arguments[0] as Int
            holdingQueue?.maxConcurrentByHost = arguments[1] as Int
            holdingQueue?.maxConcurrentByGroup = arguments[2] as Int
        }
        return null
    }

    /**
     * Store the allowWeakETag config in shared preferences
     */
    private suspend fun methodConfigAllowWeakETag(call: MethodCall): Any? {
        withContext(ioScope.coroutineContext) {
            updateSharedPreferences(keyConfigAllowWeakETag, call.arguments)
        }
        return null
    }

    /**
     * Return the Android API version integer as a String
     */
    private fun methodPlatformVersion(): String {
        return "${Build.VERSION.SDK_INT}"
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
    private fun methodForceFailPostOnBackgroundChannel(call: MethodCall): Any? {
        forceFailPostOnBackgroundChannel = call.arguments as Boolean
        return null
    }

    /**
     * Tests the content-disposition and url translation
     *
     * For testing only
     *
     */
    private fun methodTestSuggestedFilename(call: MethodCall): String {
        val args = call.arguments as List<*>
        val taskJsonMapString = args[0] as String
        val contentDisposition = args[1] as String
        val task = Json.decodeFromString<Task>(taskJsonMapString)
        val h = if (contentDisposition.isNotEmpty()) mutableMapOf(
            "Content-Disposition" to mutableListOf(contentDisposition)
        ) else mutableMapOf("" to mutableListOf())
        val t = task.withSuggestedFilenameFromResponseHeaders(applicationContext, h)
        return t.filename
    }

    /**
     * Helper function to update or delete the [value] in shared preferences under [key]
     *
     * If [value] is null, the [key] is deleted
     */
    private fun updateSharedPreferences(key: String, value: Any?) {
        PreferenceManager.getDefaultSharedPreferences(applicationContext).edit().apply {
            when (value) {
                is String -> putString(key, value)
                is Int -> putInt(key, value)
                is Boolean -> putBoolean(key, value)
                null -> remove(key)
                else -> {
                    Log.w(TAG, "Unsupported type for updateSharedPreferences")
                    return@apply
                }
            }
            apply()
        }
        Log.d(TAG, "Setting preference key $key to $value")
    }

    /**
     * Store the skipExistingFiles config in shared preferences
     */
    private suspend fun methodConfigSkipExistingFiles(call: MethodCall): Any? {
        withContext(ioScope.coroutineContext) {
            updateSharedPreferences(keyConfigSkipExistingFiles, call.arguments)
        }
        return null
    }

// ActivityAware implementation to capture Activity context needed for permissions and intents

    /**
     * Handle intent if received from tapping a notification
     *
     * This may be called on startup of the application and at that time the [backgroundChannel] and
     * its listener may not have been initialized yet. This function therefore includes retry logic.
     */
    private fun handleIntent(intent: Intent?): Boolean {
        if (intent != null && intent.action == NotificationReceiver.actionTap) {
            // if taskJsonMapString == null, this was a main launch and we ignore
            val taskJsonMapString =
                intent.getStringExtra(NotificationReceiver.keyTask) ?: return true
            val notificationTypeOrdinal =
                intent.getIntExtra(NotificationReceiver.keyNotificationType, 0)
            val notificationId = intent.getIntExtra(NotificationReceiver.keyNotificationId, 0)
            // only process notificationTap and tapOpensFile if we have task data
            if (taskJsonMapString.isNotEmpty()) {
                CoroutineScope(Dispatchers.Default).launch {
                    var retries = 0
                    var success = false
                    while (retries < 5 && !success) {
                        try {
                            if (backgroundChannel != null) {
                                val resultCompleter = CompletableDeferred<Boolean>()
                                withContext(Dispatchers.Main) {
                                    backgroundChannel?.invokeMethod(
                                        "notificationTap",
                                        listOf(taskJsonMapString, notificationTypeOrdinal),
                                        FlutterBooleanResultHandler(resultCompleter)
                                    )
                                }
                                success = resultCompleter.await()
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
                    val task = Json.decodeFromString<Task>(taskJsonMapString)
                    val notificationConfigJsonString =
                        intent.extras?.getString(NotificationReceiver.keyNotificationConfig)
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
        binding.addRequestPermissionsResultListener(this)
        binding.addActivityResultListener(this)
        binding.addOnNewIntentListener(fun(intent: Intent?): Boolean {
            return handleIntent(intent)
        })
        if (notificationButtonText.isEmpty()) {
            // store localized strings so they can be used in notifications even when the
            // activity is not alive
            notificationButtonText["Cancel"] =
                activity!!.getString(R.string.bg_downloader_cancel)
            notificationButtonText["Pause"] = activity!!.getString(R.string.bg_downloader_pause)
            notificationButtonText["Resume"] =
                activity!!.getString(R.string.bg_downloader_resume)
        }
    }

    /**
     * Detach from activity
     *
     * Because we don't know which activity, we can't really do much here
     */
    private fun detach() {
        activity = null
    }

    /**
     * Receives onRequestPermissionsResult and passes this to the
     * [PermissionsService]
     */
    override fun onRequestPermissionsResult(
        requestCode: Int, permissions: Array<out String>, grantResults: IntArray
    ): Boolean {
        return PermissionsService.onRequestPermissionsResult(
            this,
            requestCode,
            grantResults
        )
    }

    /**
     * Handle other onActivityResult calls not related to permissions
     */
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (DirectoryPicker.handleActivityResult(
                applicationContext,
                requestCode,
                resultCode,
                data
            )
        ) {
            return true
        } else if (FilePicker.handleActivityResult(
                applicationContext,
                requestCode,
                resultCode,
                data
            )
        ) {
            return true
        }
        return false
    }
}
