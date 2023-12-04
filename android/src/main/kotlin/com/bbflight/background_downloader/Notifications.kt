package com.bbflight.background_downloader

import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.util.Log
import androidx.annotation.Keep
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationCompat.Builder
import androidx.core.app.NotificationManagerCompat
import androidx.work.Data
import androidx.work.ForegroundInfo
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import com.bbflight.background_downloader.BDPlugin.Companion.TAG
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.util.LinkedList
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
@Serializable
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
@Serializable
class NotificationConfig(
    val running: TaskNotification?,
    val complete: TaskNotification?,
    val error: TaskNotification?,
    val paused: TaskNotification?,
    val progressBar: Boolean,
    val tapOpensFile: Boolean,
    val groupNotificationId: String
) {
    override fun toString(): String {
        return "NotificationConfig(running=$running, complete=$complete, error=$error, paused=$paused, progressBar=$progressBar, tapOpensFile=$tapOpensFile, groupNotificationId=$groupNotificationId)"
    }
}

/**
 * Data associated with a groupNotification
 */
class GroupNotification(
    val name: String,
    val notificationConfig: NotificationConfig
) {
    private var notifications = HashMap<Task, NotificationType>()

    /** NotificationId derived from group name */
    val notificationId get() = "groupNotification$name".hashCode()

    /** Total number of notifications in this group */
    val numTotal get() = notifications.size

    /** Progress expressed as [numFinished]/[numTotal], except
     * return 2.0 if numTotal is 0, to suggest that progress
     * is undetermined
     */
    val progress get() = if (numTotal == 0) 2.0 else numFinished.toDouble() / numTotal.toDouble()

    /** Number of "finished" notifications in this group.
     *
     * A "finished" notification is one that is not .running,
     * so includes .complete, .error, .paused
     * */
    val numFinished get() = notifications.filter { (_, v) -> v != NotificationType.running }.size

    /** Number of "failed" notifications in this group.
     *
     * A "failed" notification is one of type .error
     * */
    val numFailed get() = notifications.filter { (_, v) -> v == NotificationType.error }.size

    /** True if all tasks finished, regardless of outcome */
    val isFinished get() = numFinished == numTotal

    /**
     * Return true if this group has an error
     */
    val hasError get() = numFailed > 0

    /** Returns a Set of running tasks in this groupNotification */
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
    private val groupState get() = 1000 * numTotal + numFinished

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
        const val keyGroupNotificationName =
            "com.bbflight.background_downloader.groupNotificationName"
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
                            val task = Json.decodeFromString<Task>(taskJsonString)
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
            val groupNotificationName = bundle?.getString(keyGroupNotificationName)
            if (groupNotificationName != null) {
                // cancel all tasks associated with this group that have not yet completed
                val groupNotification =
                    NotificationService.groupNotifications[groupNotificationName]
                if (groupNotification != null) {
                    runBlocking {
                        BDPlugin.cancelTasksWithIds(context,
                            groupNotification.runningTasks.map { task -> task.taskId })
                    }
                }
            }
        }
    }
}

/**
 * Singleton service to manage notifications
 */
object NotificationService {
    var groupNotifications = HashMap<String, GroupNotification>()

    private const val notificationChannelId = "background_downloader"

    private var queue = LinkedList<NotificationData>()
    private var lastNotificationTime: Long = 0
    private var createdNotificationChannel = false

    /**
     * Creates an [UpdateNotificationWorker] to update the notification associated with
     * this task
     *
     * This is used when we do not have access to the [TaskWorker] object, i.e.
     * when called from outside an actively running worker.
     */
    fun createUpdateNotificationWorker(
        context: Context,
        taskJson: String,
        notificationConfigJson: String?,
        taskStatusOrdinal: Int?
    ) {
        // create dummy TaskWorker
        val requestBuilder = OneTimeWorkRequestBuilder<UpdateNotificationWorker>()
        val dataBuilder =
            Data.Builder().putString(TaskWorker.keyTask, taskJson)
                .putString(TaskWorker.keyNotificationConfig, notificationConfigJson)
        if (taskStatusOrdinal != null) {
            dataBuilder.putInt(UpdateNotificationWorker.keyTaskStatusOrdinal, taskStatusOrdinal)
        }
        requestBuilder.setInputData(dataBuilder.build())
        val workManager = WorkManager.getInstance(context)
        workManager.enqueue(requestBuilder.build())
    }

