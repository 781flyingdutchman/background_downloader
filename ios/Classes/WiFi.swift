//
//  WiFi.swift
//  background_downloader
//
//  Created by Bram on 1/19/24.
//

import Foundation
import os.log

/// WiFi requirement modes at the application level
enum RequireWiFi: Int {
    case
    asSetByTask,
    forAllTasks,
    forNoTasks
}

/// Manages changes to WiFi requirement, by re-enqueuing tasks if needed
class WiFiQueue {
    static let shared = WiFiQueue()
    private let requireWiFiChangeQueue = DispatchQueue(label: "com.bbflight.background_downloader.requireWiFiChangeQueue", target: DispatchQueue.global())
    private let reEnqueueQueue = DispatchQueue(label: "com.bbflight.background_downloader.reEnqueueQueue", target: DispatchQueue.global())
    private let requireWiFiChangeSemaphore = DispatchSemaphore(value: 0)

    // Private initializer to prevent creating new instances
    private init() {}
    
    // Change the application level WiFi requirement and re-enqueue tasks as necessary
    func requireWiFiChange(requireWiFi: RequireWiFi, rescheduleRunningTasks: Bool) {
        requireWiFiChangeQueue.async {
            _Concurrency.Task {
                os_log("requireWiFi=%d", log: log, type: .fault, requireWiFi.rawValue)
                BDPlugin.requireWiFi = requireWiFi
                let defaults = UserDefaults.standard
                defaults.setValue(requireWiFi.rawValue, forKey: BDPlugin.keyRequireWiFi)
                UrlSessionDelegate.createUrlSession()
                guard let urlSessionTasks = await UrlSessionDelegate.urlSession?.allTasks
                else {
                    self.reEnqueuesDone()
                    return
                }
                var haveReEnqueued = false
                urlSessionTasks.forEach { urlSessionTask in
                    if (urlSessionTask is URLSessionDownloadTask && (urlSessionTask.state == .running || urlSessionTask.state == .suspended)) {
                        guard let task = getTaskFrom(urlSessionTask: urlSessionTask) else {
                            return
                        }
                        os_log("Checking taskId %@", log: log, type: .fault, task.taskId)
                        BDPlugin.propertyLock.withLock {
                            if taskRequiresWiFi(task: task) != BDPlugin.taskIdsRequiringWiFi.contains(task.taskId) {
                                // requirement differs, so we need to re-enqueue
                                if taskRequiresWiFi(task: task) {
                                    BDPlugin.taskIdsRequiringWiFi.insert(task.taskId)
                                } else {
                                    BDPlugin.taskIdsRequiringWiFi.remove(task.taskId)
                                }
                                if BDPlugin.progressInfo[task.taskId] == nil {
                                    os_log("TaskId %@ was enqueued, re-enqueueing", log: log, type: .fault, task.taskId)
                                    // enqueued only, so ensure it is re-enqueued and cancel
                                    haveReEnqueued = true
                                    BDPlugin.tasksToReEnqueue.insert(task)
                                    urlSessionTask.cancel()
                                } else {
                                    if rescheduleRunningTasks {
                                        os_log("TaskId %@ was running, re-enqueueing", log: log, type: .fault, task.taskId)
                                        // already running, so pause instead of cancel
                                        haveReEnqueued = true
                                        BDPlugin.tasksToReEnqueue.insert(task)
                                        _Concurrency.Task{
                                            await (urlSessionTask as! URLSessionDownloadTask).cancelByProducingResumeData()
                                        }
                                    }
                                }
                            } else {
                                os_log("No need to change taskId %@", log: log, type: .fault, task.taskId)
                            }
                        }
                    }
                }
                if !haveReEnqueued {
                    self.reEnqueuesDone() // nothing left to do
                }
            }
            self.requireWiFiChangeSemaphore.wait() // wait for re-enqueues to complete
        }
    }
    
    func reEnqueuesDone() {
        self.requireWiFiChangeSemaphore.signal()
    }
    
    
    /// Re-enqueue this task and associated data. Nil signals end of batch
    func reEnqueue(_ reEnqueueData: ReEnqueueData?) {
        os_log("ReEnqueue entry for %@", log: log, type: .fault, reEnqueueData?.task.taskId ?? "nil")
        reEnqueueQueue.async {
            guard let reEnqueueData = reEnqueueData else {
                os_log("reEnqueue with nil", log: log, type: .fault)
                // nil value indicates end of batch of re-enqueues
                self.reEnqueuesDone()
                return
            }
            os_log("TaskId %@ waiting to re-enqueue", log: log, type: .fault, reEnqueueData.task.taskId)
            let timeSinceCreated = Date().timeIntervalSince(reEnqueueData.created)
            if timeSinceCreated < 0.3 {
                Thread.sleep(forTimeInterval: 0.3 - timeSinceCreated)
            }
            os_log("TaskId %@ re-enqueueing", log: log, type: .fault, reEnqueueData.task.taskId)
            BDPlugin.instance.doEnqueue(taskJsonString: jsonStringFor(task: reEnqueueData.task) ?? "", notificationConfigJsonString: reEnqueueData.notificationConfigJsonString, resumeDataAsBase64String: reEnqueueData.resumeDataAsBase64String, result: nil)
            Thread.sleep(forTimeInterval: 0.02)
        }
    }
}

/// Re-enqueue data (in the context of changing the RequireWiFi setting)
struct ReEnqueueData {
    let task: Task
    let notificationConfigJsonString: String
    let resumeDataAsBase64String: String
    let created = Date()
}
