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

/// True if this task is a DownloadTask, false if not
///
/// A ParallelDownloadTask is also a DownloadTask
func isDownloadTask(task: Task) -> Bool {
    return task.taskType == "DownloadTask" || task.taskType == "ParallelDownloadTask"
}

/// True if this task is a ParallelDownloadTask, false if not
func isParallelDownloadTask(task: Task) -> Bool
{
    return task.taskType == "ParallelDownloadTask"
}

/// True if this task is an UploadTask, false if not
///
/// A MultiUploadTask is also an UploadTask
func isUploadTask(task: Task) -> Bool {
    return task.taskType == "UploadTask" || task.taskType == "MultiUploadTask"
}

/// True if this task is a MultiUploadTask, false if not
func isMultiUploadTask(task: Task) -> Bool {
    return task.taskType == "MultiUploadTask"
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

/// Returns the absolute path to the file represented by this task
/// based on the [Task.filename] (default) or [withFilename]
///
/// If the task is a MultiUploadTask and no [withFilename] is given,
/// returns the empty string, as there is no single path that can be
/// returned
func getFilePath(for task: Task, withFilename: String? = nil) -> String? {
    if isMultiUploadTask(task: task) && withFilename == nil {
        return ""
    }
    guard let directory = try? directoryForTask(task: task)
    else {
        return nil
    }
    return directory.appendingPathComponent(withFilename ?? task.filename).path
}

func stripFileExtension ( _ filename: String ) -> String {
    var components = filename.components(separatedBy: ".")
    guard components.count > 1 else { return filename }
    components.removeLast()
    return components.joined(separator: ".")
}

/**
 * Returns a copy of the task with the [Task.filename] property changed
 * to the filename suggested by the server, or derived from the url, or
 * unchanged.
 *
 * If [unique] is true, the filename is guaranteed not to already exist. This
 * is accomplished by adding a suffix to the suggested filename with a number,
 * e.g. "data (2).txt"
 *
 * The server-suggested filename is obtained from the  [responseHeaders] entry
 * "Content-Disposition"
 */
func suggestedFilenameFromResponseHeaders(
    task: Task,
    responseHeaders: [AnyHashable: Any],
    unique: Bool = false
) -> Task {
    if let disposition = responseHeaders["Content-Disposition"] as? String {
        let range = NSMakeRange(0, disposition.utf16.count)
        // Try filename*=UTF-8'language'"encodedFilename"
        let encodedFilenameRegEx = try! NSRegularExpression(pattern: #"filename\*=\s*([^']+)'([^']*)'"?([^"]+)"?"#, options: .caseInsensitive)
        if let match = encodedFilenameRegEx.firstMatch(in: disposition, options: [], range: range) {
            let encoding = String(disposition[Range(match.range(at: 1), in: disposition)!]).uppercased()
            let filename = String(disposition[Range(match.range(at: 3), in: disposition)!])
            if encoding == "UTF-8" {
                if let decodedFilename = filename.removingPercentEncoding {
                    return uniqueFilename(task: task.copyWith(filename: decodedFilename), unique: unique)
                } else {
                    os_log("Could not interpret suggested filename (UTF-8 url encoded)", log: log, type: .debug)
                }
            } else {
                return uniqueFilename(task: task.copyWith(filename: filename), unique: unique)
            }
        }
        // Try filename="filename"
        let plainFilenameRegEx = try! NSRegularExpression(pattern: #"filename=\s*"?([^"]+)"?.*$"#, options: .caseInsensitive)
        if let match = plainFilenameRegEx.firstMatch(in: disposition, options: [], range: range) {
            let filename = String(disposition[Range(match.range(at: 1), in: disposition)!])
            return uniqueFilename(task: task.copyWith(filename: filename), unique: unique)
        }
    }
    os_log("Could not determine suggested filename from server", log: log, type: .debug)
    // Try filename derived from last path segment of the url
    if let uri = URL(string: task.url) {
        let suggestedFilename = uri.lastPathComponent
        if !suggestedFilename.isEmpty {
            return uniqueFilename(task: task.copyWith(filename: suggestedFilename), unique: unique)
        }
    }
    os_log("Could not parse URL pathSegment for suggested filename", log: log, type: .debug)
    // if everything fails, return the task with unchanged filename
    // except for possibly making it unique
    return uniqueFilename(task: task, unique: unique)
}

/// Returns [Task] with a filename similar to the one
/// supplied, but unused.
///
/// If [unique], filename will sequence up in "filename (8).txt" format,
/// otherwise returns the [task]
func uniqueFilename(task: Task, unique: Bool) -> Task {
    if !unique {
        return task
    }
    let sequenceRegEx = try! NSRegularExpression(pattern: #"\((\d+)\)\.?[^.]*$"#)
    let extensionRegEx = try! NSRegularExpression(pattern: #"\.[^.]*$"#)
    var newTask = task
    guard let filePath = getFilePath(for: task) else {
        return task
    }
    var exists = FileManager.default.fileExists(atPath: filePath)
    
    while exists {
        let range = NSMakeRange(0, newTask.filename.utf16.count)
        let extMatch = extensionRegEx.firstMatch(in: newTask.filename, options: [], range: range)
        let extString = extMatch != nil ? String(newTask.filename[Range(extMatch!.range, in: newTask.filename)!]) : ""
        let seqMatch = sequenceRegEx.firstMatch(in: newTask.filename, options: [], range: range)
        let seqString = seqMatch != nil ? String(newTask.filename[Range(seqMatch!.range, in: newTask.filename)!]) : ""
        let newSequence = seqString.isEmpty ? 1 : Int(seqString)! + 1
        
        let newFilename: String
        if seqMatch == nil {
            let baseNameWithoutExtension = stripFileExtension(newTask.filename)
            newFilename = "\(baseNameWithoutExtension) (\(newSequence))\(extString)"
        } else {
            let startOfSeq = seqMatch!.range.location
            let index = newTask.filename.index(newTask.filename.startIndex, offsetBy: startOfSeq)
            newFilename = "\(newTask.filename.prefix(upTo: index)) (\(newSequence))\(extString)"
        }
        newTask = newTask.copyWith(filename: newFilename)
        guard let filePath = getFilePath(for: task) else {
            return task
        }
        exists = FileManager.default.fileExists(atPath: filePath)
    }
    return newTask
}

/**
 * Parses the range in a Range header, and returns a Pair representing
 * the range. The format needs to be "bytes=10-20"
 *
 * A missing lower range is substituted with 0L, and a missing upper
 * range with null.  If the string cannot be parsed, returns (0L, null)
 */
func parseRange(rangeStr: String) -> (Int64, Int64?) {
    let regex = try! NSRegularExpression(pattern: #"bytes=(\d*)-(\d*)"#)
    let range = NSMakeRange(0, rangeStr.utf16.count)
    if let match = regex.firstMatch(in: rangeStr, options: [], range: range) {
        let start = Int64(String(rangeStr[Range(match.range(at: 1), in: rangeStr)!]))
        let end = Int64(String(rangeStr[Range(match.range(at: 2), in: rangeStr)!]))
        return (start!, end!)
    } else {
        return (0, nil)
    }
}

/// Returns the content length extracted from the [responseHeaders], or from
/// the [task] headers
func getContentLength(responseHeaders: [AnyHashable: Any], task: Task) -> Int64 {
    // On iOS, the header has already been parsed for Content-Length so we don't need to
    // repeat that here
    // try extracting it from Range header
    let taskRangeHeader = task.headers["Range"] ?? ""
    let taskRange = parseRange(rangeStr: taskRangeHeader)
    if let end = taskRange.1 {
        let rangeLength = end - taskRange.0 + 1
        os_log("TaskId %@ contentLength set to %d based on Range header", log: log, type: .info, task.taskId, rangeLength)
        return rangeLength
    }
    
    // try extracting it from a special "Known-Content-Length" header
    let knownLength = Int64(task.headers["Known-Content-Length"] ?? "-1") ?? -1
    if knownLength != -1 {
        os_log("TaskId %@ contentLength set to %d based on Known-Content-Length header", log: log, type: .info, task.taskId, knownLength)
    } else {
        os_log("TaskId %@ contentLength undetermined", log: log, type: .info, task.taskId)
    }
    return knownLength
}

/// Sets the mimeType and charSet extracted from the Content-Type header
/// in [responseHeaders] and stores in static maps keyed by [task.taskId]
func extractContentType(responseHeaders: [AnyHashable: Any], task: Task)  {
    guard let contentType = responseHeaders["Content-Type"] as? String else { return }
    let regEx = try! NSRegularExpression(pattern: #"(.*);\s*charset\s*=(.*)"#)
    let range = NSMakeRange(0, contentType.utf16.count)
    let match = regEx.firstMatch(in: contentType, options: [], range: range)
    if let match = match {
        let mimeType = String(contentType[Range(match.range(at: 1), in: contentType)!])
        let charSet = String(contentType[Range(match.range(at: 2), in: contentType)!])
        BDPlugin.mimeTypes[task.taskId] = mimeType
        BDPlugin.charSets[task.taskId] = charSet
    } else {
        BDPlugin.mimeTypes[task.taskId] = contentType
    }
}



/// Returns a list of fileData elements, one for each file to upload.
/// Each element is a triple containing fileField, full filePath, mimeType
///
/// The lists are stored in the similarly named String fields as a JSON list,
/// with each list the same length. For the filenames list, if a filename refers
/// to a file that exists (i.e. it is a full path) then that is the filePath used,
/// otherwise the filename is appended to the [Task.baseDirectory] and [Task.directory]
/// to form a full file path
func extractFilesData(task: Task) -> [((String, String, String))] {
    let decoder = JSONDecoder()
    guard
        let fileFields = try? decoder.decode([String].self, from: task.fileField!.data(using: .utf8)!),
        let filenames = try? decoder.decode([String].self, from: task.filename.data(using: .utf8)!),
        let mimeTypes = try? decoder.decode([String].self, from: task.mimeType!.data(using: .utf8)!)
    else {
        os_log("Could not parse filesData from field=%@, filename=%@ and mimeType=%@", log: log, type: .error, task.fileField!, task.filename, task.mimeType!)
        return []
    }
    var result = [(String, String, String)]()
    for i in 0 ..< fileFields.count {
        if FileManager.default.fileExists(atPath: filenames[i]) {
            result.append((fileFields[i], filenames[i], mimeTypes[i]))
        } else {
            result.append((
                fileFields[i],
                getFilePath(for: task, withFilename: filenames[i]) ?? "",
                mimeTypes[i]
            ))
        }
    }
    return result
}

/// Calculate progress, network speed and time remaining, and send this at an appropriate
/// interval to the Dart side
func updateProgress(task: Task, totalBytesExpected: Int64, totalBytesDone: Int64) {
    let info = BDPlugin.progressInfo[task.taskId] ?? (lastProgressUpdateTime: 0.0, lastProgressValue: 0.0, lastTotalBytesDone: 0, lastNetworkSpeed: -1.0)
    if totalBytesExpected != NSURLSessionTransferSizeUnknown && Date().timeIntervalSince1970 > info.lastProgressUpdateTime + 0.5 {
        let progress = min(Double(totalBytesDone) / Double(totalBytesExpected), 0.999)
        if progress - info.lastProgressValue > 0.02 {
            // calculate network speed and time remaining
            let now = Date().timeIntervalSince1970
            let timeSinceLastUpdate = now - info.lastProgressUpdateTime
            let bytesSinceLastUpdate = totalBytesDone - info.lastTotalBytesDone
            let currentNetworkSpeed: Double = timeSinceLastUpdate > 3600 ? -1.0 : Double(bytesSinceLastUpdate) / timeSinceLastUpdate / 1000000.0
            let newNetworkSpeed = info.lastNetworkSpeed == -1.0 ? currentNetworkSpeed : (info.lastNetworkSpeed * 3.0 + currentNetworkSpeed) / 4.0
            let remainingBytes = (1.0 - progress) * Double(totalBytesExpected)
            let timeRemaining: TimeInterval = newNetworkSpeed == -1.0 ? -1.0 : (remainingBytes / newNetworkSpeed / 1000000.0)
            BDPlugin.progressInfo[task.taskId] = (lastProgressUpdateTime: now, lastProgressValue: progress, lastTotalBytesDone: totalBytesDone, lastNetworkSpeed: newNetworkSpeed)
            processProgressUpdate(task: task, progress: progress, expectedFileSize: totalBytesExpected, networkSpeed: newNetworkSpeed, timeRemaining: timeRemaining)
        }
    }
}


/// Processes a change in status for the task
///
/// Sends status update via the background channel to Dart, if requested
/// If the task is finished, processes a final progressUpdate update and removes
/// task from persistent storage
func processStatusUpdate(task: Task, status: TaskStatus, taskException: TaskException? = nil, responseBody: String? = nil, mimeType: String? = nil, charSet: String? = nil) {
    // Post update if task expects one, or if failed and retry is needed
    let retryNeeded = status == TaskStatus.failed && task.retriesRemaining > 0
    // if task is in final state, process a final progressUpdate
    // A 'failed' progress update is only provided if
    // a retry is not needed: if it is needed, a `waitingToRetry` progress update
    // will be generated on the Dart side
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
        case .paused:
            processProgressUpdate(task: task, progress: -5.0)
        default:
            break
    }
    
    if providesStatusUpdates(downloadTask: task) || retryNeeded {
        let finalTaskException = taskException == nil
        ? TaskException(type: .general, httpResponseCode: -1, description: "")
        : taskException
        let arg: [Any?] = status == .failed
        ? [status.rawValue, finalTaskException!.type.rawValue, finalTaskException!.description, finalTaskException!.httpResponseCode, responseBody] as [Any?]
        : [status.rawValue, responseBody, mimeType, charSet] as [Any?]
        if !postOnBackgroundChannel(method: "statusUpdate", task: task, arg: arg) {
            // store update locally as a merged task/status JSON string, without error info
            guard let jsonData = try? JSONEncoder().encode(TaskStatusUpdate(task: task, taskStatus: status))
            else {
                os_log("Could not store status update locally", log: log, type: .debug)
                return }
            storeLocally(prefsKey: BDPlugin.keyStatusUpdateMap, taskId: task.taskId, item: jsonData)
        }
    }
    if isFinalState(status: status) {
        // remove references to this task that are no longer needed
        BDPlugin.progressInfo.removeValue(forKey: task.taskId)
        BDPlugin.localResumeData.removeValue(forKey: task.taskId)
        BDPlugin.remainingBytesToDownload.removeValue(forKey: task.taskId)
        BDPlugin.tasksWithSuggestedFilename.removeValue(forKey: task.taskId)
        BDPlugin.tasksWithContentLengthOverride.removeValue(forKey: task.taskId)
        BDPlugin.responseBodyData.removeValue(forKey: task.taskId)
        BDPlugin.taskIdsThatCanResume.remove(task.taskId)
        BDPlugin.taskIdsProgrammaticallyCancelled.remove(task.taskId)
    }
}


/// Processes a progress update for the task
///
/// Sends progress update via the background channel to Dart, if requested
func processProgressUpdate(task: Task, progress: Double, expectedFileSize: Int64 = -1, networkSpeed: Double = -1.0, timeRemaining: TimeInterval = -1.0) {
    if providesProgressUpdates(task: task) {
        if (!postOnBackgroundChannel(method: "progressUpdate", task: task, arg: [progress, expectedFileSize, networkSpeed, Int(timeRemaining * 1000.0)] as [Any])) {
            // store update locally as a merged task/progress JSON string
            guard let jsonData = try? JSONEncoder().encode(TaskProgressUpdate(task: task, progress: progress, expectedFileSize: expectedFileSize))
            else {
                os_log("Could not store progress update locally", log: log, type: .info)
                return }
            storeLocally(prefsKey: BDPlugin.keyProgressUpdateMap, taskId: task.taskId, item: jsonData)
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
    BDPlugin.localResumeData[task.taskId] = resumeDataAsBase64String
    if !postOnBackgroundChannel(method: "resumeData", task: task, arg: resumeDataAsBase64String) {
        // store resume data locally
        guard let jsonData = try? JSONEncoder().encode(ResumeData(task: task, data: resumeDataAsBase64String))
        else {
            os_log("Could not store resume data locally", log: log, type: .info)
            return false}
        storeLocally(prefsKey: BDPlugin.keyResumeDataMap, taskId: task.taskId, item: jsonData)
    }
    return true
}

/// Return the background channel for cummincation to Dart side, or nil
func getBackgroundChannel() -> FlutterMethodChannel? {
    guard let channel = BDPlugin.backgroundChannel else {
        os_log("Could not find background channel", log: log, type: .error)
        return nil
    }
    return channel
}

/// Post method message on backgroundChannel with arguments and return true if this was successful
///
/// [arg] can be a list or a single variable
func postOnBackgroundChannel(method: String, task:Task, arg: Any) -> Bool {
    guard let channel = BDPlugin.backgroundChannel else {
        os_log("Could not find background channel", log: log, type: .error)
        return false
    }
    guard let jsonString = jsonStringFor(task: task) else {
        os_log("Could not convert task to JSON", log: log, type: .error)
        return false
    }
    var argsList: [Any?] = [jsonString]
    if arg is [Any?] {
        argsList.append(contentsOf: arg as! [Any?])
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
                if BDPlugin.forceFailPostOnBackgroundChannel {
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
///
/// [item] is a JsonEncoded Data object
func storeLocally(prefsKey: String, taskId: String,
                  item: Data) {
    let defaults = UserDefaults.standard
    var map = defaults.dictionary(forKey: prefsKey) ?? [:]
    map[taskId] = String(data: item, encoding: .utf8)
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
///
/// If possible, the task returned contains the suggested filename
func getTaskFrom(urlSessionTask: URLSessionTask) -> Task? {
    guard let jsonData = getTaskJsonStringFrom(urlSessionTask: urlSessionTask)?.data(using: .utf8)
    else {
        return nil
    }
    let decoder = JSONDecoder()
    if let task = try? decoder.decode(Task.self, from: jsonData) {
        return BDPlugin.tasksWithSuggestedFilename[task.taskId] ?? task
    }
    return nil
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
    let documentsURL: URL
    if task.baseDirectory != BaseDirectory.root.rawValue {
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
        documentsURL =
        try FileManager.default.url(for: dir,
                                    in: .userDomainMask,
                                    appropriateFor: nil,
                                    create: false)
    } else {
        documentsURL = URL(fileURLWithPath: "/")
    }
    return task.directory.isEmpty
    ? documentsURL
    : documentsURL.appendingPathComponent(task.directory)
    
}

/**
 * Returns true if there is insufficient space to store a file of length
 * [contentLength]
 *
 * Returns false if [contentLength] <= 0
 * Returns false if configCheckAvailableSpace has not been set, or if available
 * space is greater than that setting
 * Returns true otherwise
 */
func insufficientSpace(contentLength: Int64) -> Bool {
    guard contentLength > 0 else {
        return false
    }
    let checkValue = UserDefaults.standard.integer(forKey: BDPlugin.keyConfigCheckAvailableSpace)
    guard
        // Check if the configCheckAvailableSpace preference is set and is positive
        checkValue > 0,
        let path = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first,
        let available = try? URL(fileURLWithPath: path).resourceValues(forKeys: [URLResourceKey.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
    else {
        return false
    }
    // Calculate the total remaining bytes to download
    let remainingBytesToDownload = BDPlugin.remainingBytesToDownload.values.reduce(0, +)
    // Return true if there is insufficient space to store the file
    return available - (remainingBytesToDownload + contentLength) < checkValue << 20
}

/// Post result [value] on FlutterResult completer
func postResult(result: FlutterResult?, value: Any) {
    if result != nil {
        result!(value)
    }
}
