package com.bbflight.background_downloader

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.annotation.Keep
import androidx.core.app.NotificationManagerCompat
import androidx.work.WorkManager
import com.bbflight.background_downloader.BDPlugin.Companion.TAG
import kotlinx.coroutines.runBlocking
import kotlin.math.roundToInt

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
    val tapOpensFile: Boolean,
    val notificationGroup: String
) {
    override fun toString(): String {
        return "NotificationConfig(running=$running, complete=$complete, error=$error, " +
                "paused=$paused, progressBar=$progressBar, tapOpensFile=$tapOpensFile, " +
                "notificationGroup=$notificationGroup)"
    }
}

/**
 * Data associated with a notificationGroup
 */
class NotificationGroup(
    val name: String
) {
    private var notifications = HashMap<Task, NotificationType>()

    /** NotificationId derived from group name */
    val notificationId get() = "notificationGroup$name".hashCode()

    /** Total number of notifications in this group */
    val numTotal get() = notifications.size

    /** Progress expressed as [numFinished]/[numTotal], except
     * return 2.0 if numTotal is 0, to suggest that progress
     * is undetermined
     */
    val progress get() = if (numTotal == 0) 2.0 else numFinished.toDouble() / numTotal.toDouble()

    /** Number of "finished" notifications in this group.
     *
     * A "finished" notification is one that is not "running",
     * so includes complete, error, paused
     * */
    val numFinished get() = notifications.filter { (_, v) -> v != NotificationType.running }.size

    /** True if all notifications in this group are finished */
    val complete get() = numTotal == numFinished

    /** Returns a Set of running tasks in this notificationGroup */
    val runningTasks
        get() = notifications.filter { (_, notificationType) ->
            notificationType == NotificationType.running
        }.keys

    /** Int representing this group's state. If this number
     * does not change, the group state did not change.
     *
     * State is determined by the number of finished notifications
     * and the number of total notifications
     */
    private val groupState get() = 10000 * numTotal + numFinished

    /** Update a [task] and [notificationType] to this group,
     * and return True if this led to change in [groupState]
     */
    fun update(task: Task, notificationType: NotificationType): Boolean {
        val priorState = groupState
        notifications[task] = notificationType
        return priorState != groupState
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
        const val keyBundle = "com.bbflight.background_downloader.bundle"
        const val keyTaskId = "com.bbflight.background_downloader.taskId"
        const val keyTask = "com.bbflight.background_downloader.task" // as JSON string
        const val keyNotificationGroupName =
            "com.bbflight.background_downloader.notificationGroupName"
        const val keyNotificationConfig =
            "com.bbflight.background_downloader.notificationConfig" // as JSON string
        const val keyNotificationType =
            "com.bbflight.background_downloader.notificationType" // ordinal of enum
        const val keyNotificationId = "com.bbflight.background_downloader.notificationId"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val bundle = intent.getBundleExtra(keyBundle)
        val taskId = bundle?.getString(keyTaskId)
        if (taskId != null) {
            runBlocking {
                when (intent.action) {
                    actionCancelActive -> {
                        BDPlugin.cancelActiveTaskWithId(
                            context, taskId, WorkManager.getInstance(context)
                        )
                    }

                    actionCancelInactive -> {
                        val taskJsonString = bundle.getString(keyTask)
                        if (taskJsonString != null) {
                            val task = Task(
                                BDPlugin.gson.fromJson(
                                    taskJsonString, BDPlugin.jsonMapType
                                )
                            )
                            BDPlugin.cancelInactiveTask(context, task)
                            with(NotificationManagerCompat.from(context)) {
                                cancel(task.taskId.hashCode())
                            }
                        } else {
                            Log.d(TAG, "task was null")
                        }
                    }

                    actionPause -> {
                        BDPlugin.pauseTaskWithId(taskId)
                    }

                    actionResume -> {
                        val resumeData = BDPlugin.localResumeData[taskId]
                        if (resumeData != null) {
                            val notificationConfigJsonString = bundle.getString(
                                keyNotificationConfig
                            )
                            if (notificationConfigJsonString != null) {
                                BDPlugin.doEnqueue(
                                    context,
                                    resumeData.task,
                                    notificationConfigJsonString,
                                    resumeData
                                )
                            } else {
                                BDPlugin.cancelActiveTaskWithId(
                                    context, taskId, WorkManager.getInstance(context)
                                )
                            }
                        } else {
                            BDPlugin.cancelActiveTaskWithId(
                                context, taskId, WorkManager.getInstance(context)
                            )
                        }
                    }

                    else -> {}
                }
            }
        } else {
            // no taskId -> groupNotification, and can only be a cancel action so
            // no need to check
            val notificationGroupName = bundle?.getString(keyNotificationGroupName)
            if (notificationGroupName != null) {
                // cancel all tasks associated with this group that have not yet completed
                val notificationGroup = BDPlugin.notificationGroups[notificationGroupName]
                if (notificationGroup != null) {
                    runBlocking {
                        BDPlugin.cancelTasksWithIds(
                            context,
                            notificationGroup.runningTasks.map { task -> task.taskId })
                    }
                }
            }
        }
    }
}

