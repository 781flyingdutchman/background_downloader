package com.bbflight.background_downloader

import android.content.Context
import androidx.core.app.NotificationManagerCompat
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import kotlinx.serialization.json.Json

/**
 * Worker that updates the notification for a task, given a
 * NotificationConfig and a TaskStatus.
 *
 * Used to update a task notification initiated from the Dart side, when
 * no actual TaskWorker is active for the task, e.g. when failing for the
 * last time on retry.  We need a [TaskWorker] in order to call the
 * [NotificationService] to update the associated notification.
 *
 * Note this implementation is only valid for two situations:
 * - taskStatus is null -> deletes the notification
 * - taskStatus is TaskStatus.failed -> displays error notification if needed
 */
class UpdateNotificationWorker(applicationContext: Context, workerParams: WorkerParameters) :
    CoroutineWorker(applicationContext, workerParams) {

    companion object {
        const val keyTaskStatusOrdinal = "taskStatusOrdinal"
    }

    override suspend fun doWork(): Result {
        val task = Json.decodeFromString<Task>(inputData.getString(TaskWorker.keyTask)!!)
        val notificationConfigJsonString = inputData.getString(TaskWorker.keyNotificationConfig)
        val notificationConfig =
            if (notificationConfigJsonString != null) Json.decodeFromString<NotificationConfig>(notificationConfigJsonString) else null
        val taskStatusOrdinal = inputData.getInt(keyTaskStatusOrdinal, -1)
        val notificationId = task.taskId.hashCode()
        if (taskStatusOrdinal == -1) {
            // delete notification
            with(NotificationManagerCompat.from(applicationContext)) {
                cancel(notificationId)
            }
        } else {
            // update notification for this taskStatus
            val taskStatus = TaskStatus.entries[taskStatusOrdinal]
            // We need to create a dummy TaskExecutor or similar to pass to NotificationService.
            // NotificationService expects a TaskExecutor to read config/state.
            // But we don't have a full executor here.
            // We can perhaps refactor NotificationService to take just the data it needs, or
            // create a lightweight wrapper.
            // Or we can construct a dummy TaskExecutor.

            // Refactoring NotificationService is cleaner but touches more files.
            // Creating a dummy wrapper is safer for now.
            val dummyServer = object : TaskServer {
                override val applicationContext: Context get() = this@UpdateNotificationWorker.applicationContext
                override val isStopped: Boolean get() = false
                override suspend fun makeForeground(notificationId: Int, notification: android.app.Notification) {}
                override suspend fun updateNotification(
                    taskExecutor: TaskExecutor,
                    notificationType: NotificationType,
                    notification: TaskNotification?,
                    progress: Double,
                    timeRemaining: Long
                ) {}
            }

            // We create a dummy executor.
            // Note: DataTaskExecutor is simple enough to use as base? Or just TaskExecutor directly if it wasn't abstract.
            // TaskExecutor is abstract. We need a concrete implementation.
            val dummyExecutor = object : TaskExecutor(
                dummyServer, task, notificationConfigJsonString, null
            ) {
                override fun determineIfResume() = false
                override suspend fun process(connection: java.net.HttpURLConnection) = TaskStatus.failed // unused
            }
            // Manually set properties that NotificationService might read
            dummyExecutor.notificationConfig = notificationConfig
            dummyExecutor.notificationId = notificationId

            NotificationService.updateNotification(dummyExecutor, taskStatus)
        }
        return Result.success()
    }
}
