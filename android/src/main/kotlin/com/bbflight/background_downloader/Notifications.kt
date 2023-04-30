package com.bbflight.background_downloader

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.util.Log
import androidx.annotation.Keep
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.work.WorkManager
import com.bbflight.background_downloader.BackgroundDownloaderPlugin.Companion.TAG
import kotlinx.coroutines.runBlocking

/**
 * Notification specification
 *
 * [body] may contain special string {filename] to insert the filename
 *   and/or special string {progress} to insert progress in %
 *
 * Actual appearance of notification is dependent on the platform, e.g.
 * on iOS {progress} and progressBar are not available and ignored
 */
@Keep
class TaskNotification(val title: String, val body: String) {
    override fun toString(): String {
        return "Notification(title='$title', body='$body')"
    }
}

/**
 * Notification configuration object
 *
 * [running] is the notification used while the task is in progress
 * [complete] is the notification used when the task completed
 * [error] is the notification used when something went wrong,
 * including pause, failed and notFound status
 */
@Keep
class NotificationConfig(
    val running: TaskNotification?,
    val complete: TaskNotification?,
    val error: TaskNotification?,
    val paused: TaskNotification?,
    val progressBar: Boolean,
    val tapOpensFile: Boolean
) {
    override fun toString(): String {
        return "NotificationConfig(running=$running, complete=$complete, error=$error, " +
                "paused=$paused, progressBar=$progressBar, tapOpensFile=$tapOpensFile)"
    }
}

@Suppress("EnumEntryName")
enum class NotificationType { running, complete, error, paused }

/**
 * Receiver for messages from notification, sent via intent
 *
 * Note the two cancellation actions: one for active tasks (running and managed by a
 * [WorkManager] and one for inactive (paused) tasks. Because the latter is not running in a
 * [WorkManager] job, cancellation is simpler, but the [NotificationRcvr] must remove the
 * notification that asked for cancellation directly from here. If an 'error' notification
 * was configured for the task, then it will NOT be shown (as it would when cancelling an active
 * task)
 */
@Keep
class NotificationRcvr : BroadcastReceiver() {

    companion object {
        const val actionCancelActive = "com.bbflight.background_downloader.cancelActive"
        const val actionCancelInactive = "com.bbflight.background_downloader.cancelInactive"
        const val actionPause = "com.bbflight.background_downloader.pause"
        const val actionResume = "com.bbflight.background_downloader.resume"
        const val actionTap = "com.bbflight.background_downloader.tap"
        const val extraBundle = "com.bbflight.background_downloader.bundle"
        const val bundleTaskId = "com.bbflight.background_downloader.taskId"
        const val bundleTask = "com.bbflight.background_downloader.task" // as JSON string
        const val bundleNotificationConfig =
            "com.bbflight.background_downloader.notificationConfig" // as JSON string
        const val bundleNotificationType =
            "com.bbflight.background_downloader.notificationType" // ordinal of enum
    }

    override fun onReceive(context: Context, intent: Intent) {
        val bundle = intent.getBundleExtra(extraBundle)
        val taskId = bundle?.getString(bundleTaskId)
        if (taskId != null) {
            runBlocking {
                when (intent.action) {
                    actionCancelActive -> {
                        BackgroundDownloaderPlugin.cancelActiveTaskWithId(
                            context, taskId, WorkManager.getInstance(context)
                        )
                    }

                    actionCancelInactive -> {
                        val taskJsonString = bundle.getString(bundleTask)
                        if (taskJsonString != null) {
                            val task = Task(
                                BackgroundDownloaderPlugin.gson.fromJson(
                                    taskJsonString, BackgroundDownloaderPlugin.jsonMapType
                                )
                            )
                            BackgroundDownloaderPlugin.cancelInactiveTask(context, task)
                            with(NotificationManagerCompat.from(context)) {
                                cancel(task.taskId.hashCode())
                            }
                        } else {
                            Log.d(TAG, "task was null")
                        }
                    }

                    actionPause -> {
                        BackgroundDownloaderPlugin.pauseTaskWithId(taskId)
                    }

                    actionResume -> {
                        val resumeData = BackgroundDownloaderPlugin.localResumeData[taskId]
                        if (resumeData != null) {
                            val taskJsonString = bundle.getString(bundleTask)
                            val notificationConfigJsonString = bundle.getString(
                                bundleNotificationConfig
                            )
                            if (notificationConfigJsonString != null && taskJsonString != null) {
                                BackgroundDownloaderPlugin.doEnqueue(
                                    context,
                                    taskJsonString,
                                    notificationConfigJsonString,
                                    resumeData.data,
                                    resumeData.requiredStartByte
                                )
                            } else {
                                BackgroundDownloaderPlugin.cancelActiveTaskWithId(
                                    context, taskId, WorkManager.getInstance(context)
                                )
                            }
                        } else {
                            BackgroundDownloaderPlugin.cancelActiveTaskWithId(
                                context, taskId, WorkManager.getInstance(context)
                            )
                        }
                    }

                    else -> {}
                }
            }
        }
    }
}