/**
 * Returns the notificationType related to this [status]
 */
fun notificationTypeForTaskStatus(status: TaskStatus): NotificationType {
    return when (status) {
        TaskStatus.enqueued, TaskStatus.running -> NotificationType.running
        TaskStatus.complete -> NotificationType.complete
        TaskStatus.paused -> NotificationType.paused
        else -> NotificationType.error
    }
}

// RegExes for token replacement
private val displayNameRegEx = Regex("""\{displayName\}""", RegexOption.IGNORE_CASE)
private val fileNameRegEx = Regex("""\{filename\}""", RegexOption.IGNORE_CASE)
private val progressRegEx = Regex("""\{progress\}""", RegexOption.IGNORE_CASE)
private val networkSpeedRegEx = Regex("""\{networkSpeed\}""", RegexOption.IGNORE_CASE)
private val timeRemainingRegEx = Regex("""\{timeRemaining\}""", RegexOption.IGNORE_CASE)
private val metaDataRegEx = Regex("""\{metadata\}""", RegexOption.IGNORE_CASE)
private val numFinishedRegEx = Regex("""\{numFinished\}""", RegexOption.IGNORE_CASE)
private val numTotalRegEx = Regex("""\{numTotal\}""", RegexOption.IGNORE_CASE)


/**
 * Replace special tokens {displayName}, {filename}, {metadata}, {progress}, {networkSpeed},
 * {timeRemaining}, {numFinished} and {numTotal} with their respective values.
 */
fun replaceTokens(
    input: String,
    task: Task,
    progress: Double,
    networkSpeed: Double = -1.0,
    timeRemaining: Long? = null,
    notificationGroup: NotificationGroup? = null
): String {
    // filename and metadata
    val output = displayNameRegEx.replace(
        fileNameRegEx.replace(
            metaDataRegEx.replace(
                input,
                task.metaData
            ), task.filename
        ), task.displayName
    )

    // progress
    val progressString =
        if (progress in 0.0..1.0) (progress * 100).roundToInt().toString() + "%"
        else ""
    val output2 = progressRegEx.replace(output, progressString)
    // download speed
    val networkSpeedString =
        if (networkSpeed <= 0.0) "-- MB/s" else if (networkSpeed > 1) "${networkSpeed.roundToInt()} MB/s" else "${(networkSpeed * 1000).roundToInt()} kB/s"
    val output3 = networkSpeedRegEx.replace(output2, networkSpeedString)
    // time remaining
    var output4 = output3
    if (timeRemaining != null) {
        val hours = timeRemaining.div(3600000L)
        val minutes = (timeRemaining.mod(3600000L)).div(60000L)
        val seconds = (timeRemaining.mod(60000L)).div(1000L)
        val timeRemainingString = if (timeRemaining < 0) "--:--" else if (hours > 0)
            String.format(
                "%02d:%02d:%02d",
                hours,
                minutes,
                seconds
            ) else
            String.format(
                "%02d:%02d",
                minutes,
                seconds
            )
        output4 = timeRemainingRegEx.replace(output3, timeRemainingString)
    }
    return if (notificationGroup != null) {
        numFinishedRegEx.replace(
            numTotalRegEx.replace(output4, "${notificationGroup.numTotal}"),
            "${notificationGroup.numFinished}"
        )
    } else {
        output4
    }
}
