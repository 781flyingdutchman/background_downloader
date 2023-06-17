//
//  TaskFunctions.swift
//  background_downloader
//
//  Created on 2/11/23.
//

import Foundation
import os.log

let updatesQueue = DispatchQueue(label: "updatesProcessingQueue")
let separatorString = "***<<<|>>>***"

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

/// Returns the filePath associated with this task, or nil
func getFilePath(for task: Task) -> String? {
    guard let directory = try? directoryForTask(task: task)
    else {
        return nil
    }
    return directory.appendingPathComponent(task.filename).path
}

/// Processes a change in status for the task
///
/// Sends status update via the background channel to Dart, if requested
/// If the task is finished, processes a final progressUpdate update and removes
/// task from persistent storage
func processStatusUpdate(task: Task, status: TaskStatus, taskException: TaskException? = nil) {
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
        Downloader.localResumeData.removeValue(forKey: task.taskId)
    }
    if providesStatusUpdates(downloadTask: task) || retryNeeded {
        let finalTaskException = taskException == nil ? TaskException(type: .general,
                                                           httpResponseCode: -1, description: "") : taskException
        let arg: Any = status == .failed ? [status.rawValue, finalTaskException!.type.rawValue, finalTaskException!.description, finalTaskException!.httpResponseCode] as [Any] : status.rawValue
        if !postOnBackgroundChannel(method: "statusUpdate", task: task, arg: arg) {
            // store update locally as a merged task/status JSON string, without error info
            guard let jsonData = try? JSONEncoder().encode(task),
                  var jsonObject = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
            else {
                os_log("Could not store status update locally", log: log, type: .debug)
                return }
            jsonObject["taskStatus"] = status.rawValue
            storeLocally(prefsKey: Downloader.keyStatusUpdateMap, taskId: task.taskId, item: jsonObject)
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
            else {
                os_log("Could not store progress update locally", log: log, type: .info)
                return }
            jsonObject["progress"] = progress
            storeLocally(prefsKey: Downloader.keyProgressUpdateMap, taskId: task.taskId, item: jsonObject)
        }
    }
}

/// Process a 'canResume' message for the task
///
/// Sends the data via the background channel to Dart
func processCanResume(task: Task, taskCanResume: Bool) {
    if !postOnBackgroundChannel(method: "canResume", task: task, arg: taskCanResume) {
        os_log("Could not post CanResume", log: log, type: .info)
    }
}

/// Post resume data for this task
///
/// Returns true if successful.
/// Sends the data via the background channel to Dart
func processResumeData(task: Task, resumeData: Data) -> Bool {
    let resumeDataAsBase64String = resumeData.base64EncodedString()
    Downloader.localResumeData[task.taskId] = resumeDataAsBase64String
    if !postOnBackgroundChannel(method: "resumeData", task: task, arg: [resumeDataAsBase64String, 0 as Int64] as [Any]) {
        // store resume data locally
        guard let jsonData = try? JSONEncoder().encode(task),
              var taskJsonObject = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        else {
            os_log("Could not store resume data locally", log: log, type: .info)
            return false}
        let resumeDataMap = [
            "task": taskJsonObject,
            "data": resumeDataAsBase64String,
            "requiredStartByte": 0
        ] as [String : Any]
        storeLocally(prefsKey: Downloader.keyResumeDataMap, taskId: task.taskId, item: resumeDataMap)
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
///
/// [arg] can be a list or a single variable
func postOnBackgroundChannel(method: String, task:Task, arg: Any) -> Bool {
    guard let channel = Downloader.backgroundChannel else {
        os_log("Could not find background channel", log: log, type: .error)
        return false
    }
    guard let jsonString = jsonStringFor(task: task) else {
        os_log("Could not convert task to JSON", log: log, type: .error)
        return false
    }
    var argsList: [Any] = [jsonString]
    if arg is [Any] {
        argsList.append(contentsOf: arg as! [Any])
    } else {
        argsList.append(arg)
    }
    if Thread.isMainThread {
        DispatchQueue.main.async {
            channel.invokeMethod(method, arguments: argsList)
        }
        return true
    }
    var success = false
    updatesQueue.sync {
        let dispatchGroup = DispatchGroup()
        dispatchGroup.enter()
        DispatchQueue.main.async {
            channel.invokeMethod(method, arguments: argsList, result: {(r: Any?) -> () in
                success = !(r is FlutterError)
                if Downloader.forceFailPostOnBackgroundChannel{
                    success = false
                }
                dispatchGroup.leave()
            })
        }
        dispatchGroup.wait()
    }
    return success
}

/// Store the [item] in preferences under [prefsKey], keyed by [taskId]
func storeLocally(prefsKey: String, taskId: String,
                  item: [String:Any]) {
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
    guard let jsonData = getTaskJsonStringFrom(urlSessionTask: urlSessionTask)?.data(using: .utf8)
    else {
        return nil
    }
    let decoder = JSONDecoder()
    return try? decoder.decode(Task.self, from: jsonData)
}

/// Returns the taskJsonString contained in the urlSessionTask
func getTaskJsonStringFrom(urlSessionTask: URLSessionTask) -> String? {
    guard let taskDescription = urlSessionTask.taskDescription else {
        return nil
    }
    if taskDescription.contains(separatorString) {
        return taskDescription.components(separatedBy: separatorString)[0]
    }
    return taskDescription
}

/// Return the notificationConfig corresponding to the URLSessionTask, or nil if it cannot be matched
func getNotificationConfigFrom(urlSessionTask: URLSessionTask) -> NotificationConfig? {
    guard let jsonData = getNotificationConfigJsonStringFrom(urlSessionTask: urlSessionTask)?.data(using: .utf8)
    else {
        return nil
    }
    let decoder = JSONDecoder()
    return try? decoder.decode(NotificationConfig.self, from: jsonData)
}


/// Returns the notificationConfigJsonString contained in the urlSessionTask
func getNotificationConfigJsonStringFrom(urlSessionTask: URLSessionTask) -> String? {
    guard let taskDescription = urlSessionTask.taskDescription else {
        return nil
    }
    if taskDescription.contains(separatorString) {
        return taskDescription.components(separatedBy: separatorString)[1]
    }
    return nil
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
    case 3:
        dir = .libraryDirectory
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
