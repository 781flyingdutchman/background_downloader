package com.bbflight.background_downloader

import android.annotation.SuppressLint
import android.app.Notification
import android.app.job.JobParameters
import android.app.job.JobService
import android.content.Context
import android.os.Build
import android.util.Log
import androidx.annotation.RequiresApi
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import java.util.concurrent.ConcurrentHashMap

@RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
class UidtJobService : JobService(), TaskServer {

    private val jobMap = ConcurrentHashMap<Int, Job>() // Map of jobId to Coroutine Job
    private val paramsMap = ConcurrentHashMap<Int, JobParameters>() // Map of jobId to JobParameters
    private val scope = CoroutineScope(Dispatchers.Default)
    private val stoppedJobs = ConcurrentHashMap.newKeySet<Int>()

    override val applicationContext: Context
        get() = this

    override val isStopped: Boolean
        get() = false // Individual task executors check their specific stop signal if needed, but here we manage per job

    /**
     * Called when the JobScheduler decides to start the job.
     * We return true to indicate that we are doing work on a background thread.
     */
    override fun onStartJob(params: JobParameters?): Boolean {
        if (params == null) return false

        val jobId = params.jobId
        paramsMap[jobId] = params
        stoppedJobs.remove(jobId)

        val extras = params.extras
        val taskJson = extras.getString(TaskWorker.keyTask)
        if (taskJson == null) {
            Log.e(TAG, "Task JSON missing in JobParameters for jobId $jobId")
            return false
        }

        val task = Json.decodeFromString<Task>(taskJson)
        val notificationConfigJsonString = extras.getString(TaskWorker.keyNotificationConfig)
        val resumeData = if (extras.getLong(TaskWorker.keyStartByte, 0L) != 0L) {
            ResumeData(
                task,
                extras.getString(TaskWorker.keyResumeDataData) ?: "",
                extras.getLong(TaskWorker.keyStartByte, 0L),
                extras.getString(TaskWorker.keyETag)
            )
        } else null

        val executor = createExecutor(task, notificationConfigJsonString, resumeData)

        // Launch coroutine
        val job = scope.launch {
            try {
                executor.run()
                jobFinished(params, false) // Success, no reschedule
            } catch (e: Exception) {
                Log.e(TAG, "Error executing job for taskId ${task.taskId}", e)
                jobFinished(params, true) // Fail, reschedule? Or handle via retry logic in Executor
            } finally {
                jobMap.remove(jobId)
                paramsMap.remove(jobId)
            }
        }
        jobMap[jobId] = job

        return true // Work is continuing in background
    }

    /**
     * Called when the system stops the job (e.g. timeout or constraints no longer met).
     * We return true if we want to reschedule.
     */
    override fun onStopJob(params: JobParameters?): Boolean {
        if (params == null) return false
        val jobId = params.jobId
        stoppedJobs.add(jobId)

        val job = jobMap.remove(jobId)
        job?.cancel()
        paramsMap.remove(jobId)

        Log.i(TAG, "Job $jobId stopped by system")
        return true // Reschedule if stopped by system
    }

    private fun createExecutor(
        task: Task,
        notificationConfigJsonString: String?,
        resumeData: ResumeData?
    ): TaskExecutor {
        // We wrap 'this' (UidtJobService) as TaskServer, but we need to handle 'isStopped' per task/job.
        // Since TaskExecutor accesses 'server.isStopped', and we have multiple jobs potentially (though 1 service instance),
        // we need a way to delegate 'isStopped' to the specific job.
        // However, TaskExecutor is created per task. We can create a lightweight wrapper for TaskServer.

        val jobServer = object : TaskServer {
            override val applicationContext: Context
                get() = this@UidtJobService.applicationContext

            override val isStopped: Boolean
                get() = stoppedJobs.contains(getJobIdForTask(task))

            override suspend fun makeForeground(notificationId: Int, notification: Notification) {
                this@UidtJobService.makeForeground(getJobIdForTask(task), notificationId, notification)
            }
        }

        return when (task.taskType) {
            "DownloadTask", "UriDownloadTask" -> DownloadTaskExecutor(jobServer, task, notificationConfigJsonString, resumeData)
            "UploadTask", "UriUploadTask", "MultiUploadTask" -> UploadTaskExecutor(jobServer, task, notificationConfigJsonString, resumeData)
            "DataTask" -> DataTaskExecutor(jobServer, task, notificationConfigJsonString, resumeData)
            "ParallelDownloadTask" -> ParallelDownloadTaskExecutor(jobServer, task, notificationConfigJsonString, resumeData)
            else -> throw IllegalArgumentException("Unknown task type: ${task.taskType}")
        }
    }

    // Helper to map task to jobId - assuming jobId was derived from taskId hashCode
    private fun getJobIdForTask(task: Task): Int {
        return task.taskId.hashCode()
    }

    @SuppressLint("MissingPermission")
    override suspend fun makeForeground(notificationId: Int, notification: Notification) {
       // This method is called by TaskServer interface, but we need jobId.
       // We can't easily get jobId here without context.
       // The wrapper above calls the overloaded method below.
    }

    fun makeForeground(jobId: Int, notificationId: Int, notification: Notification) {
        val params = paramsMap[jobId]
        if (params != null) {
            try {
                // UIDT requires setNotification
                setNotification(params, notificationId, notification, android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            } catch (e: Exception) {
                 Log.w(TAG, "Failed to set notification for job $jobId: ${e.message}")
            }
        }
    }

    companion object {
        const val TAG = "UidtJobService"
    }
}