    /**
     * Create or update the notification for this [taskWorker], associated with this [taskStatus]
     * [progress] and [timeRemaining]
     *
     * [taskStatus] determines the type of notification, and whether absence of one will
     * cancel the notification
     * The [progress] field is only relevant for [NotificationType.running]. If progress is
     * negative no progress bar will be shown. If progress > 1 an indeterminate progress bar
     * will be shown
     * [timeRemaining] is only relevant for [NotificationType.running]
     *
     * If this notification is part of a group, then the notification will be built
     * using [updateGroupNotification] and enqueued to avoid overloading the
     * notification system.
     *
     * For normal notification, the caller must throttle the notifications to a
     * reasonable rate
     */
    @SuppressLint("MissingPermission")
    suspend fun updateNotification(
        taskWorker: TaskWorker,
        taskStatus: TaskStatus,
        progress: Double = 2.0,
        timeRemaining: Long = -1000
    ) {
        val notificationType = notificationTypeForTaskStatus(taskStatus)
        val groupNotificationId = taskWorker.notificationConfig?.groupNotificationId
        if (groupNotificationId?.isNotEmpty() == true) {
            updateGroupNotification(taskWorker, groupNotificationId, notificationType)
            return
        }
        // regular notification
        val notification = when (notificationType) {
            NotificationType.running -> taskWorker.notificationConfig?.running
            NotificationType.complete -> taskWorker.notificationConfig?.complete
            NotificationType.error -> taskWorker.notificationConfig?.error
            NotificationType.paused -> taskWorker.notificationConfig?.paused
        }
        if (notification == null) {
            addToNotificationQueue(taskWorker) // removes notification
            return
        }
        // need to show a notification
        taskWorker.notificationId = taskWorker.task.taskId.hashCode()
        if (!createdNotificationChannel) {
            createNotificationChannel(taskWorker.applicationContext)
        }
        val iconDrawable = when (notificationType) {
            NotificationType.running -> if (taskWorker.task.isDownloadTask()) R.drawable.outline_file_download_24 else R.drawable.outline_file_upload_24
            NotificationType.complete -> R.drawable.outline_download_done_24
            NotificationType.error -> R.drawable.outline_error_outline_24
            NotificationType.paused -> R.drawable.outline_pause_24
        }
        val builder = Builder(
            taskWorker.applicationContext, notificationChannelId
        ).setPriority(NotificationCompat.PRIORITY_LOW).setSmallIcon(iconDrawable)
        // use stored progress if notificationType is .paused
        taskWorker.notificationProgress =
            if (notificationType == NotificationType.paused) taskWorker.notificationProgress else progress
        // title and body interpolation of {filename}, {progress} and {metadata}
        val title = replaceTokens(
            notification.title,
            taskWorker.task,
            taskWorker.notificationProgress,
            networkSpeed = taskWorker.networkSpeed,
            timeRemaining = timeRemaining
        )
        if (title.isNotEmpty()) {
            builder.setContentTitle(title)
        }
        val body = replaceTokens(
            notification.body,
            taskWorker.task,
            taskWorker.notificationProgress,
            networkSpeed = taskWorker.networkSpeed,
            timeRemaining = timeRemaining
        )
        if (body.isNotEmpty()) {
            builder.setContentText(body)
        }
        // progress bar
        val progressBar =
            taskWorker.notificationConfig?.progressBar ?: false && (notificationType == NotificationType.running || notificationType == NotificationType.paused)
        if (progressBar && taskWorker.notificationProgress >= 0) {
            if (taskWorker.notificationProgress <= 1) {
                builder.setProgress(
                    100, (taskWorker.notificationProgress * 100).roundToInt(), false
                )
            } else { // > 1 means indeterminate
                builder.setProgress(100, 0, true)
            }
        }
        addNotificationActions(taskWorker, notificationType, builder)
        addToNotificationQueue(taskWorker, notificationType, builder)
    }

