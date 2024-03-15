package com.bbflight.background_downloader

import android.content.Context
import androidx.work.WorkManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.net.MalformedURLException
import java.net.URL
import java.util.Date
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.PriorityBlockingQueue
import java.util.concurrent.atomic.AtomicInteger

/**
 * Queue that holds [EnqueueItem] items before they are actually enqueued as a WorkManager job
 *
 * Configure [maxConcurrent], [maxConcurrentByHost] and [maxConcurrentByGroup] to limit which items
 * can be enqueued simultaneously.
 * Call:
 * [add] to add an [EnqueueItem]
 * [taskFinished] for all tasks that finish
 * [cancelAllTasks] to empty the queue (no status updates)
 * [cancelTasksWithIds] to remove specific tasks (no status updates)
 * [allTasks] for a list of [Task] matching a group
 */
class HoldingQueue(private val workManager: WorkManager) {
    val unlimited = 1 shl 20
    private var job: Job? = null // timer job

    var maxConcurrent: Int = unlimited
    var maxConcurrentByHost: Int = unlimited
    var maxConcurrentByGroup: Int = unlimited

    private val concurrent = AtomicInteger(0)
    private val concurrentByHost = ConcurrentHashMap<String, AtomicInteger>()
    private val concurrentByGroup = ConcurrentHashMap<String, AtomicInteger>()

    private val hostByTaskId = ConcurrentHashMap<String, String>()

    private val queue = PriorityBlockingQueue<EnqueueItem>()
    private val enqueueQueue = Channel<EnqueueItem>(capacity = Channel.UNLIMITED)
    private val waitingToEnqueue = ArrayList<Task>()

    private val scope = CoroutineScope(Dispatchers.Default)
    private val processSignal = Channel<Unit>(Channel.UNLIMITED)
    private val stateMutex = Mutex()

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
                                val host = try {
                                    URL(item.task.url).host
                                } catch (e: MalformedURLException) {
                                    ""
                                }
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
                                    waitingToEnqueue.add(item.task)
                                    enqueueQueue.send(item)
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

        // coroutine to enqueue [EnqueueItem]
        // Synchronization is done via the [enqueueQueue], but we maintain a parallel
        // list [waitingToEnqueue] to allow operations like taskForId to include tasks
        // that are waiting to be enqueued, and to allow for cancellation/deletion of
        // tasks that are waiting
        scope.launch {
            for (item in enqueueQueue) {
                if (waitingToEnqueue.contains(item.task)) {
                    item.enqueue(afterDelayMillis = 100)
                    waitingToEnqueue.remove(item.task)
                }
            }
        }
    }

    /**
     * Add [EnqueueItem] [item] to the queue and advance the queue if possible
     */
    fun add(item: EnqueueItem) {
        queue.add(item)
        advanceQueue()
    }

    /**
     * Signals to the holdingQueue that a [task] has finished
     *
     * Adjusts the state variables and advances the queue
     */
    suspend fun taskFinished(task: Task) {
        val host = try {
            URL(task.url).host
        } catch (e: MalformedURLException) {
            ""
        }
        val group = task.group
        stateMutex.withLock {
            concurrent.decrementAndGet()
            concurrentByHost[host]?.decrementAndGet()
            concurrentByGroup[group]?.decrementAndGet()
        }
        advanceQueue()
    }

    /**
     * Removes all [EnqueueItem] where their taskId is in [taskIds], and returns a list of
     * taskIds that were removed this way
     */
    fun cancelTasksWithIds(taskIds: Iterable<String>): List<String> {
        val removedTaskIds: List<String>
        val toRemove = queue.filter { taskIds.contains(it.task.taskId) }
        toRemove.forEach { queue.remove(it) }
        removedTaskIds = toRemove.map { it.task.taskId }.toMutableList()
        val toRemoveFromWaiting = waitingToEnqueue.filter { taskIds.contains(it.taskId) }
        toRemoveFromWaiting.forEach { waitingToEnqueue.remove(it) }
        removedTaskIds.addAll(toRemoveFromWaiting.map { it.taskId })
        return removedTaskIds
    }

    /**
     * Cancel (delete) all [EnqueueItem] matching [group] and return the number of items deleted
     */
    fun cancelAllTasks(group: String): Int {
        val taskIds = queue.filter { it.task.group == group }.map { it.task.taskId }.toMutableList()
        taskIds.addAll(waitingToEnqueue.filter { it.group == group }.map { it.taskId })
        cancelTasksWithIds(taskIds)
        return taskIds.size
    }

    /**
     * Return task matching [taskId], or null
     */
    fun taskForId(taskId: String): Task? {
        val tasks = waitingToEnqueue.filter { it.taskId == taskId }.toMutableList()
        tasks.addAll(queue.filter { it.task.taskId == taskId }.map { it.task })
        if (tasks.isNotEmpty()) {
            return tasks.first()
        }
        return null
    }

    /**
     * Return list of [Task] for this [group]
     */
    suspend fun allTasks(group: String): List<Task> {
        stateMutex.withLock {
            val result = waitingToEnqueue.filter { it.group == group }.toMutableList()
            result.addAll(queue.filter { it.task.group == group }.map { it.task })
            return result
        }
    }

    /**
     * Advance the queue by signalling the queue processing coroutine
     *
     * Also restarts a timer that will advance the queue in 10 seconds, in case
     * it dries up
     */
    private fun advanceQueue() {
        processSignal.trySend(Unit)
        advanceQueueInFuture()
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
    private val context: Context,
    val task: Task,
    private val notificationConfigJsonString: String?,
    private val resumeData: ResumeData?,
    private val plugin: BDPlugin? = null,
    private val created: Date = Date()
) : Comparable<EnqueueItem> {

    /** Execute the re-enqueue after an appropriate delay */
    suspend fun enqueue(afterDelayMillis: Int = 1000) {
        val timeSinceCreatedMillis = Date().time - created.time
        if (timeSinceCreatedMillis < afterDelayMillis) {
            delay(afterDelayMillis - timeSinceCreatedMillis)
        }
        BDPlugin.doEnqueue(
            context = context,
            task = task,
            notificationConfigJsonString = notificationConfigJsonString,
            resumeData = resumeData,
            plugin = plugin
        )
        delay(20)
    }

    /**
     * Items are sorted based on task priority first, then by task creation time
     */
    override fun compareTo(other: EnqueueItem) = compareValuesBy(this, other,
        { it.task.priority },
        { it.task.creationTime })
}
