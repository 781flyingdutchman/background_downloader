package com.bbflight.background_downloader

import android.app.Notification
import android.app.job.JobParameters
import android.app.job.JobService
import android.content.Context
import android.os.Build
import android.os.PersistableBundle
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json

class UIDTJobService : JobService(), TaskJobContext {

    private var job: Job? = null
    private var jobParameters: JobParameters? = null
    
    // TaskJobContext Properties
    override lateinit var task: Task
    override var notificationConfig: NotificationConfig? = null
    override var notificationId: Int = 0
    override var notificationProgress: Double = 2.0
    override var networkSpeed: Double = -1.0
    override var taskCanResume: Boolean = false
    override var notificationConfigJsonString: String? = null
    override var runInForeground: Boolean = true // UIDT always runs in foreground service
    
    override val appContext: Context
        get() = applicationContext

    override val isTaskStopped: Boolean
        get() = job?.isCancelled == true

    override val isActive: Boolean
        get() = job?.isActive == true

    override fun getInputLong(key: String, defaultValue: Long): Long {
         return jobParameters?.extras?.getLong(key, defaultValue) ?: defaultValue
    }

    override fun getInputString(key: String): String? {
        return jobParameters?.extras?.getString(key)
    }

    override suspend fun setForegroundNotification(
        notificationId: Int,
        notification: Notification,
        notificationType: Int
    ) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(notificationId, notification, notificationType)
        } else {
             startForeground(notificationId, notification)
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

    override fun onStartJob(params: JobParameters?): Boolean {
        Log.d(TaskRunner.TAG, "Starting UIDT JobService")
        jobParameters = params
        if (params == null) return false

        val extras = params.extras
        val taskJson = extras.getString(TaskWorker.keyTask)
        if (taskJson == null) {
            Log.e(TaskRunner.TAG, "Task JSON not found in job parameters")
            return false
        }

        try {
            task = Json.decodeFromString(taskJson)
            notificationConfigJsonString = extras.getString(TaskWorker.keyNotificationConfig)
            if (notificationConfigJsonString != null) {
                notificationConfig = Json.decodeFromString(notificationConfigJsonString!!)
            }
        } catch (e: Exception) {
            Log.e(TaskRunner.TAG, "Failed to decode task or notification config: $e")
            return false
        }
        
        // Determine runner based on task type.
        // Logic duplicated from BDPlugin.createRequestBuilder essentially, but here we instantiate Runner directly.
        val runner = when (task.taskType) {
            "DownloadTask" -> DownloadTaskRunner(this)
            "UriDownloadTask" -> DownloadTaskRunner(this) 
            "UploadTask" -> UploadTaskRunner(this)
            "UriUploadTask" -> UploadTaskRunner(this)
            "MultiUploadTask" -> UploadTaskRunner(this)
            "DataTask" -> DataTaskRunner(this)
            "ParallelDownloadTask" -> ParallelDownloadTaskRunner(this)
             else -> {
                Log.e(TaskRunner.TAG, "Unknown task type: ${task.taskType}")
                return false
            }
        }

        job = CoroutineScope(Dispatchers.IO).launch {
            runner.run()
            Log.d(TaskRunner.TAG, "UIDT JobService finished for taskId ${task.taskId}")
            jobFinished(params, false) // Needs reschedule? usually false for these tasks as we manage retries internally?
            // If runner failed, maybe reschedule? 
            // TaskRunner handles retries internally? 
            // TaskRunner logic handles retries by posting status updates?
            // If TaskRunner.run() returns, the task is either complete, failed (and updates sent), or paused.
            // If paused, we might want to finish job.
            // If failed, we might want to finish job.
            // We assume TaskRunner handled everything.
        }

        return true // Work is still running on background thread
    }

    override fun onStopJob(params: JobParameters?): Boolean {
        Log.i(TaskRunner.TAG, "Stopping UIDT JobService for taskId ${task.taskId}")
        job?.cancel()
        return true // Reschedule? If system stopped it, maybe we want to retry?
        // If we return true, JobScheduler will reschedule it.
        // WorkManager handles this with retry policy.
        // Only return true if we want the system to retry later.
        // Given we handle retries via internal logic or user-initiated, maybe true is okay?
        // But if we return true, it might restart the specific download attempt.
        // For now, let's return true to be safe for system-initiated stops (like resource constraints).
    }
}