    /**
     * Update notification for this [taskWorker] in group
     * [groupNotificationId] and type [notificationType].
     *
     * A group notification aggregates the state of all tasks in a group and
     * presents a notification based on that value
     */
    private suspend fun updateGroupNotification(
        taskWorker: TaskWorker, groupNotificationId: String, notificationType: NotificationType
    ) {
        val groupNotification =
            groupNotifications[groupNotificationId] ?: GroupNotification(
                groupNotificationId, taskWorker.notificationConfig!!
            )
        val stateChange = groupNotification.update(taskWorker.task, notificationType)
        groupNotifications[groupNotificationId] = groupNotification
        if (stateChange) {
            // need to update the group notification
            taskWorker.notificationId = groupNotification.notificationId
            val hasError = groupNotification.hasError
            val isFinished = groupNotification.isFinished
            val notification = if (isFinished) {
                if (hasError) groupNotification.notificationConfig.error else groupNotification.notificationConfig.complete
            } else groupNotification.notificationConfig.running
            if (notification == null) {
                addToNotificationQueue(taskWorker) // removes notification
            } else {
                // need to show a notification
                if (!createdNotificationChannel) {
                    createNotificationChannel(taskWorker.applicationContext)
                }
                val iconDrawable = if (isFinished) {
                    if (hasError) R.drawable.outline_error_outline_24 else R.drawable.outline_download_done_24
                } else {
                    if (taskWorker.task.isDownloadTask()) R.drawable.outline_file_download_24 else R.drawable.outline_file_upload_24
                }
                val builder = Builder(
                    taskWorker.applicationContext, notificationChannelId
                ).setPriority(NotificationCompat.PRIORITY_LOW).setSmallIcon(iconDrawable)
                // title and body interpolation of tokens
                val progress = groupNotification.progress
                val title = replaceTokens(
                    notification.title,
                    taskWorker.task,
                    progress,
                    groupNotification = groupNotification
                )
                if (title.isNotEmpty()) {
                    builder.setContentTitle(title)
                }
                val body = replaceTokens(
                    notification.body,
                    taskWorker.task,
                    progress,
                    groupNotification = groupNotification
                )
                if (body.isNotEmpty()) {
                    builder.setContentText(body)
                }
                // progress bar
                val progressBar =
                    groupNotification.notificationConfig.progressBar && (notification == groupNotification.notificationConfig.running)
                if (progressBar && progress >= 0) {
                    if (progress <= 1) {
                        builder.setProgress(100, (progress * 100).roundToInt(), false)
                    } else { // > 1 means indeterminate
                        builder.setProgress(100, 0, true)
                    }
                }
                if (!isFinished) {
                    addCancelActionToGroupNotification(taskWorker, groupNotification, builder)
                }
                addToNotificationQueue(taskWorker, notificationType, builder) // shows notification
            }
            if (isFinished) {
                // remove only if not re-activated within 5 seconds
                withContext(Dispatchers.Default) {
                    launch {
                        delay(5000)
                        if (groupNotification.isFinished) {
                            groupNotifications.remove(groupNotificationId)
                        }
                    }
                }
            }
        }
    }

