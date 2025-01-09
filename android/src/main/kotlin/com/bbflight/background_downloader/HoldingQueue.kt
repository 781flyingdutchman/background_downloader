package com.bbflight.background_downloader

import android.content.Context
import android.util.Log
import androidx.preference.PreferenceManager
import androidx.work.WorkManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.Date
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.PriorityBlockingQueue
import java.util.concurrent.atomic.AtomicInteger

/**
 * Queue that holds [EnqueueItem] items before they are actually enqueued as a WorkManager job
 *
 * Configure [maxConcurrent], [maxConcurrentByHost] and [maxConcurrentByGroup] to limit which items
 * can be enqueued simultaneously.
 *
 * Call:
 * [add] to add an [EnqueueItem]
 * [taskFinished] for all tasks that finish, so we may start a new one
 * [cancelAllTasks] to empty the queue (sends status updates)
 * [cancelTasksWithIds] to remove specific tasks (sends status updates)
 * [allTasks] for a list of [Task] matching a group
 * [taskForId] to get the task for a specific taskId
 */
class HoldingQueue(private val workManager: WorkManager) {

    var maxConcurrent: Int = 1 shl 20
    var maxConcurrentByHost: Int = 1 shl 20
    var maxConcurrentByGroup: Int = 1 shl 20
    val hostByTaskId = ConcurrentHashMap<String, String>()
    val enqueuedTaskIds = mutableListOf<String>()

    private val concurrent = AtomicInteger(0)
    private val concurrentByHost = ConcurrentHashMap<String, AtomicInteger>()
    private val concurrentByGroup = ConcurrentHashMap<String, AtomicInteger>()

    private val queue = PriorityBlockingQueue<EnqueueItem>()
    private val taskFinishedQueue = Channel<Task>(capacity = Channel.UNLIMITED)


    private var job: Job? = null // timer job
    private val scope = CoroutineScope(Dispatchers.Default)
    private val processSignal = Channel<Unit>(Channel.UNLIMITED)
    val stateMutex = Mutex()

    init {
        // coroutine to process the queue, one item per signal
        scope.launch {
            for (signal in processSignal) {  // signal comes from [advanceQueue]
                stateMutex.withLock {
                    if (concurrent.get() < maxConcurrent) {
                        // walk through queue to find item that can be enqueued
                        val mustWait = ArrayList<EnqueueItem>()
                        while (queue.isNotEmpty()) {
                            val item = queue.poll()
                            if (item != null) {
                                val host = item.task.host()
                                val group = item.task.group
                                if ((concurrentByHost[host]?.get()
                                        ?: 0) < maxConcurrentByHost && (concurrentByGroup[group]?.get()
                                        ?: 0) < maxConcurrentByGroup
                                ) {
                                    // enqueue this item after incrementing counters
                                    concurrent.incrementAndGet()
                                    if (!concurrentByHost.containsKey(host)) {
                                        concurrentByHost[host] = AtomicInteger(0)
                                    }
                                    concurrentByHost[host]?.incrementAndGet()
                                    if (!concurrentByGroup.containsKey(group)) {
                                        concurrentByGroup[group] = AtomicInteger(0)
                                    }
                                    concurrentByGroup[group]?.incrementAndGet()
                                    item.enqueue(afterDelayMillis = 0)
                                    break
                                } else {
                                    // this item has to wait
                                    mustWait.add(item)
                                }
                            }
                        }
                        // add mustWait items back to the queue
                        queue.addAll(mustWait)
                    }
                }
            }
        }

        // coroutine to process 'taskFinished' messages
        scope.launch {
            for (task in taskFinishedQueue) {
                executeTaskFinished(task)
            }
        }
    }

    /**
     * Add [EnqueueItem] [item] to the queue and advance the queue if possible
     */
    suspend fun add(item: EnqueueItem) {
        stateMutex.withLock {
            queue.add(item)
            enqueuedTaskIds.add(item.task.taskId)
            NotificationService.registerEnqueue(
                item,
                success = true
            ) // for group notification count
        }
        advanceQueue()
    }

    /**
     * Signals to the holdingQueue that a [task] has finished
     *
     * The processing is done async, so this method only adds
     * the task to the processing queue
     */
    suspend fun taskFinished(task: Task) {
        taskFinishedQueue.send(task)
    }

    /**
     * Removes all [EnqueueItem] where their taskId is in [taskIds], sends a
     * [TaskStatus.canceled] update and returns a list of
     * taskIds that were cancelled this way
     *
     * Because this is used in combination with the WorkManager tasks, use of this method
     * requires the caller to acquire the [stateMutex]
     */
    suspend fun cancelTasksWithIds(context: Context, taskIds: Iterable<String>): List<String> {
        val removedTaskIds: List<String>
        val toRemove = queue.filter { taskIds.contains(it.task.taskId) }
        val prefs = PreferenceManager.getDefaultSharedPreferences(context)
        toRemove.forEach {
            queue.remove(it)
            TaskWorker.processStatusUpdate(it.task, TaskStatus.canceled, prefs, context = context)
            Log.i(BDPlugin.TAG, "Canceled task with id ${it.task.taskId}")
        }
        removedTaskIds = toRemove.map { it.task.taskId }.toMutableList()
        return removedTaskIds
    }

