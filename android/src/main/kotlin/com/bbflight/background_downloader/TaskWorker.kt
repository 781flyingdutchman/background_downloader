package com.bbflight.background_downloader

import android.app.Notification
import android.content.Context
import android.content.SharedPreferences
import androidx.preference.PreferenceManager
import androidx.work.CoroutineWorker
import androidx.work.ForegroundInfo
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import android.util.Log

/**
 * The worker to execute one task
 *
 * Wraps [TaskRunner], delegating the actual work to it, and implements
 * [TaskJobContext] to provide the context for the [TaskRunner].
 */
@Suppress("ConstPropertyName")
open class TaskWorker(
    val context: Context,
    workerParams: WorkerParameters
) : CoroutineWorker(context, workerParams), TaskJobContext {

    companion object {
        const val keyTask = "Task"
        const val keyNotificationConfig = "notificationConfig"
        const val keyResumeDataData = "tempFilename"
        const val keyStartByte = "startByte"
        const val keyETag = "eTag"
        const val bufferSize = 2 shl 12

        /** Converts [Task] to JSON string representation */
        fun taskToJsonString(task: Task): String {
            return TaskRunner.taskToJsonString(task)
        }

        /**
         * Processes a change in status for the task
         *
         * Delegates to [TaskRunner.processStatusUpdate]
         */
        suspend fun processStatusUpdate(
            task: Task,
            status: TaskStatus,
            prefs: SharedPreferences,
            taskException: TaskException? = null,
            responseBody: String? = null,
            responseHeaders: Map<String, String>? = null,
            responseStatusCode: Int? = null,
            mimeType: String? = null,
            charSet: String? = null,
            context: Context
        ) {
            TaskRunner.processStatusUpdate(
                task,
                status,
                prefs,
                taskException,
                responseBody,
                responseHeaders,
                responseStatusCode,
                mimeType,
                charSet,
                context
            )
        }
    }

    override val appContext: Context
        get() = applicationContext
    override val runId: String
        get() = id.toString()

    // TaskJobContext Mutable properties
    override lateinit var task: Task
    override var notificationConfig: NotificationConfig? = null
    override var notificationId: Int = 0
    override var notificationProgress: Double = 2.0 // indeterminate
    override var networkSpeed: Double = -1.0
    override var taskCanResume: Boolean = false
    override var notificationConfigJsonString: String? = null
    override var runInForeground: Boolean = false

    override val isTaskStopped: Boolean
        get() = isStopped



    override val isActive: Boolean
        get() = !isTaskStopped

    override fun getInputLong(key: String, defaultValue: Long): Long {
        return inputData.getLong(key, defaultValue)
    }

    override fun getInputString(key: String): String? {
        return inputData.getString(key)
    }

    override suspend fun setForegroundNotification(
        notificationId: Int,
        notification: Notification,
        notificationType: Int
    ) {
        try {
            setForeground(ForegroundInfo(notificationId, notification, notificationType))
        } catch (e: IllegalStateException) {
            Log.d("TaskWorker", "Ignoring setForeground: worker already completed. ${e.message}")
        }
    }

    override suspend fun updateNotification(
        task: Task,
        status: TaskStatus,
        progress: Double,
        timeRemaining: Long
    ) {
        NotificationService.updateNotification(this, status, progress, timeRemaining)
    }

    override fun updateEstimatedNetworkBytes(downloadBytes: Long, uploadBytes: Long) {
        // No-op for TaskWorker
    }


    override suspend fun doWork(): Result {
        try {
            // Initialize task and notificationConfig from inputData
            val taskJson = inputData.getString(keyTask)
            if (taskJson != null) {
                task = bdJson.decodeFromString(taskJson)
            } else {
                return Result.failure()
            }

            notificationConfigJsonString = inputData.getString(keyNotificationConfig)
            if (notificationConfigJsonString != null) {
                notificationConfig = bdJson.decodeFromString(notificationConfigJsonString!!)
            }
            
            runInForeground = false 

            if (runAttemptCount > 0 && skipReRun()) {
                return Result.success()
            }
            val runner = createRunner()
            runner.run()
            
            return Result.success()
        } catch (e: Exception) {
            return Result.failure()
        }
    }

    /**
     * Returns true if this WorkManager re-run must end without running its task, because the
     * task already finished or another work supersedes it, and gives back a finished task's slot
     *
     * WorkManager starts a work again after it stopped it, and after a process death for works
     * it didn't see finish, without asking the holding queue
     */
    private suspend fun skipReRun(): Boolean {
        val prefs = PreferenceManager.getDefaultSharedPreferences(applicationContext)
        val taskInTasksMap = getTaskMap(prefs).containsKey(task.taskId)
        val otherUnfinishedWorkIds = withContext(Dispatchers.IO) {
            WorkManager.getInstance(applicationContext)
                .getWorkInfosByTag("taskId=${task.taskId}").get()
        }.filter { !it.state.isFinished && it.id != id }.map { it.id.toString() }
        val attempt = "WorkManager re-run (attempt $runAttemptCount) of taskId ${task.taskId}"
        return when (reRunDecision(runAttemptCount, taskInTasksMap, otherUnfinishedWorkIds)) {
            ReRunDecision.run -> {
                Log.i(BDPlugin.TAG, "Running $attempt")
                false
            }

            ReRunDecision.skipFinished -> {
                Log.i(BDPlugin.TAG, "Skipping $attempt: finished")
                // the slot the holding queue counted for this work, unless a cancel released it
                if (!BDPlugin.slotReleasedRunIds.remove(runId)) {
                    BDPlugin.holdingQueue?.taskFinished(task)
                }
                true
            }

            ReRunDecision.skipSuperseded -> {
                // the other work holds the task's slot, and releases it when it ends
                Log.i(BDPlugin.TAG, "Skipping $attempt: superseded by ${otherUnfinishedWorkIds.first()}")
                true
            }
        }
    }

    /**
     * Create the appropriate [TaskRunner] for this worker
     *
     * Must be overridden by subclasses
     */
    open fun createRunner(): TaskRunner {
        throw NotImplementedError("Subclasses must override createRunner")
    }
}

/** What a WorkManager run of a task does, see [reRunDecision] */
@Suppress("EnumEntryName")
enum class ReRunDecision {
    run,
    skipFinished, // the task's final state was already processed
    skipSuperseded // another unfinished work for the task exists
}

/**
 * Decides whether a WorkManager run with [runAttemptCount] runs its task, given whether the task
 * is still in the tasks map ([taskInTasksMap]) and the ids of other unfinished works for it
 *
 * A first run (attempt 0) always runs. A re-run is skipped if another work supersedes it, or else
 * if its task already finished
 */
fun reRunDecision(
    runAttemptCount: Int,
    taskInTasksMap: Boolean,
    otherUnfinishedWorkIds: List<String>
): ReRunDecision = when {
    runAttemptCount == 0 -> ReRunDecision.run
    otherUnfinishedWorkIds.isNotEmpty() -> ReRunDecision.skipSuperseded
    !taskInTasksMap -> ReRunDecision.skipFinished
    else -> ReRunDecision.run
}
