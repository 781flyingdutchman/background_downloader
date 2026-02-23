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

class UIDTJobService : JobService() {

    private val jobs = java.util.concurrent.ConcurrentHashMap<Int, Job>()

    override fun onStartJob(params: JobParameters?): Boolean {
        Log.d(TaskRunner.TAG, "Starting UIDT JobService")
        if (params == null) return false

        val extras = params.extras
        val taskJson = extras.getString(TaskWorker.keyTask)
        if (taskJson == null) {
            Log.e(TaskRunner.TAG, "Task JSON not found in job parameters")
            return false
        }

        val jobContext = UIDTJobContext(this, params)
        try {
            jobContext.task = Json.decodeFromString(taskJson)
            jobContext.notificationConfigJsonString = extras.getString(TaskWorker.keyNotificationConfig)
            if (jobContext.notificationConfigJsonString != null) {
                jobContext.notificationConfig = Json.decodeFromString(jobContext.notificationConfigJsonString!!)
            }
        } catch (e: Exception) {
            Log.e(TaskRunner.TAG, "Failed to decode task or notification config: $e")
            return false
        }

        // Determine runner based on task type.
        val runner = when (jobContext.task.taskType) {
            "DownloadTask" -> DownloadTaskRunner(jobContext)
            "UriDownloadTask" -> DownloadTaskRunner(jobContext)
            "UploadTask" -> UploadTaskRunner(jobContext)
            "UriUploadTask" -> UploadTaskRunner(jobContext)
            "MultiUploadTask" -> UploadTaskRunner(jobContext)
            "DataTask" -> DataTaskRunner(jobContext)
            "ParallelDownloadTask" -> ParallelDownloadTaskRunner(jobContext)
            else -> {
                Log.e(TaskRunner.TAG, "Unknown task type: ${jobContext.task.taskType}")
                return false
            }
        }

        val job = CoroutineScope(Dispatchers.IO).launch {
            runner.run()
            Log.d(TaskRunner.TAG, "UIDT JobService finished for taskId ${jobContext.task.taskId}")
            jobs.remove(params.jobId)
            jobFinished(params, false) // Needs reschedule? usually false for these tasks as we manage retries internally
        }
        jobs[params.jobId] = job

        return true // Work is still running on background thread
    }

    override fun onStopJob(params: JobParameters?): Boolean {
        Log.i(TaskRunner.TAG, "Stopping UIDT JobService")
        if (params != null) {
            jobs.remove(params.jobId)?.cancel()
        }
        return true // Reschedule? If system stopped it, maybe we want to retry?
    }

    /**
     * Context for a single job execution, holding the state for that specific task/job
     */
    class UIDTJobContext(val service: JobService, val params: JobParameters) : TaskJobContext {
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
            get() = service.applicationContext

        override val isTaskStopped: Boolean
            get() = !isActive // Simple check if job is active

        override val isActive: Boolean
            get() {
                 // ideally we check if the specific job is still active, but we don't have easy access
                 // to the job object here without circular dependency or passing it in later.
                 // However, onStopJob cancels the coroutine, so the check in TaskRunner via isActive
                 // (CoroutineScope) should handle it.
                 // TaskJobContext.isActive is used for some checks.
                 // For now, return true, relying on coroutine cancellation to stop the runner's loop.
                 return true
            }


        override fun getInputLong(key: String, defaultValue: Long): Long {
            return params.extras?.getLong(key, defaultValue) ?: defaultValue
        }

        override fun getInputString(key: String): String? {
            return params.extras?.getString(key)
        }

        override suspend fun setForegroundNotification(
            notificationId: Int,
            notification: Notification,
            notificationType: Int
        ) {
            if (Build.VERSION.SDK_INT >= 34) {
                service.setNotification(params, notificationId, notification, notificationType)
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                service.startForeground(notificationId, notification, notificationType)
            } else {
                service.startForeground(notificationId, notification)
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
            if (Build.VERSION.SDK_INT >= 34) {
                service.updateEstimatedNetworkBytes(params, downloadBytes, uploadBytes)
            }
        }
    }
}
