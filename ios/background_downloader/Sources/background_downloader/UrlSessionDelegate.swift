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
    public static var backgroundCompletionHandler: (() -> Void)?
    
    //MARK: URLSessionTaskDelegate
    
    public func urlSession(_ session: URLSession, task: URLSessionTask, willBeginDelayedRequest request: URLRequest) async -> (URLSession.DelayedRequestDisposition, URLRequest?) {
        guard let bgdTask = getTaskFrom(urlSessionTask: task),
              bgdTask.options?.hasStartCallback() == true || bgdTask.options?.auth?.hasOnAuthCallback() == true
        else {
            return (.continueLoading, nil)
        }
        let (newTask, taskWasModified) = await getModifiedTask(task: bgdTask)
        if !taskWasModified {
            return (.continueLoading, nil)
        }
        // modify the request, copying the unmodified data from the original request
        guard let url = validateUrl(newTask)
        else {
            os_log("Invalid url in modified task", log: log, type: .info)
            return (.continueLoading, nil)
        }
        var newRequest = URLRequest(url: url)
        // all original request headers are copied, then the newTask headers are set:
        // you can change or add a header, but not remove one
        if request.allHTTPHeaderFields != nil {
            for (key, value) in request.allHTTPHeaderFields! {
                newRequest.setValue(value, forHTTPHeaderField: key)
            }}
        for (key, value) in newTask.headers {
            newRequest.setValue(value, forHTTPHeaderField: key)
        }
        newRequest.httpMethod = request.httpMethod
        newRequest.httpBody = request.httpBody
        newRequest.allowsCellularAccess = request.allowsCellularAccess
        return (URLSession.DelayedRequestDisposition.useNewRequest, newRequest)
    }
    
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
        let responseHeaders = (task.response as? HTTPURLResponse)?.allHeaderFields
        let notificationConfig = getNotificationConfigFrom(urlSessionTask: task)
        // from here on, task refers to "our" task, not a URLSessionTask
        guard let task = getTaskFrom(urlSessionTask: task) else {
            os_log("Could not find task related to urlSessionTask %d", log: log, type: .error, task.taskIdentifier)
            return
        }
        if let tempUploadUrl = BDPlugin.propertyLock.withLock({ BDPlugin.tasksWithTempUploadFile.removeValue(forKey: task.taskId) }) {
            try? FileManager.default.removeItem(at: tempUploadUrl)
        }
        if BDPlugin.holdingQueue != nil {
            _Concurrency.Task {
                await BDPlugin.holdingQueue?.taskFinished(task)
            }
        }
        let responseBody = getResponseBody(taskId: task.taskId)
        let taskWasProgramaticallyCanceled = BDPlugin.propertyLock.withLock( {
            BDPlugin.taskIdsProgrammaticallyCancelled.remove(task.taskId) != nil
        })
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
                        BDPlugin.propertyLock.withLock({
                            _ = BDPlugin.progressInfo.removeValue(forKey: task.taskId) // ensure .running update on resume
                        })
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
        // if this is an upload task, send final TaskStatus (based on HTTP status code).
        // for download tasks, this is done in urlSession(downloadTask:, didFinishDownloadingTo:)
        if isUploadTask(task: task) {
            let taskException = TaskException(type: .httpResponse, httpResponseCode: responseStatusCode, description: responseStatusDescription)
            let finalStatus = (200...206).contains(responseStatusCode)
            ? TaskStatus.complete
            : responseStatusCode == 404
            ? TaskStatus.notFound
            : TaskStatus.failed
            processStatusUpdate(task: task, status: finalStatus, taskException: taskException, responseBody: responseBody, responseHeaders: responseHeaders, responseStatusCode: responseStatusCode)
        }
    }
    
    //MARK: URLSessionDownloadTaskDelegate
    
    
    
    /// Process taskdelegate progress update for download task
    ///
    /// If the task requires progress updates, provides these at a reasonable interval
    /// If this is the first update for this file, also emits a 'running' status update
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        // task is var because the filename can be changed on the first 'didWriteData' call
        guard var task = getTaskFrom(urlSessionTask: downloadTask) else { return }
        let progressInfo = BDPlugin.propertyLock.withLock({
            BDPlugin.progressInfo[task.taskId]
        })
        if progressInfo == nil {
            // first 'didWriteData' call
            os_log("Starting/resuming taskId %@", log: log, type: .info, task.taskId)
            let response = downloadTask.response as! HTTPURLResponse
            // get suggested filename if needed
            if task.filename == "?" {
                let newTask = suggestedFilenameFromResponseHeaders(task: task, responseHeaders: response.allHeaderFields)
                os_log("Suggested task filename for taskId %@ is %@", log: log, type: .info, newTask.taskId, newTask.filename)
                if newTask.filename != task.filename {
                    // store for future replacement, and replace now
                    BDPlugin.propertyLock.withLock({
                        BDPlugin.tasksWithSuggestedFilename[newTask.taskId] = newTask
                    })
                    task = newTask
                }
            }
            extractContentType(responseHeaders: response.allHeaderFields, task: task)
            // obtain content length override, if needed and available
            if totalBytesExpectedToWrite == -1 {
                let contentLength = getContentLength(responseHeaders: response.allHeaderFields, task: task)
                if contentLength != -1 {
                    BDPlugin.propertyLock.withLock({
                        BDPlugin.tasksWithContentLengthOverride[task.taskId] = contentLength
                    })
                }
            }
            // Check if there is enough space
            if insufficientSpace(contentLength: totalBytesExpectedToWrite) {
                let notProgrammaticallyCancelled = BDPlugin.propertyLock.withLock({
                    !BDPlugin.taskIdsProgrammaticallyCancelled.contains(task.taskId)
                })
                if notProgrammaticallyCancelled {
                    os_log("Error for taskId %@: Insufficient space to store the file to be downloaded", log: log, type: .error, task.taskId)
                    processStatusUpdate(task: task, status: .failed, taskException: TaskException(type: .fileSystem, httpResponseCode: -1, description: "Insufficient space to store the file to be downloaded for taskId \(task.taskId)"))
                    BDPlugin.propertyLock.withLock({
                        _ = BDPlugin.taskIdsProgrammaticallyCancelled.insert(task.taskId)
                    })
                    downloadTask.cancel()
                }
                return
            }
            // Send 'running' status update and check if the task is resumable
            processStatusUpdate(task: task, status: TaskStatus.running)
            processProgressUpdate(task: task, progress: 0.0)
            BDPlugin.propertyLock.withLock({
                BDPlugin.progressInfo[task.taskId] = (lastProgressUpdateTime: 0, lastProgressValue: 0.0, lastTotalBytesDone: 0, lastNetworkSpeed: -1.0)
            })
            if task.allowPause {
                let acceptRangesHeader = (downloadTask.response as? HTTPURLResponse)?.allHeaderFields["Accept-Ranges"]
                let taskCanResume = acceptRangesHeader as? String == "bytes"
                processCanResume(task: task, taskCanResume: taskCanResume)
                if taskCanResume {
                    BDPlugin.propertyLock.withLock({
                        _ = BDPlugin.taskIdsThatCanResume.insert(task.taskId)
                    })
                }
            }
            // notify if needed
            let notificationConfig = getNotificationConfigFrom(urlSessionTask: downloadTask)
            if (notificationConfig != nil) {
                updateNotification(task: task, notificationType: .running, notificationConfig: notificationConfig)
            }
        }
        let contentLength = BDPlugin.propertyLock.withLock({
            let l = totalBytesExpectedToWrite != -1 ? totalBytesExpectedToWrite : BDPlugin.tasksWithContentLengthOverride[task.taskId] ?? -1
            BDPlugin.remainingBytesToDownload[task.taskId] = l - totalBytesWritten
            return l
        })
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
        let progressInfo = BDPlugin.propertyLock.withLock({
            return BDPlugin.progressInfo[taskId]
        })
        if progressInfo == nil {
            // first call to this method: send 'running' status update
            processStatusUpdate(task: task, status: TaskStatus.running)
            processProgressUpdate(task: task, progress: 0.0)
            BDPlugin.propertyLock.withLock({
                BDPlugin.progressInfo[task.taskId] = (lastProgressUpdateTime: 0, lastProgressValue: 0.0, lastTotalBytesDone: 0, lastNetworkSpeed: -1.0)
            })
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
        let responseHeaders = response.allHeaderFields
        let taskId = task.taskId
        let (mimeType, charSet) = BDPlugin.propertyLock.withLock({
            let mimeType = BDPlugin.mimeTypes.removeValue(forKey: taskId)
            let charSet = BDPlugin.charSets.removeValue(forKey: taskId)
            BDPlugin.tasksWithSuggestedFilename.removeValue(forKey: taskId)
            BDPlugin.tasksWithContentLengthOverride.removeValue(forKey: taskId)
            return (mimeType, charSet)
        })
        let notificationConfig = getNotificationConfigFrom(urlSessionTask: downloadTask)
        if response.statusCode == 404 {
            let responseBody = readFile(url: location)
            processStatusUpdate(task: task, status: TaskStatus.notFound, responseBody: responseBody, responseHeaders: responseHeaders, responseStatusCode: response.statusCode)
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
            var responseBody: String? = nil
            defer {
                processStatusUpdate(task: task, 
                                    status: finalStatus,
                                    taskException: taskException,
                                    responseBody: responseBody,
                                    responseHeaders: responseHeaders,
                                    responseStatusCode: response.statusCode,
                                    mimeType: mimeType,
                                    charSet: charSet)
                if finalStatus != TaskStatus.failed || task.retriesRemaining == 0 {
                    // update notification only if not failed, or no retries remaining
                    updateNotification(task: task, notificationType: notificationTypeForTaskStatus(status: finalStatus), notificationConfig: notificationConfig)
                }
            }
            if (isDownloadTask(task: task)) {
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
                var fileUrl = directory.appendingPath(task.filename)
                if FileManager.default.fileExists(atPath: fileUrl.path) {
                    try? FileManager.default.removeItem(at: fileUrl)
                }
                do {
                    try FileManager.default.moveItem(at: location, to: fileUrl)
                } catch {
                    os_log("Failed to move file from %@ to %@: %@", log: log, type: .error, location.path, fileUrl.path, error.localizedDescription)
                    taskException = TaskException(type: .fileSystem, httpResponseCode: -1,
                                                  description: "Failed to move file from \(location.path) to \(fileUrl.path): \(error.localizedDescription)")
                    return
                }
                do {
                    if UserDefaults.standard.bool(forKey: BDPlugin.keyConfigExcludeFromCloudBackup)
                    {
                        try fileUrl.setCloudBackup(exclude: true)
                        os_log("Excluded from iCloud backup: %@", log: log, type: .info, fileUrl.path)
                    }
                } catch {
                    os_log("Could not exclude from iCloud backup: %@ - %@", log: log, type: .info, fileUrl.path, error.localizedDescription)
                }
                finalStatus = TaskStatus.complete
            } else {
                // this is a DataTask, so we read the file as the responseBody
                responseBody = readFile(url: location)
                try? FileManager.default.removeItem(at: location);
                finalStatus = .complete
            }
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
        BDPlugin.propertyLock.withLock({
            var dataList = BDPlugin.responseBodyData[task.taskId] ?? []
            dataList.append(data)
            BDPlugin.responseBodyData[task.taskId] = dataList
        })
    }
    
    //MARK: URLSessionDelegate
    
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
        guard let dataList = BDPlugin.propertyLock.withLock( { BDPlugin.responseBodyData[taskId] }) else {
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
    /// Configures defaultResourceTimeout, defaultRequestTimeout and proxy based on configuration parameters,
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

    /// Returns a `task` that may be modified through callbacks, and a bool to indicate that the task was modified.
    ///
    /// Callbacks would be attached to the task via its `Task.options` property, and if
    /// present will be invoked by starting a taskDispatcher on a background isolate, then
    /// sending the callback request via the MethodChannel.
    ///
    /// First test is for auth refresh (the onAuth callback), then the onStart callback. Both
    /// callbacks run in a Dart isolate, and may return a modified task, which will be used
    /// for the actual task execution.
    func getModifiedTask(task: Task) async -> (Task, Bool) {
        var authTask: Task?
        var taskWasModified: Bool = false
        if let auth = task.options?.auth {
            // Refresh token if needed
            if auth.isTokenExpired() && auth.hasOnAuthCallback() == true {
                os_log("onAuth callback for taskId %@", log: log, type: .info, task.taskId)
                authTask = await invokeOnAuthCallback(task: task)
            }
            taskWasModified = authTask != nil
            authTask = authTask ?? task // Either original or newly authorized
            guard let newAuth = authTask?.options?.auth else { return (authTask ?? task, taskWasModified) }
            // Insert query parameters and headers
            taskWasModified = true
            let uri = newAuth.addOrUpdateQueryParams(
                url: authTask!.url,
                queryParams: newAuth.getExpandedAccessQueryParams()
            )
            var headers = authTask!.headers
            headers.merge(newAuth.getExpandedAccessHeaders()) { (_, new) in new }
            authTask = authTask!.copyWith(url: uri.absoluteString, headers: headers)
        }
        authTask = authTask ?? task
        guard task.options?.hasStartCallback() == true else { return (authTask!, taskWasModified) }
        // onStart callback
        os_log("onTaskStart callback for taskId %@", log: log, type: .info, authTask!.taskId)
        let modifiedTask = await invokeOnTaskStartCallback(task: authTask!)
        taskWasModified = taskWasModified || modifiedTask != nil
        return (modifiedTask ?? authTask!, taskWasModified)
    }
}
