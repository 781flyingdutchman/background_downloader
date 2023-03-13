package com.bbflight.background_downloader

/**
 * Notification specification
 *
 * [iconAsset] is of form 'assets/my_icon.png'
 * [body] may contain special string {filename] to insert the filename
 *   and/or special string {progress} to insert progress in %
 *   and/or special trailing string {progressBar} to add a progress bar under
 *   the body text in the notification
 *
 * Actual appearance of notification is dependent on the platform, e.g.
 * on iOS {progress} and {progressBar} are not available and ignored
 */
class Notification (val iconAsset: String, val title: String, val body: String) {
    override fun toString(): String {
        return "Notification(iconAsset='$iconAsset', title='$title', body='$body')"
    }
}

/**
 * Notification configuration object
 *
 * Determines how a [task] or [group] of tasks needs to be notified
 *
 * [activeNotification] is the notification used while the task is in progress
 * [completeNotification] is the notification used when the task completed
 * [errorNotification] is the notification used when something went wrong,
 * including pause, failed and notFound status
 */
class NotificationConfig(
        val task: Task?,
        val group: String?,
        val activeNotification: Notification?,
        val completeNotification: Notification?,
        val errorNotification: Notification?
        ) {
    override fun toString(): String {
        return "NotificationConfig(task=$task, group=$group, activeNotification=$activeNotification, completeNotification=$completeNotification, errorNotification=$errorNotification)"
    }
}

