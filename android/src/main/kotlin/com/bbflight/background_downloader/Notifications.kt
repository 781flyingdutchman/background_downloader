package com.bbflight.background_downloader

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
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
class Notification(val title: String, val body: String) {
    override fun toString(): String {
        return "Notification(title='$title', body='$body')"
    }
}

/**
 * Notification configuration object
 *
 * [runningNotification] is the notification used while the task is in progress
 * [completeNotification] is the notification used when the task completed
 * [errorNotification] is the notification used when something went wrong,
 * including pause, failed and notFound status
 */
class NotificationConfig(
        val runningNotification: Notification?,
        val completeNotification: Notification?,
        val errorNotification: Notification?,
        val pausedNotification: Notification?,
        val progressBar: Boolean
) {
    override fun toString(): String {
        return "NotificationConfig(runningNotification=$runningNotification, completeNotification=$completeNotification, errorNotification=$errorNotification, pausedNotification=$pausedNotification, progressBar=$progressBar)"
    }
}

enum class NotificationType { running, complete, error, paused }

/**
 * Receiver for messages from notification, sent via intent
 */
class NotificationBroadcastReceiver : BroadcastReceiver() {

    companion object {
        val actionCancel = "com.bbflight.background_downloader.cancel"
        val actionPause = "com.bbflight.background_downloader.pause"
        val extraTaskId = "com.bbflight.background_downloader.taskId"
    }

    override fun onReceive(context: Context, intent: Intent) {
        Log.d(TAG, "Receiving ${intent.action}")
        val taskId = intent.getStringExtra(extraTaskId)
        if (taskId != null) {
            runBlocking {
                when (intent.action) {
                    actionCancel -> {
                        BackgroundDownloaderPlugin.cancelTaskWithId(context, taskId, WorkManager
                                .getInstance(context))
                    }
                    actionPause -> {

                        //TODO cancel
                    }
                    else -> {}
                }
            }
        }
    }
}

