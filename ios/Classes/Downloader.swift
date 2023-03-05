import Flutter
import UIKit
import BackgroundTasks
import os.log
import MobileCoreServices




let log = OSLog.init(subsystem: "FileDownloaderPlugin", category: "Downloader")


public class Downloader: NSObject, FlutterPlugin, FlutterApplicationLifeCycleDelegate, URLSessionDelegate, URLSessionDownloadDelegate {

    private static var resourceTimeout = 4 * 60 * 60.0 // in seconds
    public static var sessionIdentifier = "com.bbflight.background_downloader.Downloader"
    public static var flutterPluginRegistrantCallback: FlutterPluginRegistrantCallback?
    public static var backgroundChannel: FlutterMethodChannel?
    
    private static var backgroundCompletionHandler: (() -> Void)?
    private static var urlSession: URLSession?
    static var nativeToTaskMap  = [String: Task]()
    static var lastProgressUpdate = [String:Double]()
    static var nextProgressUpdateTime = [String:Date]()
    static var uploaderForUrlSessionTaskIdentifier = [Int:Uploader]() // maps from UrlSessionTask TaskIdentifier
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "com.bbflight.background_downloader", binaryMessenger: registrar.messenger())
        backgroundChannel = FlutterMethodChannel(name: "com.bbflight.background_downloader.background", binaryMessenger: registrar.messenger())
        let instance = Downloader()
        registrar.addMethodCallDelegate(instance, channel: channel)
        registrar.addApplicationDelegate(instance)
    }
    
    @objc
    public static func setPluginRegistrantCallback(_ callback: @escaping FlutterPluginRegistrantCallback) {
        flutterPluginRegistrantCallback = callback
    }
    
    /// Handler for Flutter plugin method channel calls
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        os_log("Method call %@", log: log, type: .info, call.method)
        switch call.method {
        case "reset":
            methodReset(call: call, result: result)
        case "enqueue":
            methodEnqueue(call: call, result: result)
        case "allTasks":
            methodAllTasks(call: call, result: result)
        case "cancelTasksWithIds":
            methodCancelTasksWithIds(call: call, result: result)
        case "taskForId":
            methodTaskForId(call: call, result: result)
        case "pause":
            _Concurrency.Task {
                await methodPause(call: call, result: result)
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    
    
    /// Starts the download for one task, passed as map of values representing a Task
    ///
    /// Returns true if successful, but will emit a status update that the background task is running
    private func methodEnqueue(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as! [Any]
        let jsonString = args[0] as! String
        os_log("methodEnqueue with %@", log: log, type: .info, jsonString)
        guard let task = taskFrom(jsonString: jsonString)
        else {
            os_log("Could not decode %@ to Task", log: log, jsonString)
            result(false)
            return
        }
        os_log("Starting task with id %@", log: log, type: .info, task.taskId)
        Downloader.urlSession = Downloader.urlSession ?? createUrlSession()
        var baseRequest = URLRequest(url: URL(string: task.url)!)
        for (key, value) in task.headers {
            baseRequest.setValue(value, forHTTPHeaderField: key)
        }
        if task.requiresWiFi {
            baseRequest.allowsCellularAccess = false
        }
        if isDownloadTask(task: task)
        {
            scheduleDownload(task: task, jsonString: jsonString, baseRequest: baseRequest, result: result)
        } else
        {
            DispatchQueue.global().async {
                self.scheduleUpload(task: task, jsonString: jsonString, baseRequest: baseRequest, result: result)
            }
        }
    }
    
    /// Schedule a download task
    private func scheduleDownload(task: Task, jsonString: String, baseRequest: URLRequest, result: @escaping FlutterResult) {
        var request = baseRequest
        if task.post != nil {
            request.httpMethod = "POST"
            request.httpBody = Data((task.post ?? "").data(using: .utf8)!)
        }
        let urlSessionDownloadTask = Downloader.urlSession!.downloadTask(with: request)
        urlSessionDownloadTask.taskDescription = jsonString
        urlSessionDownloadTask.resume()
        processStatusUpdate(task: task, status: TaskStatus.enqueued)
        result(true)
        return
    }
    
    /// Schedule an upload task
    private func scheduleUpload(task: Task, jsonString: String, baseRequest: URLRequest, result: @escaping FlutterResult) {
        guard let directory = try? directoryForTask(task: task) else {
            os_log("Could not find directory for taskId %@", log: log, type: .info, task.taskId)
            result(false)
            return
        }
        let filePath = directory.appendingPathComponent(task.filename)
        if !FileManager.default.fileExists(atPath: filePath.path) {
            os_log("Could not find file %@ for taskId %@", log: log, type: .info, filePath.absoluteString, task.taskId)
            result(false)
            return
        }
        var request = baseRequest
        request.httpMethod = "POST"
        if task.post?.lowercased() == "binary" {
            os_log("Binary file upload", log: log)
            // binary post can use uploadTask fromFile method
            request.setValue("attachment; filename=\"\(task.filename)\"", forHTTPHeaderField: "Content-Disposition")
            let urlSessionUploadTask = Downloader.urlSession!.uploadTask(with: request, fromFile: filePath)
            urlSessionUploadTask.taskDescription = jsonString
            urlSessionUploadTask.resume()
        }
        else {
            // multi-part upload via StreamedRequest
            os_log("Multipart file upload", log: log)
            let uploader = Uploader(task: task)
            if !uploader.createMultipartFile() {
                result(false)
                return
            }
            request.setValue("multipart/form-data; boundary=\(Uploader.boundary)", forHTTPHeaderField: "Content-Type")
            request.setValue("UTF-8", forHTTPHeaderField: "Accept-Charset")
            request.setValue("Keep-Alive", forHTTPHeaderField: "Connection")
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            let urlSessionUploadTask = Downloader.urlSession!.uploadTask(with: request, fromFile: uploader.outputFileUrl())
            urlSessionUploadTask.taskDescription = jsonString
            Downloader.uploaderForUrlSessionTaskIdentifier[urlSessionUploadTask.taskIdentifier] = uploader
            urlSessionUploadTask.resume()
        }
        processStatusUpdate(task: task, status: TaskStatus.enqueued)
        result(true)
    }
    
    /// Resets the downloadworker by cancelling all ongoing download tasks
    ///
    /// Returns the number of tasks canceled
    private func methodReset(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let group = call.arguments as! String
        Downloader.urlSession = Downloader.urlSession ?? createUrlSession()
        var counter = 0
        Downloader.urlSession?.getAllTasks(completionHandler: { urlSessionTasks in
            for urlSessionTask in urlSessionTasks {
                guard let task = getTaskFrom(urlSessionTask: urlSessionTask)
                else { continue }
                if task.group == group {
                    urlSessionTask.cancel()
                    counter += 1
                }
            }
            os_log("methodReset removed %d unfinished tasks", log: log, type: .info, counter)
            result(counter)
        })
    }
    
    /// Returns a list with all tasks in progress, as a list of JSON strings
    private func methodAllTasks(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let group = call.arguments as! String
        var tasksAsListOfJsonStrings: [String] = []
        Downloader.urlSession = Downloader.urlSession ?? createUrlSession()
        Downloader.urlSession?.getAllTasks(completionHandler: { urlSessionTasks in
            for urlSessionTask in urlSessionTasks {
                guard let task = getTaskFrom(urlSessionTask: urlSessionTask)
                else { continue }
                if task.group == group {
                    if urlSessionTask.state == URLSessionTask.State.running || urlSessionTask.state == URLSessionTask.State.suspended
                    {
                        let taskAsJsonString = jsonStringFor(task: task)
                        if taskAsJsonString != nil {
                            tasksAsListOfJsonStrings.append(taskAsJsonString!)
                        }
                    }
                }
            }
            os_log("Returning %d unfinished tasks", log: log, type: .info, tasksAsListOfJsonStrings.count)
            result(tasksAsListOfJsonStrings)
        })
    }
    
    
    /// Cancels ongoing tasks whose taskId is in the list provided with this call
    ///
    /// Returns true if all cancellations were successful
    private func methodCancelTasksWithIds(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let taskIds = call.arguments as! [String]
        os_log("Canceling taskIds %@", log: log, type: .info, taskIds)
        Downloader.urlSession = Downloader.urlSession ?? createUrlSession()
        Downloader.urlSession?.getAllTasks(completionHandler: { urlSessionTasks in
            for urlSessionTask in urlSessionTasks {
                guard let task = getTaskFrom(urlSessionTask: urlSessionTask)
                else { continue }
                if taskIds.contains(task.taskId)
                {
                    urlSessionTask.cancel() }
            }
            result(true)
        })
    }
    
    /// Returns Task for this taskId, or nil
    private func methodTaskForId(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let taskId = call.arguments as! String
        Downloader.urlSession = Downloader.urlSession ?? createUrlSession()
        Downloader.urlSession?.getAllTasks(completionHandler: { urlSessionTasks in
            for urlSessionTask in urlSessionTasks {
                guard let task = getTaskFrom(urlSessionTask: urlSessionTask)
                else { continue }
                os_log("Found taskId %@", log: log, type: .debug, task.taskId)
                if task.taskId == taskId
                {
                    result(jsonStringFor(task: task))
                    return
                }
            }
            result(nil)
        })
    }

    /// Pauses Task for this taskId, or nil
    private func methodPause(call: FlutterMethodCall, result: @escaping FlutterResult) async {
        let taskId = call.arguments as! String
        Downloader.urlSession = Downloader.urlSession ?? createUrlSession()
        guard let urlSessionTask = await getUrlSessionTaskWithId(taskId: taskId) as? URLSessionDownloadTask,
              let task = await getTaskWithId(taskId: taskId),
              let resumeData = await urlSessionTask.cancelByProducingResumeData()
        else {
            os_log("Something is nil", log: log, type: .info)
            result(false)
            return
        }
        result(processResumeData(task: task, resumeData: resumeData))
    }
    
    
    /// Return the active task with this taskId, or nil
    private func getTaskWithId(taskId: String) async -> Task? {
        Downloader.urlSession = Downloader.urlSession ?? createUrlSession()
        let urlSessionTasks = await Downloader.urlSession?.allTasks
        guard let task = urlSessionTasks?.map({ getTaskFrom(urlSessionTask: $0) }).first(where: { $0?.taskId == taskId }) else { return nil }
        return task
    }
    
    /// Return the urlSessionTask matching this taskId, or nil
    private func getUrlSessionTaskWithId(taskId: String) async -> URLSessionTask? {
        Downloader.urlSession = Downloader.urlSession ?? createUrlSession()
        let urlSessionTasks = await Downloader.urlSession?.allTasks
        guard let urlSessionTask = urlSessionTasks?.first(where: {
            guard let task = getTaskFrom(urlSessionTask: $0) else { return false }
            return task.taskId == taskId
        }) else { return nil }
        return urlSessionTask
    }

    
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
        os_log("Completed task with urlSessionTaskIdentifier %d", log: log, type: .error, task.taskIdentifier)
        let multipartUploader = Downloader.uploaderForUrlSessionTaskIdentifier[task.taskIdentifier]
        if multipartUploader != nil {
            try? FileManager.default.removeItem(at: multipartUploader!.outputFileUrl())
            Downloader.uploaderForUrlSessionTaskIdentifier.removeValue(forKey: task.taskIdentifier)
        }
        let statusCode = (task.response as! HTTPURLResponse?)?.statusCode ?? 0
        guard let task = getTaskFrom(urlSessionTask: task) else {
            os_log("Could not find task related to urlSessionTask %d", log: log, type: .error, task.taskIdentifier)
            return
        }
        guard error == nil else {
            os_log("Completed task with error %@", log: log, type: .error, error.debugDescription)
            let userInfo = (error! as NSError).userInfo
                if let resumeData = userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                    if processResumeData(task: task, resumeData: resumeData) {
                        processStatusUpdate(task: task, status: .paused)
                        return
                    }
                }
            if error!.localizedDescription.contains("cancelled") {
                os_log("Description contains canceled", log: log, type: .error)
                processStatusUpdate(task: task, status: .canceled)
            }
            else {
                os_log("Error for taskId %@: %@", log: log, type: .error, task.taskId, error!.localizedDescription)
                processStatusUpdate(task: task, status: .failed)
            }
            return
        }
        // if this is an upload task, send final TaskStatus (based on HTTP status code
        if isUploadTask(task: task) {
            let finalStatus = (200...206).contains(statusCode)
                ? TaskStatus.complete
                : statusCode == 404
                    ? TaskStatus.notFound
                    : TaskStatus.failed
            processStatusUpdate(task: task, status: finalStatus)
        }
    }
    
    //MARK: URLSessionDownloadTaskDelegate

    /// Process taskdelegate progress update for download task
    ///
    /// If the task requires progress updates, provide these at a reasonable interval
    /// If this is the first update for this file, also emit a 'running' status update
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let task = getTaskFrom(urlSessionTask: downloadTask) else {return}
        if Downloader.lastProgressUpdate[task.taskId] == nil {
            // first 'didWriteData' call, so send 'running' status update
            // and check if the task is resumable
            processStatusUpdate(task: task, status: TaskStatus.running)
            processProgressUpdate(task: task, progress: 0.0)
            Downloader.lastProgressUpdate[task.taskId] = 0.0
            if task.allowPause {
                let acceptRangesHeader = (downloadTask.response as! HTTPURLResponse?)?.allHeaderFields["Accept-Ranges"]
                let taskCanResume = acceptRangesHeader as? String == "bytes"
                os_log( "taskCanresume = %d", log: log,  type: .info, taskCanResume)
                processCanResume(task: task, taskCanResume: taskCanResume)
            }
        }
        if totalBytesExpectedToWrite != NSURLSessionTransferSizeUnknown && Date() > Downloader.nextProgressUpdateTime[task.taskId] ?? Date(timeIntervalSince1970: 0) {
            let progress = min(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 0.999)
            if progress - (Downloader.lastProgressUpdate[task.taskId] ?? 0.0) > 0.02 {
                processProgressUpdate(task: task, progress: progress)
                Downloader.lastProgressUpdate[task.taskId] = progress
                Downloader.nextProgressUpdateTime[task.taskId] = Date().addingTimeInterval(0.5)
            }
        }
    }
    
    /// Process taskdelegate progress update for upload task
    ///
    /// If the task requires progress updates, provide these at a reasonable interval
    /// If this is the first update for this file, also emit a 'running' status update
    public func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        let urlSessionTask = task
        guard let task = getTaskFrom(urlSessionTask: task) else {return}
        let taskId = task.taskId
        if Downloader.lastProgressUpdate[taskId] == nil {
            // first call to this method: send 'running' status update
            processStatusUpdate(task: task, status: TaskStatus.running)
            processProgressUpdate(task: task, progress: 0.0)
            Downloader.lastProgressUpdate[taskId] = 0.0
        }
        if totalBytesExpectedToSend != NSURLSessionTransferSizeUnknown && Date() > Downloader.nextProgressUpdateTime[taskId] ?? Date(timeIntervalSince1970: 0) {
            let progress = min(Double(totalBytesSent) / Double(totalBytesExpectedToSend), 0.999)
            if progress - (Downloader.lastProgressUpdate[taskId] ?? 0.0) > 0.02 {
                processProgressUpdate(task: task, progress: progress)
                Downloader.lastProgressUpdate[taskId] = progress
                Downloader.nextProgressUpdateTime[taskId] = Date().addingTimeInterval(0.5)
            }
        }
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
            os_log("Could not find task associated with native id %d, or did not get HttpResponse", log: log,  type: .info, downloadTask.taskIdentifier)
            return}
        if response.statusCode == 404 {
            processStatusUpdate(task: task, status: TaskStatus.notFound)
            return
        }
        if !(200...206).contains(response.statusCode)   {
            os_log("TaskId %@ returned response code %d", log: log,  type: .info, task.taskId, response.statusCode)
            processStatusUpdate(task: task, status: TaskStatus.failed)
            return
        }
        do {
            var finalStatus = TaskStatus.failed
            defer {
                processStatusUpdate(task: task, status: finalStatus)
            }
            let directory = try directoryForTask(task: task)
            do
            {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories:  true)
            } catch {
                os_log("Failed to create directory %@", log: log, type: .error, directory.path)
                return
            }
            let filePath = directory.appendingPathComponent(task.filename)
            os_log("Moving file to %@", log: log, type: .error, filePath.absoluteString) //TODO remove
            if FileManager.default.fileExists(atPath: filePath.path) {
                try? FileManager.default.removeItem(at: filePath)
            }
            do {
                try FileManager.default.moveItem(at: location, to: filePath)
            } catch {
                os_log("Failed to move file from %@ to %@: %@", log: log, type: .error, location.path, filePath.path, error.localizedDescription)
                return
            }
            finalStatus = TaskStatus.complete
        } catch {
            os_log("File download error for taskId %@ and file %@: %@", log: log, type: .error, task.taskId, task.filename, error.localizedDescription)
        }
    }
    

    //MARK: URLSessionDelegate
        
    
    /// When the app restarts, recreate the urlSession if needed, and store the completion handler
    public func application(_ application: UIApplication,
                            handleEventsForBackgroundURLSession identifier: String,
                            completionHandler: @escaping () -> Void) -> Bool {
        os_log("In handleEventsForBackgroundURLSession with identifier %@", log: log, type: .debug, identifier)
        if (identifier == Downloader.sessionIdentifier) {
            Downloader.backgroundCompletionHandler = completionHandler
            Downloader.urlSession = Downloader.urlSession ?? createUrlSession()
            return true
        }
        return false
    }
    
    /// Upon completion of download of all files, call the completion handler
    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        os_log("In urlSessionDidFinishEvents, calling completionHandler", log: log, type: .debug)
        DispatchQueue.main.async {
            guard
                let handler = Downloader.backgroundCompletionHandler,
                session.configuration.identifier == Downloader.sessionIdentifier
            else {
                os_log("No handler or no identifier match", log: log, type: .info)
                return
            }
            handler()
        }
    }
    
    //MARK: helper methods
    
    /// Creates a urlSession
    private func createUrlSession() -> URLSession {
        os_log("Creating URLSession", log: log, type: .info)
        if Downloader.urlSession != nil {
            os_log("createUrlSession called with non-null urlSession", log: log, type: .info)
        }
        let config = URLSessionConfiguration.background(withIdentifier: Downloader.sessionIdentifier)
        config.timeoutIntervalForResource = Downloader.resourceTimeout
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }


}

//MARK: helpers

/// Return MIME type for this filename url
func mimeType(url: URL) -> String {
    let pathExtension = url.pathExtension
    if let uti = UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, pathExtension as NSString, nil)?.takeRetainedValue() {
            if let mimetype = UTTypeCopyPreferredTagWithClass(uti, kUTTagClassMIMEType)?.takeRetainedValue() {
                return mimetype as String
            }
        }
        return "application/octet-stream"
}

/// Extension to append a String to a mutable data object
extension NSMutableData {
  func append(_ string: String) {
    if let data = string.data(using: .utf8) {
      self.append(data)
    }
  }
}


