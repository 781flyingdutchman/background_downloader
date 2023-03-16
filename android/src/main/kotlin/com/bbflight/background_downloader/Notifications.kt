package com.bbflight.background_downloader

/**
 * Notification specification
 *
 * [body] may contain special string {filename] to insert the filename
 *   and/or special string {progress} to insert progress in %
 *
 * Actual appearance of notification is dependent on the platform, e.g.
 * on iOS {progress} and progressBar are not available and ignored
 */
class Notification (val title: String, val body: String) {
    override fun toString(): String {
        return "Notification(title='$title', body='$body')"
    }
}

/**
 * Notification configuration object
 *
 * Determines how a [task] or [group] of tasks needs to be notified
 *
 * [runningNotification] is the notification used while the task is in progress
 * [completeNotification] is the notification used when the task completed
 * [errorNotification] is the notification used when something went wrong,
 * including pause, failed and notFound status
 */
class NotificationConfig(
        val task: Task?,
        val group: String?,
        val runningNotification: Notification?,
        val completeNotification: Notification?,
        val errorNotification: Notification?,
        val pausedNotification: Notification?,
        val progressBar: Boolean
        ) {
    override fun toString(): String {
        return "NotificationConfig(task=$task, group=$group, runningNotification=$runningNotification, completeNotification=$completeNotification, errorNotification=$errorNotification, pausedNotification=$pausedNotification, progressBar=$progressBar)"
    }
}

enum class NotificationType {running, complete, error, paused}