    /**
     * Add action to notification via buttons or tap
     *
     * Which button(s) depends on the [notificationType], and the actions require
     * access to [taskWorker] and the [builder]
     */
    private fun addNotificationActions(
        taskWorker: TaskWorker, notificationType: NotificationType, builder: Builder
    ) {
        val activity = BDPlugin.activity
        if (activity != null) {
            val taskJsonString = Json.encodeToString(taskWorker.task)
            // add tap action for all notifications
            val tapIntent = taskWorker.applicationContext.packageManager.getLaunchIntentForPackage(
                taskWorker.applicationContext.packageName
            )
            if (tapIntent != null) {
                tapIntent.apply {
                    action = NotificationRcvr.actionTap
                    putExtra(NotificationRcvr.keyTask, taskJsonString)
                    putExtra(NotificationRcvr.keyNotificationType, notificationType.ordinal)
                    putExtra(
                        NotificationRcvr.keyNotificationConfig,
                        taskWorker.notificationConfigJsonString
                    )
                    putExtra(NotificationRcvr.keyNotificationId, taskWorker.notificationId)
                }
                val tapPendingIntent: PendingIntent = PendingIntent.getActivity(
                    taskWorker.applicationContext,
                    taskWorker.notificationId,
                    tapIntent,
                    PendingIntent.FLAG_CANCEL_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
                builder.setContentIntent(tapPendingIntent)
            }
            // add buttons depending on notificationType
            when (notificationType) {
                NotificationType.running -> {
                    // cancel button when running
                    val cancelOrPauseBundle = Bundle().apply {
                        putString(NotificationRcvr.keyTaskId, taskWorker.task.taskId)
                    }
                    val cancelIntent =
                        Intent(taskWorker.applicationContext, NotificationRcvr::class.java).apply {
                            action = NotificationRcvr.actionCancelActive
                            putExtra(NotificationRcvr.keyBundle, cancelOrPauseBundle)
                        }
                    val cancelPendingIntent: PendingIntent = PendingIntent.getBroadcast(
                        taskWorker.applicationContext,
                        taskWorker.notificationId,
                        cancelIntent,
                        PendingIntent.FLAG_IMMUTABLE
                    )
                    builder.addAction(
                        R.drawable.outline_cancel_24,
                        activity.getString(R.string.bg_downloader_cancel),
                        cancelPendingIntent
                    )
                    if (taskWorker.taskCanResume && (taskWorker.notificationConfig?.paused != null)) {
                        // pause button when running and paused notification configured
                        val pauseIntent = Intent(
                            taskWorker.applicationContext, NotificationRcvr::class.java
                        ).apply {
                            action = NotificationRcvr.actionPause
                            putExtra(NotificationRcvr.keyBundle, cancelOrPauseBundle)
                        }
                        val pausePendingIntent: PendingIntent = PendingIntent.getBroadcast(
                            taskWorker.applicationContext,
                            taskWorker.notificationId,
                            pauseIntent,
                            PendingIntent.FLAG_IMMUTABLE
                        )
                        builder.addAction(
                            R.drawable.outline_pause_24,
                            activity.getString(R.string.bg_downloader_pause),
                            pausePendingIntent
                        )
                    }
                }

                NotificationType.paused -> {
                    // cancel button
                    val cancelBundle = Bundle().apply {
                        putString(NotificationRcvr.keyTaskId, taskWorker.task.taskId)
                        putString(
                            NotificationRcvr.keyTask, taskJsonString
                        )
                    }
                    val cancelIntent = Intent(
                        taskWorker.applicationContext, NotificationRcvr::class.java
                    ).apply {
                        action = NotificationRcvr.actionCancelInactive
                        putExtra(NotificationRcvr.keyBundle, cancelBundle)
                    }
                    val cancelPendingIntent: PendingIntent = PendingIntent.getBroadcast(
                        taskWorker.applicationContext,
                        taskWorker.notificationId,
                        cancelIntent,
                        PendingIntent.FLAG_IMMUTABLE
                    )
                    builder.addAction(
                        R.drawable.outline_cancel_24,
                        activity.getString(R.string.bg_downloader_cancel),
                        cancelPendingIntent
                    )
                    // resume button
                    val resumeBundle = Bundle().apply {
                        putString(NotificationRcvr.keyTaskId, taskWorker.task.taskId)
                        putString(
                            NotificationRcvr.keyTask, taskJsonString
                        )
                        putString(
                            NotificationRcvr.keyNotificationConfig,
                            taskWorker.notificationConfigJsonString
                        )
                    }
                    val resumeIntent = Intent(
                        taskWorker.applicationContext, NotificationRcvr::class.java
                    ).apply {
                        action = NotificationRcvr.actionResume
                        putExtra(NotificationRcvr.keyBundle, resumeBundle)
                    }
                    val resumePendingIntent: PendingIntent = PendingIntent.getBroadcast(
                        taskWorker.applicationContext,
                        taskWorker.notificationId,
                        resumeIntent,
                        PendingIntent.FLAG_IMMUTABLE
                    )
                    builder.addAction(
                        R.drawable.outline_play_arrow_24,
                        activity.getString(R.string.bg_downloader_resume),
                        resumePendingIntent
                    )
                }

                NotificationType.complete -> {}
                NotificationType.error -> {}
            }
        }
    }

    /**
     * Add Cancel action to groupNotification notification
     */
    private fun addCancelActionToGroupNotification(
        taskWorker: TaskWorker,
        groupNotification: GroupNotification,
        builder: Builder
    ) {
        val activity = BDPlugin.activity
        if (activity != null) {
            // add cancel button for running notification
            val cancelBundle = Bundle().apply {
                putString(NotificationRcvr.keyGroupNotificationName, groupNotification.name)
            }
            val cancelIntent =
                Intent(taskWorker.applicationContext, NotificationRcvr::class.java).apply {
                    action = NotificationRcvr.actionCancelActive
                    putExtra(NotificationRcvr.keyBundle, cancelBundle)
                }
            val cancelPendingIntent: PendingIntent = PendingIntent.getBroadcast(
                taskWorker.applicationContext,
                groupNotification.notificationId,
                cancelIntent,
                PendingIntent.FLAG_IMMUTABLE
            )
            builder.addAction(
                R.drawable.outline_cancel_24,
                activity.getString(R.string.bg_downloader_cancel),
                cancelPendingIntent
            )
        }
    }

    /**
     * Display the notification presented by the [builder], for this
     * [notificationType]
     *
     * Checks for permissions, and if necessary asks for it
     */
    @SuppressLint("MissingPermission")
    private suspend fun displayNotification(
        taskWorker: TaskWorker, notificationType: NotificationType, builder: Builder
    ) {
        with(NotificationManagerCompat.from(taskWorker.applicationContext)) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                // On Android 33+, check/ask for permission
                val status = PermissionsService.getPermissionStatus(
                    taskWorker.applicationContext,
                    PermissionType.notifications
                )
                if (status != PermissionStatus.granted) {
                    return
                }
            }
            val androidNotification = builder.build()
            if (taskWorker.runInForeground) {
                if (notificationType == NotificationType.running) {
                    taskWorker.setForeground(
                        ForegroundInfo(
                            taskWorker.notificationId, androidNotification
                        )
                    )
                } else {
                    // to prevent the 'not running' notification getting killed as the foreground
                    // process is terminated, this notification is shown regularly, but with
                    // a delay
                    CoroutineScope(Dispatchers.Main).launch {
                        delay(200)
                        notify(taskWorker.notificationId, androidNotification)
                    }
                }
            } else {
                val now = System.currentTimeMillis()
                val timeSinceLastUpdate = now - taskWorker.lastNotificationTime
                taskWorker.lastNotificationTime = now
                if (notificationType == NotificationType.running || timeSinceLastUpdate > 2000) {
                    notify(taskWorker.notificationId, androidNotification)
                } else {
                    // to prevent the 'not running' notification getting ignored
                    // due to too frequent updates, post it with a delay
                    CoroutineScope(Dispatchers.Main).launch {
                        delay(2000 - java.lang.Long.max(timeSinceLastUpdate, 1000L))
                        notify(taskWorker.notificationId, androidNotification)
                    }
                }
            }
        }
    }


    /**
     * Create the notification channel to use for download notifications
     */
    private fun createNotificationChannel(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val name = context.getString(R.string.bg_downloader_notification_channel_name)
            val descriptionText = context.getString(
                R.string.bg_downloader_notification_channel_description
            )
            val importance = NotificationManager.IMPORTANCE_LOW
            val channel = NotificationChannel(
                notificationChannelId, name, importance
            ).apply {
                description = descriptionText
            }
            // Register the channel with the system
            val notificationManager: NotificationManager = context.getSystemService(
                Context.NOTIFICATION_SERVICE
            ) as NotificationManager
            notificationManager.createNotificationChannel(channel)
        }
        createdNotificationChannel = true
    }

    /**
     * Returns the notificationType related to this [status]
     */
    private fun notificationTypeForTaskStatus(status: TaskStatus): NotificationType {
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
    private val numFailedRegEx = Regex("""\{numFailed\}""", RegexOption.IGNORE_CASE)
    private val numTotalRegEx = Regex("""\{numTotal\}""", RegexOption.IGNORE_CASE)


    /**
     * Replace special tokens {displayName}, {filename}, {metadata}, {progress}, {networkSpeed},
     * {timeRemaining}, {numFinished} and {numTotal} with their respective values.
     */
    private fun replaceTokens(
        input: String,
        task: Task,
        progress: Double,
        networkSpeed: Double = -1.0,
        timeRemaining: Long? = null,
        groupNotification: GroupNotification? = null
    ): String {
        // filename and metadata
        val output = displayNameRegEx.replace(
            fileNameRegEx.replace(
                metaDataRegEx.replace(
                    input, task.metaData
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
            val timeRemainingString =
                if (timeRemaining < 0) "--:--" else if (hours > 0) String.format(
                    "%02d:%02d:%02d", hours, minutes, seconds
                ) else String.format(
                    "%02d:%02d", minutes, seconds
                )
            output4 = timeRemainingRegEx.replace(output3, timeRemainingString)
        }
        return if (groupNotification != null) {
            numFailedRegEx.replace(
                numFinishedRegEx.replace(
                    numTotalRegEx.replace(output4, "${groupNotification.numTotal}"),
                    "${groupNotification.numFinished}"
                ), "${groupNotification.numFailed}"
            )
        } else {
            output4
        }
    }

    /** Add display notification request to the queue, and start the
     * queue if needed
     */
    private suspend fun addToNotificationQueue(
        taskWorker: TaskWorker, notificationType: NotificationType? = null, builder: Builder? = null
    ) {
        queue.add(NotificationData(taskWorker, notificationType, builder))
        if (queue.size == 1) {
            startQueue()
        }
    }

    /**
     * Start the queue to process group notifications, until the queue is empty
     *
     * Should only be called if queue length == 1
     */
    private suspend fun startQueue() {
        withContext(Dispatchers.Default) {
            launch {
                var queueIsEmpty = false
                while (!queueIsEmpty) {
                    val now = System.currentTimeMillis()
                    val elapsed = now - lastNotificationTime
                    if (elapsed < 200) {
                        delay(200 - elapsed)
                    }
                    val notificationData = queue.remove()
                    queueIsEmpty = queue.isEmpty()
                    if (notificationData.notificationType != null && notificationData.builder != null) {
                        displayNotification(
                            notificationData.taskWorker,
                            notificationData.notificationType,
                            notificationData.builder
                        )
                    } else {
                        // remove the notification
                        with(NotificationManagerCompat.from(notificationData.taskWorker.applicationContext)) {
                            cancel(notificationData.taskWorker.notificationId)
                        }
                    }
                    lastNotificationTime = System.currentTimeMillis()
                }
            }
        }
    }

    /**
     * Return the [GroupNotification] this [taskId] belongs to, or
     * null if not part of a [GroupNotification]
     */
    fun groupNotificationWithTaskId(taskId: String): GroupNotification? {
        for (group in groupNotifications.values) {
            if (group.runningTasks.any { task -> task.taskId == taskId }) {
                return group
            }
        }
        return null
    }
}

/** Holds data required to construct a notification */
data class NotificationData(
    val taskWorker: TaskWorker,
    val notificationType: NotificationType?,
    val builder: Builder?
)
