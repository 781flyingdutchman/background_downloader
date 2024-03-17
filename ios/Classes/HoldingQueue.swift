//
//  HoldingQueue.swift
//  background_downloader
//
//  Created by Bram on 3/16/24.
//

import Foundation
import os.log

/**
 * Queue that holds [EnqueueItem] items before they are actually enqueued as a URLSessionTask
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
class HoldingQueue {
    var maxConcurrent: Int = 1000000
    var maxConcurrentByHost: Int = 1000000
    var maxConcurrentByGroup: Int = 1000000
    var enqueuedTaskIds = [String]()
    
    private var concurrent = 0
    private var concurrentByHost = [String: Int]()
    private var concurrentByGroup = [String: Int]()
    
    private var queue = [EnqueueItem]()  // Using an array as a substitute for a priority queue
    
    private let stateLock = NSLock()
    private var job: DispatchWorkItem? = nil // for advanceQueue in future
    
    /**
     * Add [EnqueueItem] [item] to the queue and advance the queue if possible
     */
    func add(item: EnqueueItem) {
        stateLock.lock()
        defer { stateLock.unlock() }
        queue.append(item)
        queue.sort()
        enqueuedTaskIds.append(item.task.taskId)
        advanceQueue()
    }
    
    /**
     * Signals to the holdingQueue that a [task] has finished
     *
     * Adjusts the state variables and advances the queue
     */
    func taskFinished(_ task: Task) {
        stateLock.lock()
        defer { stateLock.unlock() }
        let host = getHost(task)
        concurrent -= 1
        concurrentByHost[host]? -= 1
        concurrentByGroup[task.group]? -= 1
        if let index = enqueuedTaskIds.firstIndex(of: task.taskId) {
            enqueuedTaskIds.remove(at: index)
        }
        advanceQueue()
    }
    
    /**
     * Removes all [EnqueueItem] where their taskId is in [taskIds], sends a
     * [TaskStatus.canceled] update and returns a list of
     * taskIds that were cancelled this way
     */
    func cancelTasksWithIds(_ taskIds: [String]) -> [String] {
        stateLock.lock()
        defer { stateLock.unlock() }
        let toRemove = queue.filter( { taskIds.contains($0.task.taskId) } )
        toRemove.forEach { item in
            processStatusUpdate(task: item.task, status: .canceled)
            os_log("Canceled task with id %@", log: log, type: .info, item.task.taskId)
        }
        queue.removeAll(where: { taskIds.contains($0.task.taskId)})
        return toRemove.map { $0.task.taskId }
    }
    
    /**
     * Cancel (delete) all [EnqueueItem] matching [group], send a
     * [TaskStatus.canceled] for each and return the number of items cancelled
     */
    func cancelAllTasks(group: String) -> Int {
        stateLock.lock()
        let taskIds = queue.filter({ $0.task.group == group }).map { $0.task.taskId }
        stateLock.unlock()
        return cancelTasksWithIds(taskIds).count
    }
    
    /**
     * Return task matching [taskId], or null
     */
    func taskForId(_ taskId: String) -> Task? {
        stateLock.lock()
        defer { stateLock.unlock() }
        let tasks = queue.filter( { $0.task.taskId == taskId } ).map { $0.task }
        if !tasks.isEmpty {
            return tasks.first
        }
        return nil
    }
    
    /**
     * Return list of [Task] for this [group]
     */
    func allTasks(group: String) -> [Task] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return queue.filter( { $0.task.group == group } ).map { $0.task }
    }
    
    /**
     * Advance the queue by signalling the queue processing coroutine
     *
     * Also restarts a timer that will advance the queue in 10 seconds, in case
     * it dries up
     */
    private func advanceQueue() {
        DispatchQueue.global().async {
            _Concurrency.Task {
                await self.processQueue()
            }
        }
        advanceQueueInFuture()
    }
    
    private func advanceQueueInFuture() {
        job?.cancel()
        job = DispatchWorkItem {
            _Concurrency.Task {
                await self.calculateState()
                self.advanceQueue()
            }
        }
        guard let job = job else { return }
        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 10, execute: job)
        
    }
    
    /// Processes one item in the queue, if possible
    private func processQueue() async {
        stateLock.withLock {
            if concurrent < maxConcurrent {
                var mustWait = [EnqueueItem]()
                while !queue.isEmpty {
                    let item = queue.removeFirst()
                    let host = getHost(item.task)
                    if concurrentByHost[host] ?? 0 < maxConcurrentByHost &&
                        concurrentByGroup[item.task.group] ?? 0 < maxConcurrentByGroup {
                        concurrent += 1
                        concurrentByHost[host, default: 0] += 1
                        concurrentByGroup[item.task.group, default: 0] += 1
                        _Concurrency.Task {
                            await item.enqueue()
                        }
                        break
                    } else {
                        mustWait.append(item)
                    }
                }
                queue.append(contentsOf: mustWait)
                queue.sort()
            }
        }
    }
    
    /**
     * Calculates the [concurrent], [concurrentByHost] and [concurrentByGroup] values
     *
     * This is expensive, so is only done initially and when the [advanceQueueInFuture] timer
     * fires
     */
    private func calculateState() async {
        return stateLock.withLock {
            _Concurrency.Task {
                UrlSessionDelegate.createUrlSession()
                guard let urlSessionTasks = await UrlSessionDelegate.urlSession?.allTasks else {
                    return
                }
                let tasks: [Task] = urlSessionTasks.filter({ $0.state != .completed }).map({ getTaskFrom(urlSessionTask: $0)}).filter({ $0 != nil}).map({ $0!})
                concurrent = tasks.count
                concurrentByHost.removeAll()
                concurrentByGroup.removeAll()
                for task in tasks {
                    let host = getHost(task)
                    concurrentByHost[host, default: 0] += 1
                    concurrentByGroup[task.group, default: 0] += 1
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
struct EnqueueItem : Comparable {
    let task: Task
    let notificationConfigJsonString: String?
    let resumeDataAsBase64String: String
    let created = Date()
    
    // Comparable implementation to sort based on task priority and creation time
    static func < (lhs: EnqueueItem, rhs: EnqueueItem) -> Bool {
        return lhs.task.priority == rhs.task.priority ? lhs.task.creationTime < rhs.task.creationTime : lhs.task.priority < rhs.task.priority
    }
    
    static func == (lhs: EnqueueItem, rhs: EnqueueItem) -> Bool {
        return lhs.task.priority == rhs.task.priority && lhs.task.creationTime == rhs.task.creationTime
    }
    
    func enqueue() async {
        let success = await BDPlugin.instance.doEnqueue(taskJsonString: jsonStringFor(task: task) ?? "", notificationConfigJsonString: notificationConfigJsonString, resumeDataAsBase64String: resumeDataAsBase64String)
        if !success {
            os_log("Delayed or retried enqueue failed for taskId %@", log: log, type: .info, task.taskId)
            processStatusUpdate(task: task, status: .failed, taskException: TaskException(type: .general, description: "Delayed or retried enqueue failed"))
            BDPlugin.holdingQueue?.taskFinished(task)
        }
    }
}
