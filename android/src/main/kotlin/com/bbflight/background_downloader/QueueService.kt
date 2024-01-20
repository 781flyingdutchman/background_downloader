package com.bbflight.background_downloader

import android.content.Context
import android.os.Looper
import android.util.Log
import androidx.preference.PreferenceManager
import androidx.work.WorkInfo
import androidx.work.WorkManager
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Queue service that executes things on a queue, to ensure ordered execution
 * and potentially manage delay
 */
object QueueService {
    private val scope = CoroutineScope(Dispatchers.Default)

    private val taskIdDeletionQueue = Channel<String>(capacity = Channel.UNLIMITED)
    private var lastTaskIdAdditionTime: Long = 0
    private const val minTaskIdDeletionDelay: Long = 2000L //ms

    private val backgroundPostQueue = Channel<BackgroundPost>(capacity = Channel.UNLIMITED)

    private val requireWiFiQueue =
        Channel<RequireWiFiChange>(capacity = Channel.UNLIMITED)

    private val reEnqueueQueue = Channel<ReEnqueue>(capacity = Channel.UNLIMITED)

    /**
     * Starts listening to the queues and processes each item
     *
     * taskIdDeletionQueue:
     *    Each item is a taskId and it will be removed from the
     *    BDPlugin.bgChannelByTaskId, BDPlugin.localResumeData
     *    and BDPlugin.notificationConfigs maps
     *
     * backgroundPostQueue:
     *    Each item is a [BackgroundPost] that will be posted on the UI thread, and its
     *    success completer will complete with true if successfully posted
     *
     * requireWiFiQueue:
     *    Each item is a Triple(context, workInfo, rescheduleActive), and each workInfo
     *    will be either rescheduled (if enqueued) or paused and resumed (if running and
     *    possible) or cancelled and re-enqueued (if running and pause not possible
     */
    init {
        scope.launch {
            for (taskId in taskIdDeletionQueue) {
                val now = System.currentTimeMillis()
                val elapsed = now - lastTaskIdAdditionTime
                if (elapsed < minTaskIdDeletionDelay) {
                    delay(minTaskIdDeletionDelay - elapsed)
                }
                BDPlugin.bgChannelByTaskId.remove(taskId)
                BDPlugin.localResumeData.remove(taskId)
                BDPlugin.notificationConfigs.remove(taskId)
            }
        }
        scope.launch {
            for (bgPost in backgroundPostQueue) {
                val success = CompletableDeferred<Boolean>()
                launch(Dispatchers.Main) {
                    try {
                        val argList = mutableListOf<Any>(
                            TaskWorker.taskToJsonString(bgPost.task)
                        )
                        if (bgPost.arg is ArrayList<*>) {
                            argList.addAll(bgPost.arg)
                        } else {
                            argList.add(bgPost.arg)
                        }
                        val bgChannel = BDPlugin.backgroundChannel(taskId = bgPost.task.taskId)
                        if (bgChannel != null) {
                            bgChannel.invokeMethod(
                                bgPost.method, argList, FlutterResultHandler(success)
                            )
                        } else {
                            Log.i(
                                TaskWorker.TAG,
                                "Could not post ${bgPost.method} to background channel"
                            )
                            success.complete(false)
                        }
                    } catch (e: Exception) {
                        Log.w(
                            TaskWorker.TAG,
                            "Exception trying to post ${bgPost.method} to background channel: ${e.message}"
                        )
                        if (!success.isCompleted) {
                            success.complete(false)
                        }
                    }
                    // Complete the success completer that was part of the backgroundPost
                    if (!bgPost.postedFromUIThread) {
                        bgPost.success.complete(!BDPlugin.forceFailPostOnBackgroundChannel && success.await())
                    }
                }
                if (bgPost.postedFromUIThread) {
                    bgPost.success.complete(!BDPlugin.forceFailPostOnBackgroundChannel)
                }
            }
        }

        scope.launch {
            for (change in requireWiFiQueue) {
                change.execute()
                while (!reEnqueueQueue.isEmpty) {
                    delay(1000)
                }
            }
        }

        scope.launch {
            for (reEnqueue in reEnqueueQueue) {
                delay(200)
                reEnqueue.execute()
            }
        }
    }