    /**
     * Cancel (delete) all [EnqueueItem] matching [group], send a
     * [TaskStatus.canceled] for each and return the number of items cancelled
     *
     * Because this is used in combination with the WorkManager tasks, use of this method
     * requires the caller to acquire the [stateMutex]
     */
    suspend fun cancelAllTasks(context: Context, group: String): Int {
        val taskIds =
            queue.filter { it.task.group == group }.map { it.task.taskId }.toMutableList()
        cancelTasksWithIds(context, taskIds)
        return taskIds.size
    }

    /**
     * Return task matching [taskId], or null
     *
     * Because this is used in combination with the WorkManager tasks, use of this method
     * requires the caller to acquire the [stateMutex]
     */
    fun taskForId(taskId: String): Task? {
        val tasks = queue.filter { it.task.taskId == taskId }.map { it.task }
        if (tasks.isNotEmpty()) {
            return tasks.first()
        }
        return null
    }

    /**
     * Return list of [Task] for this [group]. If [group] is null, all tasks will be returned
     *
     * Because this is used in combination with the WorkManager tasks, use of this method
     * requires the caller to acquire the [stateMutex]
     */
    fun allTasks(group: String?): List<Task> {
        return queue.filter { group == null || it.task.group == group }.map { it.task }
    }

    /**
     * Advance the queue by signalling the queue processing coroutine
     *
     * Also restarts a timer that will advance the queue in 10 seconds, in case
     * it dries up
     */
    private fun advanceQueue() {
        processSignal.trySend(Unit)
        if (queue.isNotEmpty()) {
            advanceQueueInFuture()
        }
    }

    /**
     * Calls [advanceQueue] in 10 seconds, thus ensuring it never dries up
     *
     * If called again before the timer fires, cancels the original timer and
     * resets to 10 seconds
     */
    private fun advanceQueueInFuture() {
        job?.cancel()
        job = scope.launch {
            delay(10000)
            calculateState()
            advanceQueue()
        }
    }

    /**
     * Signals to the holdingQueue that a [task] has finished
     *
     * Adjusts the state variables and advances the queue
     */
    private suspend fun executeTaskFinished(task: Task) {
        hostByTaskId.remove(task.taskId)
        enqueuedTaskIds.remove(task.taskId)
        val host = task.host()
        val group = task.group
        stateMutex.withLock {
            concurrent.decrementAndGet()
            concurrentByHost[host]?.decrementAndGet()
            concurrentByGroup[group]?.decrementAndGet()
        }
        advanceQueue()
    }

    /**
     * Calculates the [concurrent], [concurrentByHost] and [concurrentByGroup] values
     *
     * This is expensive, so is only done initially and when the [advanceQueueInFuture] timer
     * fires
     */
    private suspend fun calculateState() {
        stateMutex.withLock {
            val workInfos = workManager.getWorkInfosByTag(BDPlugin.TAG).get()
                .filter { !it.state.isFinished }
            concurrent.set(workInfos.size)
            concurrentByHost.clear()
            concurrentByGroup.clear()
            for (workInfo in workInfos) {
                // update concurrentByHost
                try {
                    val taskIdTag = workInfo.tags.first { it.startsWith("taskId=") }
                    val taskId = taskIdTag.substring(startIndex = 7)
                    val host = hostByTaskId[taskId] ?: ""
                    if (!concurrentByHost.containsKey(host)) {
                        concurrentByHost[host] = AtomicInteger(0)
                    }
                    concurrentByHost[host]?.incrementAndGet()
                } catch (_: NoSuchElementException) {
                }
                // update concurrentByGroup
                try {
                    val groupTag = workInfo.tags.first { it.startsWith("group=") }
                    val group = groupTag.substring(startIndex = 6)
                    if (!concurrentByGroup.containsKey(group)) {
                        concurrentByGroup[group] = AtomicInteger(0)
                    }
                    concurrentByGroup[group]?.incrementAndGet()
                } catch (_: NoSuchElementException) {
                }
            }
        }
    }
}


/**
 * Holds data related to enqueueing a task
 *
 * Used in the context of changing the RequireWiFi setting (where tasks need to be re-enqueued)
 * and in the context of the [HoldingQueue]
 */
class EnqueueItem(
    val context: Context,
    val task: Task,
    val notificationConfigJsonString: String?,
    private val resumeData: ResumeData? = null,
    private val plugin: BDPlugin? = null,
    private val created: Date = Date()
) : Comparable<EnqueueItem> {

    /** Execute the re-enqueue after an appropriate delay */
    suspend fun enqueue(afterDelayMillis: Int = 1000) {
        val timeSinceCreatedMillis = Date().time - created.time
        if (timeSinceCreatedMillis < afterDelayMillis) {
            delay(afterDelayMillis - timeSinceCreatedMillis)
        }
        if (!BDPlugin.doEnqueue(
                context = context,
                task = task,
                notificationConfigJsonString = notificationConfigJsonString,
                resumeData = resumeData,
                plugin = plugin
            )
        ) {
            Log.w(BDPlugin.TAG, "Delayed or retried enqueue failed for taskId ${task.taskId}")
            TaskWorker.processStatusUpdate(
                task, TaskStatus.failed, PreferenceManager.getDefaultSharedPreferences(context),
                taskException = TaskException(
                    type = ExceptionType.general,
                    description = "Delayed or retried enqueue failed"
                ), context = context
            )
            BDPlugin.holdingQueue?.taskFinished(task)
            NotificationService.registerEnqueue(this, success = false)
        }
        delay(20)
    }

    /**
     * Items are sorted based on task priority first, then by task creation time
     */
    override fun compareTo(other: EnqueueItem) = compareValuesBy(this, other,
        { it.task.priority },
        { it.task.creationTime })
}
