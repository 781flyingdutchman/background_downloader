package com.bbflight.background_downloader

import android.content.Context
import android.net.NetworkCapabilities
import android.os.Build
import android.util.Log
import androidx.preference.PreferenceManager
import androidx.work.Constraints
import androidx.work.NetworkType
import androidx.work.WorkInfo
import androidx.work.WorkManager
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

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
object WiFi {
    private val scope = CoroutineScope(Dispatchers.Default)

    private val requireWiFiQueue =
        Channel<RequireWiFiChange>(capacity = Channel.UNLIMITED)
    private val reEnqueueQueue = Channel<suspend () -> Unit>(capacity = Channel.UNLIMITED)

    // completed once the current change's re-enqueues are enqueued
    @Volatile
    private var batchEnd: CompletableDeferred<Unit>? = null

    init {
        scope.launch {
            for (change in requireWiFiQueue) {
                val thisBatchEnd = CompletableDeferred<Unit>()
                batchEnd = thisBatchEnd
                try {
                    // wait for the re-enqueues before the next change, with a timeout
                    if (change.execute() && withTimeoutOrNull(15000) { thisBatchEnd.await() } == null) {
                        val clearedTaskIds = synchronized(BDPlugin.tasksToReEnqueue) {
                            BDPlugin.tasksToReEnqueue.map { it.taskId }
                                .also { BDPlugin.tasksToReEnqueue.clear() }
                        }
                        Log.w(
                            BDPlugin.TAG,
                            "WiFi re-enqueue watchdog timeout, cleared taskIds $clearedTaskIds"
                        )
                    }
                } catch (e: Exception) {
                    Log.e(BDPlugin.TAG, "Exception during requireWiFiChange execution: $e")
                }
            }
        }

        scope.launch {
            for (reEnqueue in reEnqueueQueue) {
                try {
                    reEnqueue()
                } catch (e: Exception) {
                    Log.e(BDPlugin.TAG, "Exception during WiFi reEnqueue: $e")
                }
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
    suspend fun reEnqueue(enqueueItem: EnqueueItem?) {
        if (enqueueItem != null) {
            reEnqueueQueue.send { enqueueItem.reEnqueue() }
        } else {
            // captured now, so a late signal cannot end a later batch
            val thisBatchEnd = batchEnd
            reEnqueueQueue.send { thisBatchEnd?.complete(Unit) }
        }
    }
}

/**
 * Change the global WiFi requirement setting
 */
class RequireWiFiChange(
    private val applicationContext: Context,
    private val requireWifi: RequireWiFi,
    private val rescheduleRunningTasks: Boolean,
    private val alsoRestartUploads: Boolean
) {
    /**
     * Execute the change in WiFi requirement and return
     * true if one or more tasks have been scheduled for re-enqueue
     */
    suspend fun execute(): Boolean {
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
        // collected first and all added to tasksToReEnqueue before any is canceled or paused,
        // so the set can't run empty, which ends the batch, before the last task is added
        val tasksToCancel = mutableListOf<Task>()
        val tasksToPause = mutableListOf<Task>()
        for (workInfo in workInfos) {
            val tags = workInfo.tags.filter { it.contains("taskId=") }
            if (tags.isNotEmpty()) {
                val taskId = tags.first().substring(7)
                val task = tasksMap[taskId]
                if (task != null && (task.isDownloadTask() || task.isUploadTask())) {
                    // compare with the constraints the work was enqueued with, which WorkManager
                    // keeps across app restarts, so work enqueued by an earlier process is included
                    if (BDPlugin.taskRequiresWifi(task) != workInfo.constraints.requiresWifi()) {
                        when (workInfo.state) {
                            WorkInfo.State.ENQUEUED -> tasksToCancel.add(task)

                            WorkInfo.State.RUNNING -> {
                                if (rescheduleRunningTasks && task.isDownloadTask()) {
                                    tasksToPause.add(task)
                                } else if (alsoRestartUploads && task.isUploadTask()) {
                                    tasksToCancel.add(task)
                                }
                            }

                            else -> {}
                        }
                    }
                }
            }
        }
        BDPlugin.tasksToReEnqueue.addAll(tasksToCancel + tasksToPause)
        tasksToPause.forEach { BDPlugin.pauseTaskWithId(it.taskId) }
        for (task in tasksToCancel) {
            // the cancel's update is intercepted within cancelActiveTaskWithId, so an entry still
            // there means it sent none: the task finished before it was added, and its entry
            // would otherwise stay until the timeout
            if (!BDPlugin.cancelActiveTaskWithId(applicationContext, task.taskId, workManager) ||
                BDPlugin.tasksToReEnqueue.contains(task)
            ) {
                BDPlugin.tasksToReEnqueue.remove(task)
                if (BDPlugin.tasksToReEnqueue.isEmpty()) {
                    WiFi.reEnqueue(null) // nothing left to re-enqueue, so end the batch
                }
            }
        }
        return tasksToCancel.isNotEmpty() || tasksToPause.isNotEmpty()
    }

    /**
     * Return true if these [Constraints] restrict the work to WiFi, as set in [BDPlugin.doEnqueue]
     *
     * From API 28 the WiFi requirement is a NetworkRequest, and WorkManager then stores
     * NetworkType.NOT_REQUIRED as the network type. Before API 28 it is NetworkType.UNMETERED
     */
    private fun Constraints.requiresWifi(): Boolean =
        (Build.VERSION.SDK_INT >= 28 &&
                requiredNetworkRequest?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true) ||
                requiredNetworkType == NetworkType.UNMETERED
}