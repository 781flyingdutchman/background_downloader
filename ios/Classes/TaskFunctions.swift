//
//  TaskFunctions.swift
//  background_downloader
//
//  Created on 2/11/23.
//

import Foundation
import os.log

let updatesQueue = DispatchQueue(label: "updatesProcessingQueue")

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
    return status == .enqueued || status == .running || status == .waitingToRetry || status == .paused
}

/// True if this state is a final state (i.e. no more changes will happen)
func isFinalState(status: TaskStatus) -> Bool {
    return !isNotFinalState(status: status)
}

/// Processes a change in status for the task
///
/// Sends status update via the background channel to Dart, if requested
/// If the task is finished, processes a final progressUpdate update and removes
/// task from persistent storage
func processStatusUpdate(task: Task, status: TaskStatus) {
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
        // remove from persistent storage
        Downloader.lastProgressUpdate.removeValue(forKey: task.taskId)
        Downloader.nextProgressUpdateTime.removeValue(forKey: task.taskId)
    }
    if providesStatusUpdates(downloadTask: task) || retryNeeded {
        if !postOnBackgroundChannel(method: "statusUpdate", task: task, arg: status.rawValue) {
            // store update locally as a merged task/status JSON string
            guard let jsonData = try? JSONEncoder().encode(task),
                  var jsonObject = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
            else { return }
            jsonObject["statusUpdate"] = status.rawValue
            guard let newJsonData = try? JSONSerialization.data(withJSONObject: jsonObject),
                  let jsonString = String(data: newJsonData, encoding: .utf8) else { return }
            storeLocally(prefsKey: Downloader.keyStatusUpdateMap, taskId: task.taskId, item: jsonString)
        }
    }
}


/// Processes a progress update for the task
///
/// Sends progress update via the background channel to Dart, if requested
func processProgressUpdate(task: Task, progress: Double) {
    if providesProgressUpdates(task: task) {
        if (!postOnBackgroundChannel(method: "progressUpdate", task: task, arg: progress)) {
            // store update locally as a merged task/progress JSON string
            guard let jsonData = try? JSONEncoder().encode(task),
                  var jsonObject = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
            else { return }
            jsonObject["progressUpdate"] = progress
            guard let newJsonData = try? JSONSerialization.data(withJSONObject: jsonObject),
                  let jsonString = String(data: newJsonData, encoding: .utf8) else { return }
            storeLocally(prefsKey: Downloader.keyStatusUpdateMap, taskId: task.taskId, item: jsonString)
        }
    }
}

/// Process a 'canResume' message for the task
///
/// Sends the data via the background channel to Dart
func processCanResume(task: Task, taskCanResume: Bool) {
    guard let channel = getBackgroundChannel() else { return }
    DispatchQueue.main.async {
        channel.invokeMethod("canResume", arguments: [jsonStringFor(task: task) ?? "", taskCanResume])
    }
}

/// Post resume data for this task
///
/// Returns true if successful.
/// Sends the data via the background channel to Dart
func processResumeData(task: Task, resumeData: Data) -> Bool {
    guard let channel = getBackgroundChannel() else { return false }
    let resumeDataAsBase64String = resumeData.base64EncodedString()
    DispatchQueue.main.async {
        channel.invokeMethod("resumeData", arguments: [jsonStringFor(task: task) ?? "", resumeDataAsBase64String, 0 as Int64])
    }
    return true
}

/// Return the background channel for cummincation to Dart side, or nil
func getBackgroundChannel() -> FlutterMethodChannel? {
    guard let channel = Downloader.backgroundChannel else {
        os_log("Could not find background channel", log: log, type: .error)
        return nil
    }
    return channel
}

/// Post method message on backgroundChannel with arguments and return true if this was successful
func postOnBackgroundChannel(method: String, task:Task, arg: Any, arg2: Any? = nil) -> Bool {
    guard let channel = Downloader.backgroundChannel else {
        os_log("Could not find background channel", log: log, type: .error)
        return false
    }
    guard let jsonString = jsonStringFor(task: task) else {
        os_log("Could not convert task to JSON", log: log, type: .error)
        return false
    }
    var argsList = [jsonString, arg]
    if (arg2 != nil) {
        argsList.append(arg2!)
    }
    if Thread.isMainThread {
        DispatchQueue.main.async {
            channel.invokeMethod(method, arguments: argsList)
        }
        return true
    }
    var success = false
    updatesQueue.sync {
        os_log("Starting postOnBG", log: log, type: .error)
        let dispatchGroup = DispatchGroup()
        dispatchGroup.enter()
        os_log("Before post async", log: log, type: .error)
        DispatchQueue.main.async {
            channel.invokeMethod(method, arguments: argsList, result: {(r: Any?) -> () in
                os_log("result async", log: log, type: .error)
                success = !(r is FlutterError)
                os_log("Set success not in  main thread: %d", log: log, type: .info, success)
                dispatchGroup.leave()
            })
        }
        os_log("Before wait", log: log, type: .error)
        dispatchGroup.wait()
    }
    os_log("Returning success: %d", log: log, type: .info, success)
    return success
}

/// Store the [item] in preferences under [prefsKey], keyed by [taskId]
func storeLocally(prefsKey: String, taskId: String,
                  item: String) {
    os_log("Storing locally: %@", log: log, type: .info, item)
    let defaults = UserDefaults.standard
    var map: [String:Any] = defaults.dictionary(forKey: prefsKey) ?? [:]
    map[taskId] = item
    defaults.set(map, forKey: prefsKey)
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
