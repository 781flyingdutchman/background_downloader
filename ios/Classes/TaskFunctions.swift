//
//  TaskFunctions.swift
//  background_downloader
//
//  Created on 2/11/23.
//

import Foundation
import os.log

/// True if this task expects to provide progress updates
func providesProgressUpdates(task: Task) -> Bool {
    return task.updates == Updates.progressUpdates.rawValue || task.updates == Updates.statusChangeAndProgressUpdates.rawValue
}

/// True if this task expects to provide status updates
func providesStatusUpdates(downloadTask: Task) -> Bool {
    return downloadTask.updates == Updates.statusChange.rawValue || downloadTask.updates == Updates.statusChangeAndProgressUpdates.rawValue
}

/// True if this task is a DownloadTask, false if it is an UploadTask
func isDownloadTask(task: Task) -> Bool {
    return task.taskType != "UploadTask"
}

/// True if this task is an UploadTask, false if it is an UploadTask
func isUploadTask(task: Task) -> Bool {
    return task.taskType == "UploadTask"
}

/// True if this task is a binary UploadTask
func isBinaryUploadTask(task: Task) -> Bool {
    return isUploadTask(task: task) && task.post?.lowercased() == "binary"
}

/// True if this state is not a final state (i.e. more changes may happen)
func isNotFinalState(status: TaskStatus) -> Bool {
    return status == .enqueued || status == .running || status == .waitingToRetry
}

/// True if this state is a final state (i.e. no more changes will happen)
func isFinalState(status: TaskStatus) -> Bool {
    return !isNotFinalState(status: status)
}

/// Processes a change in status for the task
///
/// Sends status update via the background channel to Flutter, if requested
/// If the task is finished, processes a final progressUpdate update and removes
/// task from persistent storage
func processStatusUpdate(task: Task, status: TaskStatus) {
   guard let channel = Downloader.backgroundChannel else {
       os_log("Could not find background channel", log: log, type: .error)
       return
   }
   // Post update if task expects one, or if failed and retry is needed
   let retryNeeded = status == TaskStatus.failed && task.retriesRemaining > 0
   // if task is in final state, process a final progressUpdate
   // A 'failed' progress update is only provided if
   // a retry is not needed: if it is needed, a `waitingToRetry` progress update
   // will be generated on the Dart side
   if isFinalState(status: status) {
       switch (status) {
       case .complete:
           processProgressUpdate(task: task, progress: 1.0)
       case .failed:
           if !retryNeeded {
               processProgressUpdate(task: task, progress: -1.0)
           }
       case .canceled:
           processProgressUpdate(task: task, progress: -2.0)
       case .notFound:
           processProgressUpdate(task: task, progress: -3.0)
       default:
           break
       }
   }
   if providesStatusUpdates(downloadTask: task) || retryNeeded {
       let jsonString = jsonStringFor(task: task)
       if (jsonString != nil)
       {
           DispatchQueue.main.async {
               channel.invokeMethod("statusUpdate", arguments: [jsonString!, status.rawValue])
           }
       }
   }
   // if task is in final state, remove from persistent storage
   if isFinalState(status: status) {
       Downloader.nativeToTaskMap.removeValue(forKey: task.taskId)
       Downloader.lastProgressUpdate.removeValue(forKey: task.taskId)
       Downloader.nextProgressUpdateTime.removeValue(forKey: task.taskId)
   }
}


/// Processes a progress update for the task
///
/// Sends progress update via the background channel to Flutter, if requested
func processProgressUpdate(task: Task, progress: Double) {
    guard let channel = Downloader.backgroundChannel else {
        os_log("Could not find background channel", log: log, type: .error)
        return
    }
    if providesProgressUpdates(task: task) {
        let jsonString = jsonStringFor(task: task)
        if (jsonString != nil)
        {
            DispatchQueue.main.async {
                channel.invokeMethod("progressUpdate", arguments: [jsonString!, progress])
            }
        }
    }
}


/// Returns a JSON string for this Task, or nil
func jsonStringFor(task: Task) -> String? {
    let jsonEncoder = JSONEncoder()
    guard let jsonResultData = try? jsonEncoder.encode(task)
    else {
        return nil
    }
    return String(data: jsonResultData, encoding: .utf8)
}

/// Returns a Task from the supplied jsonString, or nil
func taskFrom(jsonString: String) -> Task? {
    let decoder = JSONDecoder()
    let task: Task? = try? decoder.decode(Task.self, from: (jsonString).data(using: .utf8)!)
    return task
}

/// Return the task corresponding to the URLSessionTask, or nil if it cannot be matched
func getTaskFrom(urlSessionTask: URLSessionTask) -> Task? {
    let decoder = JSONDecoder()
    guard let jsonData = urlSessionTask.taskDescription?.data(using: .utf8)
    else {
        return nil
    }
    return try? decoder.decode(Task.self, from: jsonData)
}

/// Returns the URL of the directory where the file for this task is stored
///
/// This is made up of the baseDirectory and the directory fields of the Task
func directoryForTask(task: Task) throws ->  URL {
    var dir: FileManager.SearchPathDirectory
    switch task.baseDirectory {
    case 0:
        dir = .documentDirectory
    case 1:
        dir = .cachesDirectory
    case 2:
        dir = .applicationSupportDirectory
    default:
        dir = .documentDirectory
    }
    let documentsURL =
    try FileManager.default.url(for: dir,
                            in: .userDomainMask,
                            appropriateFor: nil,
                            create: false)
    return task.directory.isEmpty
        ? documentsURL
        : documentsURL.appendingPathComponent(task.directory)
}
