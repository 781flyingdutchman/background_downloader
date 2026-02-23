package com.bbflight.background_downloader

import android.app.Notification
import android.content.Context
import android.content.SharedPreferences
import androidx.preference.PreferenceManager
import androidx.work.CoroutineWorker
import androidx.work.ForegroundInfo
import androidx.work.WorkerParameters
import kotlinx.serialization.json.Json

/**
 * The worker to execute one task
 *
 * It is now a wrapper around [TaskRunner], delegating the actual work to it.
 * This class implements [TaskJobContext] to provide the context for the [TaskRunner].
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
        setForeground(ForegroundInfo(notificationId, notification, notificationType))
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
                task = Json.decodeFromString(taskJson)
            } else {
                return Result.failure()
            }

            notificationConfigJsonString = inputData.getString(keyNotificationConfig)
            if (notificationConfigJsonString != null) {
                notificationConfig = Json.decodeFromString(notificationConfigJsonString!!)
            }
            
            // Check runInForeground pre-requisite (shared pref check done in Runner mostly, 
            // but might need initial value for context?)
             val prefs = PreferenceManager.getDefaultSharedPreferences(applicationContext)
             val runInForegroundFileSize = prefs.getInt(BDPlugin.keyConfigForegroundFileSize, -1)
             // simplified check, Runner does full check
             // But we need to set runInForeground to false initially
             runInForeground = false 

            val runner = createRunner()
            runner.run()
            
            return Result.success()
        } catch (e: Exception) {
            return Result.failure()
        }
    }

    /**
     * Create the appropriate [TaskRunner] for this worker
     *
     * Must be overridden by subclasses
     */
    open fun createRunner(): TaskRunner {
        // Should not be called directly on TaskWorker, but abstract not allowed on non-abstract class
        // And TaskWorker needs to be instantiable for UpdateNotificationWorker?
        // UpdateNotificationWorker overrides doWork entirely, so createRunner is not called.
        // But for other workers, it must be overridden.
        throw NotImplementedError("Subclasses must override createRunner")
    }
}
