package com.bbflight.background_downloader

import android.content.Context
import androidx.preference.PreferenceManager
import androidx.work.WorkInfo
import androidx.work.WorkManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.util.Date

/**
 * Processes WiFi requirement changes
 *
 * requireWiFiQueue:
 *    Each item is a [RequireWiFiChange] data object, and each workInfo
 *    will be either rescheduled (if enqueued) or paused and resumed (if running and
 *    possible) or cancelled and re-enqueued (if running and pause not possible
 *
 * reEnqueueQueue:
 *    Each item is a [ReEnqueue] data object represent one task re-enqueue. The task
 *    will be re-enqueued with an appropriate delay
 */
@OptIn(ExperimentalCoroutinesApi::class)
object WiFi {
    private val scope = CoroutineScope(Dispatchers.Default)

    private val requireWiFiQueue =
        Channel<RequireWiFiChange>(capacity = Channel.UNLIMITED)
    private val reEnqueueQueue = Channel<ReEnqueue>(capacity = Channel.UNLIMITED)

    init {
        scope.launch {
            for (change in requireWiFiQueue) {
                while (!reEnqueueQueue.isEmpty) {
                    delay(1000)
                }
                change.execute()
            }
        }

        scope.launch {
            for (reEnqueue in reEnqueueQueue) {
                reEnqueue.execute()
            }
        }
    }

    /**
     * Execute the requireWiFi change request
     */
    suspend fun requireWiFiChange(change: RequireWiFiChange) {
        requireWiFiQueue.send(change)
    }

    /**
     * Re-enqueue this task and associated data. Null signals end of batch
     */
    suspend fun reEnqueue(reEnqueue: ReEnqueue) {
        reEnqueueQueue.send(reEnqueue)
    }
}

/**
 * Change the global WiFi requirement setting
 */
class RequireWiFiChange(
    private val applicationContext: Context,
    private val requireWifi: RequireWiFi,
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
    private val resumeData: ResumeData?,
    private val created: Date = Date()
) {


    /** Execute the re-enqueue after an appropriate delay */
    suspend fun execute() {
        val timeSinceCreatedMillis = Date().time - created.time
        if (timeSinceCreatedMillis < 1000) {
            delay(1000 - timeSinceCreatedMillis)
        }
        BDPlugin.doEnqueue(
            context = context,
            task = task,
            notificationConfigJsonString = notificationConfigJsonString,
            resumeData = resumeData
        )
    }
}