    /**
     * Remove this [taskId] from the [BDPlugin.bgChannelByTaskId] map and the
     * [BDPlugin.localResumeData] map
     */
    suspend fun cleanupTaskId(taskId: String) {
        lastTaskIdAdditionTime = System.currentTimeMillis()
        taskIdDeletionQueue.send(taskId)
    }

    /**
     * Post this [BackgroundPost] on the background channel, on the main/UI thread, and
     * complete the [BackgroundPost.success] completer with the result
     */
    suspend fun postOnBackgroundChannel(bgPost: BackgroundPost) {
        backgroundPostQueue.send(bgPost)
    }

    /**
     * Execute the requireWiFi change request
     */
    suspend fun requireWiFiChange(change: RequireWiFiChange) {
        requireWiFiQueue.send(change)
    }

    /**
     * Execute the reEnqueue request
     */
    suspend fun reEnqueue(reEnqueue: ReEnqueue) {
        reEnqueueQueue.send(reEnqueue)
    }

}

/**
 * BackgroundPost to be sent via backgroundChannel to Flutter, used in [QueueService]
 */
data class BackgroundPost(
    val task: Task,
    val method: String,
    val arg: Any,
) {
    val postedFromUIThread = Looper.myLooper() == Looper.getMainLooper()
    val success = CompletableDeferred<Boolean>()
}

/**
 * Change the global WiFi requirement setting
 */
class RequireWiFiChange(
    private val applicationContext: Context,
    private val requireWifi: RequireWifi,
    private val rescheduleRunningTasks: Boolean
) {
    suspend fun execute() {
        BDPlugin.requireWifi = requireWifi
        val prefs = PreferenceManager.getDefaultSharedPreferences(applicationContext)
        prefs.edit().apply {
            putInt(BDPlugin.keyRequireWiFi, requireWifi.ordinal)
            apply()
        }
        val tasksMap = getTaskMap(prefs)
        val workManager = WorkManager.getInstance(applicationContext)
        val workInfos = workManager.getWorkInfosByTag(BDPlugin.TAG).get()
            .filter { !it.state.isFinished }
        for (workInfo in workInfos) {
            val tags = workInfo.tags.filter { it.contains("taskId=") }
            if (tags.isNotEmpty()) {
                val taskId = tags.first().substring(7)
                val task = tasksMap[taskId]
                if (task != null && task.isDownloadTask()) {
                    if (BDPlugin.taskRequiresWifi(task) != BDPlugin.taskIdsRequiringWiFi.contains(
                            task.taskId
                        )
                    ) {
                        when (BDPlugin.taskRequiresWifi(task)) {
                            false -> BDPlugin.taskIdsRequiringWiFi.remove(task.taskId)
                            true -> BDPlugin.taskIdsRequiringWiFi.add(task.taskId)
                        }
                        when (workInfo.state) {
                            WorkInfo.State.ENQUEUED -> {
                                BDPlugin.tasksToReEnqueue.add(task)
                                if (!BDPlugin.cancelActiveTaskWithId(
                                        applicationContext,
                                        task.taskId,
                                        workManager
                                    )
                                ) {
                                    BDPlugin.tasksToReEnqueue.remove(task)
                                }
                            }

                            WorkInfo.State.RUNNING -> {
                                if (rescheduleRunningTasks) {
                                    BDPlugin.tasksToReEnqueue.add(task)
                                    BDPlugin.pauseTaskWithId(task.taskId)
                                }
                            }

                            else -> {}
                        }
                    }
                }
            }
        }
    }
}

/**
 * Re-enqueue a task (in the context of changing the RequireWiFi setting)
 */
class ReEnqueue(
    private val context: Context,
    private val task: Task,
    private val notificationConfigJsonString: String?,
    private val resumeData: ResumeData?
) {
    suspend fun execute() {
        BDPlugin.doEnqueue(
            context = context,
            task = task,
            notificationConfigJsonString = notificationConfigJsonString,
            resumeData = resumeData
        )
    }
}
