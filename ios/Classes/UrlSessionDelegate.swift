//
//  UrlSessionDelegate.swift
//  background_downloader
//
//  Created by Bram on 11/12/23.
//

import Foundation
import os.log


public class UrlSessionDelegate : NSObject, URLSessionDelegate, URLSessionDownloadDelegate, URLSessionDataDelegate {
    
    static let instance = UrlSessionDelegate()
    static var urlSession: URLSession?
    public static var sessionIdentifier = "com.bbflight.background_downloader.Downloader"
    private static var backgroundCompletionHandler: (() -> Void)?
    
    //MARK: URLSessionTaskDelegate
    
    /// Handle task completion
    ///
    /// DownloadTasks handle task completion in the :didFinishDownloadingTo function, so for download tasks
    /// we only process status updates if there was an error.
    /// For other tasks we handle error, or send .complete
    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let multipartUploader = BDPlugin.uploaderForUrlSessionTaskIdentifier[task.taskIdentifier]
        if multipartUploader != nil {
            try? FileManager.default.removeItem(at: multipartUploader!.outputFileUrl())
            BDPlugin.uploaderForUrlSessionTaskIdentifier.removeValue(forKey: task.taskIdentifier)
        }
        let responseStatusCode = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        let responseStatusDescription = HTTPURLResponse.localizedString(forStatusCode: responseStatusCode)
        let notificationConfig = getNotificationConfigFrom(urlSessionTask: task)
        // from here on, task refers to "our" task, not a URLSessionTask
        guard let task = getTaskFrom(urlSessionTask: task) else {
            os_log("Could not find task related to urlSessionTask %d", log: log, type: .error, task.taskIdentifier)
            return
        }
        let responseBody = getResponseBody(taskId: task.taskId)
        let taskWasProgramaticallyCanceled: Bool = BDPlugin.taskIdsProgrammaticallyCancelled.remove(task.taskId) != nil
        guard error == nil else {
            // handle the error if this task wasn't programatically cancelled (in which
            // case the error has been handled already)
            if !taskWasProgramaticallyCanceled {
                // check if we have resume data, and if so, process it
                let userInfo = (error! as NSError).userInfo
                let resumeData = userInfo[NSURLSessionDownloadTaskResumeData] as? Data
                let canResume = resumeData != nil && processResumeData(task: task, resumeData: resumeData!)
                // check different error codes
                if (error! as NSError).code == NSURLErrorTimedOut {
                    os_log("Task with id %@ timed out", log: log, type: .info, task.taskId)
                    processStatusUpdate(task: task, status: .failed, taskException: TaskException(type: .connection, httpResponseCode: -1, description: error!.localizedDescription))
                    return
                }
                if (error! as NSError).code == NSURLErrorCancelled {
                    // cancelled with resumedata implies 'pause'
                    if canResume {
                        os_log("Paused task with id %@", log: log, type: .info, task.taskId)
                        processStatusUpdate(task: task, status: .paused)
                        if isDownloadTask(task: task) {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                updateNotification(task: task, notificationType: .paused, notificationConfig: notificationConfig)
                            }
                        }
                        BDPlugin.progressInfo.removeValue(forKey: task.taskId) // ensure .running update on resume
                        return
                    }
                    // cancelled without resumedata implies 'cancel'
                    os_log("Canceled task with id %@", log: log, type: .info, task.taskId)
                    processStatusUpdate(task: task, status: .canceled)
                }
                else {
                    os_log("Error for taskId %@: %@", log: log, type: .error, task.taskId, error!.localizedDescription)
                    processStatusUpdate(task: task, status: .failed, taskException: TaskException(type: .general, httpResponseCode: -1, description: error!.localizedDescription))
                }
            }
            if isDownloadTask(task: task) {
                updateNotification(task: task, notificationType: .error, notificationConfig: notificationConfig)
            }
            return
        }
        // there was no error
        os_log("Finished task with id %@", log: log, type: .info, task.taskId)
        // if this is an upload task, send final TaskStatus (based on HTTP status code
        if isUploadTask(task: task) {
            let taskException = TaskException(type: .httpResponse, httpResponseCode: responseStatusCode, description: responseStatusDescription)
            let finalStatus = (200...206).contains(responseStatusCode)
            ? TaskStatus.complete
            : responseStatusCode == 404
            ? TaskStatus.notFound
            : TaskStatus.failed
            processStatusUpdate(task: task, status: finalStatus, taskException: taskException, responseBody: responseBody)
        }
    }
    
    //MARK: URLSessionDownloadTaskDelegate
    
    
    
    /// Process taskdelegate progress update for download task
    ///
    /// If the task requires progress updates, provide these at a reasonable interval
    /// If this is the first update for this file, also emit a 'running' status update
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        // task is var because the filename can be changed on the first 'didWriteData' call
        guard var task = getTaskFrom(urlSessionTask: downloadTask) else { return }
        if BDPlugin.progressInfo[task.taskId] == nil {
            // first 'didWriteData' call
            let response = downloadTask.response as! HTTPURLResponse
            // get suggested filename if needed
            if task.filename == "?" {
                let newTask = suggestedFilenameFromResponseHeaders(task: task, responseHeaders: response.allHeaderFields)
                os_log("Suggested task filename for taskId %@ is %@", log: log, type: .info, newTask.taskId, newTask.filename)
                if newTask.filename != task.filename {
                    // store for future replacement, and replace now
                    BDPlugin.tasksWithSuggestedFilename[newTask.taskId] = newTask
                    task = newTask
                }
            }
            extractContentType(responseHeaders: response.allHeaderFields, task: task)
            // obtain content length override, if needed and available
            if totalBytesExpectedToWrite == -1 {
                let contentLength = getContentLength(responseHeaders: response.allHeaderFields, task: task)
                if contentLength != -1 {
                    BDPlugin.tasksWithContentLengthOverride[task.taskId] = contentLength
                }
            }
            // Check if there is enough space
            if insufficientSpace(contentLength: totalBytesExpectedToWrite) {
                if !BDPlugin.taskIdsProgrammaticallyCancelled.contains(task.taskId) {
                    os_log("Error for taskId %@: Insufficient space to store the file to be downloaded", log: log, type: .error, task.taskId)
                    processStatusUpdate(task: task, status: .failed, taskException: TaskException(type: .fileSystem, httpResponseCode: -1, description: "Insufficient space to store the file to be downloaded for taskId \(task.taskId)"))
                    BDPlugin.taskIdsProgrammaticallyCancelled.insert(task.taskId)
                    downloadTask.cancel()
                }
                return
            }
            // Send 'running' status update and check if the task is resumable
            processStatusUpdate(task: task, status: TaskStatus.running)
            processProgressUpdate(task: task, progress: 0.0)
            BDPlugin.progressInfo[task.taskId] = (lastProgressUpdateTime: 0, lastProgressValue: 0.0, lastTotalBytesDone: 0, lastNetworkSpeed: -1.0)
            if task.allowPause {
                let acceptRangesHeader = (downloadTask.response as? HTTPURLResponse)?.allHeaderFields["Accept-Ranges"]
                let taskCanResume = acceptRangesHeader as? String == "bytes"
                processCanResume(task: task, taskCanResume: taskCanResume)
                if taskCanResume {
                    BDPlugin.taskIdsThatCanResume.insert(task.taskId)
                }
            }
            // notify if needed
            let notificationConfig = getNotificationConfigFrom(urlSessionTask: downloadTask)
            if (notificationConfig != nil) {
                updateNotification(task: task, notificationType: .running, notificationConfig: notificationConfig)
            }
        }
        let contentLength = totalBytesExpectedToWrite != -1 ? totalBytesExpectedToWrite : BDPlugin.tasksWithContentLengthOverride[task.taskId] ?? -1
        BDPlugin.remainingBytesToDownload[task.taskId] = contentLength - totalBytesWritten
        updateProgress(task: task, totalBytesExpected: contentLength, totalBytesDone: totalBytesWritten)
    }
    
    /// Process taskdelegate progress update for upload task
    ///
    /// If the task requires progress updates, provide these at a reasonable interval
    /// If this is the first update for this file, also emit a 'running' status update
    public func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        let urlSessionTask = task
        guard let task = getTaskFrom(urlSessionTask: task) else {return}
        let taskId = task.taskId
        if BDPlugin.progressInfo[taskId] == nil {
            // first call to this method: send 'running' status update
            processStatusUpdate(task: task, status: TaskStatus.running)
            processProgressUpdate(task: task, progress: 0.0)
            BDPlugin.progressInfo[task.taskId] = (lastProgressUpdateTime: 0, lastProgressValue: 0.0, lastTotalBytesDone: 0, lastNetworkSpeed: -1.0)
            // notify if needed
            let notificationConfig = getNotificationConfigFrom(urlSessionTask: urlSessionTask)
            if (notificationConfig != nil) {
                updateNotification(task: task, notificationType: .running, notificationConfig: notificationConfig)
            }
        }
        updateProgress(task: task, totalBytesExpected: totalBytesExpectedToSend, totalBytesDone: totalBytesSent)
    }
    
    /// Process end of downloadTask sent by the urlSession.
    ///
    /// If successful, (over)write file to final destination per Task info
    public func urlSession(_ session: URLSession,
                           downloadTask: URLSessionDownloadTask,
                           didFinishDownloadingTo location: URL) {
        guard let task = getTaskFrom(urlSessionTask: downloadTask),
              let response = downloadTask.response as? HTTPURLResponse
        else {
            os_log("Could not find task associated urlSessionTask %d, or did not get HttpResponse", log: log,  type: .info, downloadTask.taskIdentifier)
            return}
        let taskId = task.taskId
        let mimeType = BDPlugin.mimeTypes[taskId]
        let charSet = BDPlugin.charSets[taskId]
        BDPlugin.mimeTypes.removeValue(forKey: taskId)
        BDPlugin.charSets.removeValue(forKey: taskId)
        BDPlugin.tasksWithSuggestedFilename.removeValue(forKey: taskId)
        BDPlugin.tasksWithContentLengthOverride.removeValue(forKey: taskId)
        let notificationConfig = getNotificationConfigFrom(urlSessionTask: downloadTask)
        if response.statusCode == 404 {
            let responseBody = readFile(url: location)
            processStatusUpdate(task: task, status: TaskStatus.notFound, responseBody: responseBody)
            updateNotification(task: task, notificationType: .error, notificationConfig: notificationConfig)
            return
        }
        if !(200...206).contains(response.statusCode)   {
            os_log("TaskId %@ returned response code %d", log: log,  type: .info, task.taskId, response.statusCode)
            let responseBody = readFile(url: location)
            processStatusUpdate(task: task, status: TaskStatus.failed, taskException: TaskException(type: .httpResponse, httpResponseCode: response.statusCode, description: responseBody?.isEmpty == false ? responseBody! : HTTPURLResponse.localizedString(forStatusCode: response.statusCode)))
            if task.retriesRemaining == 0 {
                // update notification only if no retries remaining
                updateNotification(task: task, notificationType: .error, notificationConfig: notificationConfig)
            }
            return
        }
        do {
            var finalStatus = TaskStatus.failed
            var taskException: TaskException? = nil
            defer {
                processStatusUpdate(task: task, status: finalStatus, taskException: taskException, mimeType: mimeType, charSet: charSet)
                if finalStatus != TaskStatus.failed || task.retriesRemaining == 0 {
                    // update notification only if not failed, or no retries remaining
                    updateNotification(task: task, notificationType: notificationTypeForTaskStatus(status: finalStatus), notificationConfig: notificationConfig)
                }
            }
            let directory = try directoryForTask(task: task)
            do
            {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories:  true)
            } catch {
                os_log("Failed to create directory %@", log: log, type: .error, directory.path)
                taskException = TaskException(type: .fileSystem, httpResponseCode: -1,
                                              description: "Failed to create directory \(directory.path)")
                return
            }
            let filePath = directory.appendingPathComponent(task.filename)
            if FileManager.default.fileExists(atPath: filePath.path) {
                try? FileManager.default.removeItem(at: filePath)
            }
            do {
                try FileManager.default.moveItem(at: location, to: filePath)
            } catch {
                os_log("Failed to move file from %@ to %@: %@", log: log, type: .error, location.path, filePath.path, error.localizedDescription)
                taskException = TaskException(type: .fileSystem, httpResponseCode: -1,
                                              description: "Failed to move file from \(location.path) to \(filePath.path): \(error.localizedDescription)")
                return
            }
            finalStatus = TaskStatus.complete
        } catch {
            os_log("Uncaught file download error for taskId %@ and file %@: %@", log: log, type: .error, task.taskId, task.filename, error.localizedDescription)
        }
    }
    
    //MARK: URLSessionDataDelegate
    
    /// Collects incoming data following a file upload, by appending the data block to a static dictionary keyed by taskId
    public func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    )
    {
        guard let task = getTaskFrom(urlSessionTask: dataTask)
        else {
            os_log("Could not find task associated urlSessionTask %d", log: log,  type: .info, dataTask.taskIdentifier)
            return
        }
        var dataList = BDPlugin.responseBodyData[task.taskId] ?? []
        dataList.append(data)
        BDPlugin.responseBodyData[task.taskId] = dataList
    }
    
    //MARK: URLSessionDelegate
    
    /// When the app restarts, recreate the urlSession if needed, and store the completion handler
    public func application(_ application: UIApplication,
                            handleEventsForBackgroundURLSession identifier: String,
                            completionHandler: @escaping () -> Void) -> Bool {
        if (identifier == UrlSessionDelegate.sessionIdentifier) {
            UrlSessionDelegate.backgroundCompletionHandler = completionHandler
            UrlSessionDelegate.createUrlSession()
            return true
        }
        return false
    }
    
    /// Upon completion of download of all files, call the completion handler
    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            guard
                let handler = UrlSessionDelegate.backgroundCompletionHandler,
                session.configuration.identifier == UrlSessionDelegate.sessionIdentifier
            else {
                os_log("No handler or no identifier match in urlSessionDidFinishEvents", log: log, type: .info)
                return
            }
            handler()
        }
    }
    
    //MARK: Helpers
    
    /// Read the contents of a file to a String, or nil if unable
    private func readFile(url: URL) -> String? {
        do {
            let data = try Data(contentsOf: url)
            let string = String(data: data, encoding: .utf8)
            return string
        } catch {
            return nil
        }
    }
    
    /// Get response body for upload task with this [taskId]
    private func getResponseBody(taskId: String) -> String? {
        guard let dataList = BDPlugin.responseBodyData[taskId] else {
            return nil
        }
        var allData: Data? = nil
        dataList.forEach { data in
            if allData == nil {
                allData = data
            } else {
                allData?.append(data)
            }
        }
        if (allData == nil) {
            return nil
        }
        return String(data: allData!, encoding: .utf8)!
    }
    
    //MARK: UrlSession and related Task helpers
    
    /// Creates a urlSession
    ///
    /// Configues defaultResourceTimeout, defaultRequestTimeout and proxy based on configuration parameters,
    /// or defaults
    static func createUrlSession() -> Void {
        if UrlSessionDelegate.urlSession != nil {
            return
        }
        let config = URLSessionConfiguration.background(withIdentifier: UrlSessionDelegate.sessionIdentifier)
        let defaults = UserDefaults.standard
        let storedTimeoutIntervalForResource = defaults.double(forKey: BDPlugin.keyConfigResourceTimeout) // seconds
        let timeOutIntervalForResource = storedTimeoutIntervalForResource > 0 ? storedTimeoutIntervalForResource : BDPlugin.defaultResourceTimeout
        os_log("timeoutIntervalForResource = %d seconds", log: log, type: .info, Int(timeOutIntervalForResource))
        config.timeoutIntervalForResource = timeOutIntervalForResource
        let storedTimeoutIntervalForRequest = defaults.double(forKey: BDPlugin.keyConfigRequestTimeout) // seconds
        let timeoutIntervalForRequest = storedTimeoutIntervalForRequest > 0 ? storedTimeoutIntervalForRequest : BDPlugin.defaultRequestTimeout
        os_log("timeoutIntervalForRequest = %d seconds", log: log, type: .info, Int(timeoutIntervalForRequest))
        config.timeoutIntervalForRequest = timeoutIntervalForRequest
        let proxyAddress = defaults.string(forKey: BDPlugin.keyConfigProxyAdress)
        let proxyPort = defaults.integer(forKey: BDPlugin.keyConfigProxyPort)
        if (proxyAddress != nil && proxyPort != 0) {
            config.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable: true,
                kCFNetworkProxiesHTTPProxy: proxyAddress!,
                kCFNetworkProxiesHTTPPort: proxyPort,
                "HTTPSEnable": true,
                "HTTPSProxy": proxyAddress!,
                "HTTPSPort": proxyPort
            ]
            os_log("Using proxy %@:%d for all tasks", log: log, type: .info, proxyAddress!, proxyPort)
        } else {
            os_log("Not using proxy for any task", log: log, type: .info)
        }
        UrlSessionDelegate.urlSession = URLSession(configuration: config, delegate: UrlSessionDelegate.instance, delegateQueue: nil)
    }
    
    /// Return all tasks in this urlSession
    static func getAllTasks() async -> [Task] {
        UrlSessionDelegate.createUrlSession()
        guard let urlSessionTasks = await UrlSessionDelegate.urlSession?.allTasks else { return [] }
        return urlSessionTasks.map({ getTaskFrom(urlSessionTask: $0) }).filter({ $0 != nil }) as? [Task] ?? []
    }
    
    /// Return the active task with this taskId, or nil
    static func getTaskWithId(taskId: String) async -> Task? {
        return await getAllTasks().first(where: { $0.taskId == taskId })
    }
    
    /// Return all urlSessionsTasks in this urlSession
    static func getAllUrlSessionTasks(group: String? = nil) async -> [URLSessionTask] {
        UrlSessionDelegate.createUrlSession()
        if (group == nil) {
            guard let urlSessionTasks = await UrlSessionDelegate.urlSession?.allTasks else { return [] }
            return urlSessionTasks
        }
        guard let urlSessionTasks = await UrlSessionDelegate.urlSession?.allTasks else { return [] }
        let urlSessionTasksInGroup = urlSessionTasks.filter({
            guard let task = getTaskFrom(urlSessionTask: $0) else { return false }
            return task.group == group
        })
        return urlSessionTasksInGroup
    }
    
    /// Return the urlSessionTask matching this taskId, or nil
    static func getUrlSessionTaskWithId(taskId: String) async -> URLSessionTask? {
        guard let urlSessionTask = await getAllUrlSessionTasks().first(where: {
            guard let task = getTaskFrom(urlSessionTask: $0) else { return false }
            return task.taskId == taskId
        }) else { return nil }
        return urlSessionTask
    }
}
