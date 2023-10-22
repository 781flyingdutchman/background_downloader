import Flutter
import UIKit
import BackgroundTasks
import os.log
import MobileCoreServices

let log = OSLog.init(subsystem: "BackgroundDownloader", category: "Downloader")

public class Downloader: NSObject, FlutterPlugin, URLSessionDelegate, URLSessionDownloadDelegate, URLSessionDataDelegate, UNUserNotificationCenterDelegate {
    
    static let instance = Downloader()
    
    private static var defaultResourceTimeout = 4 * 60 * 60.0 // in seconds
    private static var defaultRequestTimeout = 60.0 // in seconds
    public static var sessionIdentifier = "com.bbflight.background_downloader.Downloader"
    public static var flutterPluginRegistrantCallback: FlutterPluginRegistrantCallback?
    public static var backgroundChannel: FlutterMethodChannel?
    private static var backgroundCompletionHandler: (() -> Void)?
    private static var urlSession: URLSession?
    public static var keyResumeDataMap = "com.bbflight.background_downloader.resumeDataMap"
    public static var keyStatusUpdateMap = "com.bbflight.background_downloader.statusUpdateMap"
    public static var keyProgressUpdateMap = "com.bbflight.background_downloader.progressUpdateMap"
    public static var keyConfigLocalize = "com.bbflight.background_downloader.config.localize"
    public static var keyConfigResourceTimeout = "com.bbflight.background_downloader.config.resourceTimeout"
    public static var keyConfigRequestTimeout = "com.bbflight.background_downloader.config.requestTimeout"
    public static var keyConfigProxyAdress = "com.bbflight.background_downloader.config.proxyAddress"
    public static var keyConfigProxyPort = "com.bbflight.background_downloader.config.proxyPort"
    public static var keyConfigCheckAvailableSpace = "com.bbflight.background_downloader.config.checkAvailableSpace"
    public static var forceFailPostOnBackgroundChannel = false
        
    static var progressInfo = [String: (lastProgressUpdateTime: TimeInterval,
                                        lastProgressValue: Double,
                                        lastTotalBytesDone: Int64,
                                        lastNetworkSpeed: Double)]() // time, bytes, speed
    static var uploaderForUrlSessionTaskIdentifier = [Int:Uploader]() // maps from UrlSessionTask TaskIdentifier
    static var haveNotificationPermission: Bool?
    static var haveregisteredNotificationCategories = false
    static var taskIdsThatCanResume = Set<String>() // taskIds that can resume
    static var taskIdsProgrammaticallyCancelled = Set<String>() // skips error handling for these tasks
    static var localResumeData = [String : String]() // locally stored to enable notification resume
    static var remainingBytesToDownload = [String : Int64]()  // keyed by taskId
    static var responseBodyData = [String: [Data]]() // list of Data objects received for this UploadTask id
    static var tasksWithSuggestedFilename = [String : Task]() // [taskId : Task with suggested filename]
    static var tasksWithContentLengthOverride = [String : Int64]() // [taskId : Content length]
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "com.bbflight.background_downloader", binaryMessenger: registrar.messenger())
        backgroundChannel = FlutterMethodChannel(name: "com.bbflight.background_downloader.background", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(instance, channel: channel)
        registrar.addApplicationDelegate(instance)
    }
    
    @objc
    public static func setPluginRegistrantCallback(_ callback: @escaping FlutterPluginRegistrantCallback) {
        flutterPluginRegistrantCallback = callback
    }
    
    /// Handler for Flutter plugin method channel calls
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
            case "reset":
                _Concurrency.Task {
                    await methodReset(call: call, result: result)
                }
            case "enqueue":
                methodEnqueue(call: call, result: result)
            case "allTasks":
                _Concurrency.Task {
                    await methodAllTasks(call: call, result: result)
                }
            case "cancelTasksWithIds":
                _Concurrency.Task {
                    await methodCancelTasksWithIds(call: call, result: result)
                }
            case "taskForId":
                _Concurrency.Task {
                    await methodTaskForId(call: call, result: result)
                }
            case "pause":
                _Concurrency.Task {
                    await methodPause(call: call, result: result)
                }
            case "moveToSharedStorage":
                methodMoveToSharedStorage(call: call, result: result)
            case "pathInSharedStorage":
                methodPathInSharedStorage(call: call, result: result)
            case "openFile":
                methodOpenFile(call: call, result: result)
                /// ParallelDownloadTask child updates
            case "chunkStatusUpdate":
                methodUpdateChunkStatus(call: call, result: result)
            case "chunkProgressUpdate":
                methodUpdateChunkProgress(call: call, result: result)
                /// internal use
            case "popResumeData":
                methodPopResumeData(result: result)
            case "popStatusUpdates":
                methodPopStatusUpdates(result: result)
            case "popProgressUpdates":
                methodPopProgressUpdates(result: result)
                /// configuration
            case "configLocalize":
                methodStoreConfig(key: Downloader.keyConfigLocalize, value: call.arguments, result: result)
            case "configResourceTimeout":
                methodStoreConfig(key: Downloader.keyConfigResourceTimeout, value: call.arguments, result: result)
            case "configRequestTimeout":
                methodStoreConfig(key: Downloader.keyConfigRequestTimeout, value: call.arguments, result: result)
            case "configProxyAddress":
                methodStoreConfig(key: Downloader.keyConfigProxyAdress, value: call.arguments, result: result)
            case "configProxyPort":
                methodStoreConfig(key: Downloader.keyConfigProxyPort, value: call.arguments, result: result)
            case "configCheckAvailableSpace":
                methodStoreConfig(key: Downloader.keyConfigCheckAvailableSpace, value: call.arguments, result: result)
            case "forceFailPostOnBackgroundChannel":
                methodForceFailPostOnBackgroundChannel(call: call, result: result)
            case "testSuggestedFilename":
                methodTestSuggestedFilename(call: call, result: result)
            default:
                os_log("Invalid method: %@", log: log, type: .error, call.method)
                result(FlutterMethodNotImplemented)
        }
    }
    
    /// Starts the download for one task, passed as map of values representing a Task
    ///
    /// Returns true if successful, but will emit a status update that the background task is running
    private func methodEnqueue(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as! [Any]
        let taskJsonString = args[0] as! String
        let notificationConfigJsonString = args[1] as? String
        if notificationConfigJsonString != nil  && Downloader.haveNotificationPermission == nil {
            // check (or ask) if we have permission to send notifications
            let center = UNUserNotificationCenter.current()
            center.requestAuthorization(options: [.alert]) { granted, error in
                if let error = error {
                    os_log("Error obtaining notification authorization: %@", log: log, type: .error, error.localizedDescription)
                }
                Downloader.haveNotificationPermission = granted
            }
        }
        let isResume = args.count == 5
        let resumeDataAsBase64String = isResume
            ? args[2] as? String ?? ""
            : ""
        doEnqueue(taskJsonString: taskJsonString, notificationConfigJsonString: notificationConfigJsonString, resumeDataAsBase64String: resumeDataAsBase64String, result: result)
    }
    
    public func doEnqueue(taskJsonString: String, notificationConfigJsonString: String?, resumeDataAsBase64String: String, result: FlutterResult?) {
        let taskDescription = notificationConfigJsonString == nil ? taskJsonString : taskJsonString + separatorString + notificationConfigJsonString!
        var isResume = !resumeDataAsBase64String.isEmpty
        let resumeData = isResume ? Data(base64Encoded: resumeDataAsBase64String) : nil
        guard let task = taskFrom(jsonString: taskJsonString)
        else {
            os_log("Could not decode %@ to Task", log: log, taskJsonString)
            postResult(result: result, value: false)
            return
        }
        isResume = isParallelDownloadTask(task: task) ? isResume : isResume && resumeData != nil
        let verb = isResume ? "Resuming" : "Starting"
        os_log("%@ task with id %@", log: log, type: .info, verb, task.taskId)
        Downloader.urlSession = Downloader.urlSession ?? createUrlSession()
        guard let url = URL(string: task.url) else {
            os_log("Invalid url: %@", log: log, type: .info, task.url)
            postResult(result: result, value: false)
            return
        }
        var baseRequest = URLRequest(url: url)
        baseRequest.httpMethod = task.httpRequestMethod
        for (key, value) in task.headers {
            baseRequest.setValue(value, forHTTPHeaderField: key)
        }
        if task.requiresWiFi {
            baseRequest.allowsCellularAccess = false
        }
        if isParallelDownloadTask(task: task) {
            // ParallelDownloadTask itself is not part of a urlSession, so handled separately
            baseRequest.httpMethod = "HEAD" // override
            scheduleParallelDownload(task: task, taskDescription: taskDescription, baseRequest: baseRequest, resumeData: resumeDataAsBase64String, result: result)
        } else if isDownloadTask(task: task)
        {
            scheduleDownload(task: task, taskDescription: taskDescription, baseRequest: baseRequest, resumeData: resumeData, result: result)
        } else
        {
            DispatchQueue.global().async {
                self.scheduleUpload(task: task, taskDescription: taskDescription, baseRequest: baseRequest, result: result)
            }
        }
    }
    
    /// Schedule a download task
    private func scheduleDownload(task: Task, taskDescription: String, baseRequest: URLRequest, resumeData: Data? , result: FlutterResult?) {
        var request = baseRequest
        if task.post != nil {
            request.httpBody = Data((task.post ?? "").data(using: .utf8)!)
        }
        let urlSessionDownloadTask = resumeData == nil ? Downloader.urlSession!.downloadTask(with: request) : Downloader.urlSession!.downloadTask(withResumeData: resumeData!)
        urlSessionDownloadTask.taskDescription = taskDescription
        urlSessionDownloadTask.priority = 1 - Float(task.priority) / 10
        urlSessionDownloadTask.resume()
        processStatusUpdate(task: task, status: TaskStatus.enqueued)
        postResult(result: result, value: true)
    }
    
    /// Schedule an upload task
    private func scheduleUpload(task: Task, taskDescription: String, baseRequest: URLRequest, result: FlutterResult?) {
        var request = baseRequest
        if isBinaryUploadTask(task: task) {
            os_log("Binary file upload", log: log, type: .debug)
            guard let directory = try? directoryForTask(task: task) else {
                os_log("Could not find directory for taskId %@", log: log, type: .info, task.taskId)
                postResult(result: result, value: false)
                return
            }
            let filePath = directory.appendingPathComponent(task.filename)
            if !FileManager.default.fileExists(atPath: filePath.path) {
                os_log("Could not find file %@ for taskId %@", log: log, type: .info, filePath.absoluteString, task.taskId)
                postResult(result: result, value: false)
                return
            }
            // binary post can use uploadTask fromFile method
            request.setValue("attachment; filename=\"\(task.filename)\"", forHTTPHeaderField: "Content-Disposition")
            let urlSessionUploadTask = Downloader.urlSession!.uploadTask(with: request, fromFile: filePath)
            urlSessionUploadTask.taskDescription = taskDescription
            urlSessionUploadTask.priority = 1 - Float(task.priority) / 10
            urlSessionUploadTask.resume()
        }
        else {
            // multi-part upload via StreamedRequest
            os_log("Multipart file upload", log: log, type: .debug)
            let uploader = Uploader(task: task)
            if !uploader.createMultipartFile() {
                postResult(result: result, value: false)
                return
            }
            request.setValue("multipart/form-data; boundary=\(Uploader.boundary)", forHTTPHeaderField: "Content-Type")
            request.setValue("UTF-8", forHTTPHeaderField: "Accept-Charset")
            request.setValue("Keep-Alive", forHTTPHeaderField: "Connection")
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            let urlSessionUploadTask = Downloader.urlSession!.uploadTask(with: request, fromFile: uploader.outputFileUrl())
            urlSessionUploadTask.taskDescription = taskDescription
            urlSessionUploadTask.priority = Float(task.priority) / 10
            Downloader.uploaderForUrlSessionTaskIdentifier[urlSessionUploadTask.taskIdentifier] = uploader
            urlSessionUploadTask.resume()
        }
        processStatusUpdate(task: task, status: TaskStatus.enqueued)
        postResult(result: result, value: true)
    }
    
    /// Resets the downloadworker by cancelling all ongoing download tasks
    ///
    /// Returns the number of tasks canceled
    private func methodReset(call: FlutterMethodCall, result: @escaping FlutterResult) async {
        let group = call.arguments as! String
        let tasksToCancel = await getAllUrlSessionTasks(group: group)
        tasksToCancel.forEach({$0.cancel()})
        let numTasks = tasksToCancel.count
        os_log("reset removed %d unfinished tasks", log: log, type: .debug, numTasks)
        result(numTasks)
    }
    
    /// Returns a list with all tasks in progress, as a list of JSON strings
    private func methodAllTasks(call: FlutterMethodCall, result: @escaping FlutterResult) async {
        let group = call.arguments as! String
        Downloader.urlSession = Downloader.urlSession ?? createUrlSession()
        guard let urlSessionTasks = await Downloader.urlSession?.allTasks else {
            result(nil)
            return
        }
        let tasksAsListOfJsonStrings = urlSessionTasks.filter({ $0.state == .running || $0.state == .suspended }).map({ getTaskFrom(urlSessionTask: $0)}).filter({ $0?.group == group }).map({ jsonStringFor(task: $0!) }).filter({ $0 != nil }) as? [String] ?? []
        os_log("Returning %d unfinished tasks", log: log, type: .debug, tasksAsListOfJsonStrings.count)
        result(tasksAsListOfJsonStrings)
    }
    
    /// Cancels ongoing tasks whose taskId is in the list provided with this call
    ///
    /// Returns true if all cancellations were successful
    private func methodCancelTasksWithIds(call: FlutterMethodCall, result: @escaping FlutterResult) async {
        let taskIds = call.arguments as! [String]
        os_log("Canceling taskIds %@", log: log, type: .info, taskIds)
        let tasksToCancel = await getAllUrlSessionTasks().filter({
            guard let task = getTaskFrom(urlSessionTask: $0) else { return false }
            return taskIds.contains(task.taskId)
        })
        tasksToCancel.forEach({$0.cancel()})
        // cancel all ParallelDownloadTasks (they would not have shown up in tasksToCancel)
        taskIds.forEach { ParallelDownloader.downloads[$0]?.cancelTask() }
        result(true)
    }
    
    /// Returns Task for this taskId, or nil
    private func methodTaskForId(call: FlutterMethodCall, result: @escaping FlutterResult) async {
        let taskId = call.arguments as! String
        guard let task = await getTaskWithId(taskId: taskId) else {
            result(nil)
            return
        }
        result(jsonStringFor(task: task))
    }
    
    /// Pauses Task for this taskId. Returns true of pause likely successful, false otherwise
    ///
    /// If pause is not successful, task will be canceled (attempted)
    private func methodPause(call: FlutterMethodCall, result: @escaping FlutterResult) async {
        let taskId = call.arguments as! String
        Downloader.urlSession = Downloader.urlSession ?? createUrlSession()
        Downloader.taskIdsProgrammaticallyCancelled.insert(taskId)
        guard let urlSessionTask = await getUrlSessionTaskWithId(taskId: taskId) as? URLSessionDownloadTask,
              let task = await getTaskWithId(taskId: taskId),
              let resumeData = await urlSessionTask.cancelByProducingResumeData()
        else {
            // no regular task found, return if there's no ParalleldownloadTask either
            Downloader.taskIdsProgrammaticallyCancelled.remove(taskId)
            if ParallelDownloader.downloads[taskId] == nil {
                os_log("Could not pause task %@", log: log, type: .info, taskId)
                result(false)
            } else {
                if await ParallelDownloader.downloads[taskId]?.pauseTask() == true {
                    os_log("Paused task with taskId %@", log: log, type: .info, taskId)
                    result(true)
                } else {
                    os_log("Could not pause taskId %@", log: log, type: .info, taskId)
                    result(false)
                }
            }
            return
        }
        if processResumeData(task: task, resumeData: resumeData) {
            processStatusUpdate(task: task, status: .paused)
            os_log("Paused task with taskId %@", log: log, type: .info, taskId)
            result(true)
        } else {
            os_log("Could not post resume data for taskId %@: task paused but cannot be resumed", log: log, type: .info, taskId)
            result(false)
        }
    }
    
    /// Returns a JSON String of a map of [ResumeData], keyed by taskId, that has been stored
    /// in local shared preferences because they could not be delivered to the Dart side.
    /// Local storage of this map is then cleared
    private func methodPopResumeData(result: @escaping FlutterResult) {
        popLocalStorage(key: Downloader.keyResumeDataMap, result: result)
    }
    
    /// Returns a JSON String of a map of status updates, keyed by taskId, that has been stored
    /// in local shared preferences because they could not be delivered to the Dart side.
    /// Local storage of this map is then cleared
    private func methodPopStatusUpdates(result: @escaping FlutterResult) {
        popLocalStorage(key: Downloader.keyStatusUpdateMap, result: result)
    }
    
    /// Returns a JSON String of a map of progress updates, keyed by taskId, that has been stored
    /// in local shared preferences because they could not be delivered to the Dart side.
    /// Local storage of this map is then cleared
    private func methodPopProgressUpdates(result: @escaping FlutterResult) {
        popLocalStorage(key: Downloader.keyProgressUpdateMap, result: result)
    }
    
    /// Pops and returns locally stored map for this key as a JSON String, via the FlutterResult
    private func popLocalStorage(key: String, result: @escaping FlutterResult) {
        let defaults = UserDefaults.standard
        guard let map = defaults.dictionary(forKey: key),
              let jsonData = try? JSONSerialization.data(withJSONObject: map),
              let jsonString = String(data: jsonData, encoding: .utf8)
        else {
            os_log("Could not pop local storage for key %@", log: log, type: .info, key)
            result("{}")
            return
        }
        defaults.removeObject(forKey: key)
        result(jsonString)
        return
    }
    
    /// Moves a file represented by the first argument to a SharedStorage destination
    ///
    /// Results in the new filePath if successful, or nil
    private func methodMoveToSharedStorage(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as! [Any]
        guard
            let filePath = args[0] as? String,
            let destination = SharedStorage.init(rawValue: args[1] as? Int ?? 0),
            let directory = args[2] as? String
        else {
            result(nil)
            return
        }
        result(moveToSharedStorage(filePath: filePath, destination: destination, directory: directory))
    }

    /// Returns path to file in a SharedStorage destination, or null
    private func methodPathInSharedStorage(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as! [Any]
        guard
            let filePath = args[0] as? String,
            let destination = SharedStorage.init(rawValue: args[1] as? Int ?? 0),
            let directory = args[2] as? String
        else {
            result(nil)
            return
        }
        result(pathInSharedStorage(filePath: filePath, destination: destination, directory: directory))
    }

    
    /// Opens to file represented by the Task or filePath using iOS standard
    ///
    /// Results in true if successful
    private func methodOpenFile(call: FlutterMethodCall, result: @escaping FlutterResult) {
        var success = false
        defer {
            result(success)
        }
        let args = call.arguments as! [Any]
        let taskJsonMapString = args[0] as? String
        var filePath = args[1] as? String
        if filePath == nil {
            guard let task = taskFrom(jsonString: taskJsonMapString!)
            else {
                return
            }
            filePath = getFilePath(for: task)
        }
        if !FileManager.default.fileExists(atPath: filePath!) {
            os_log("File does not exist: %@", log: log, type: .info, filePath!)
            return
        }
        let mimeType = args[2] as? String
        success = doOpenFile(filePath: filePath!, mimeType: mimeType)
    }
    
     /// Update the status of one chunk (part of a ParallelDownloadTask), and returns
     /// the status of the parent task based on the 'sum' of its children, or null
     /// if unchanged
     ///
     /// Arguments are the parent TaskId, chunk taskId, taskStatusOrdinal
    private func methodUpdateChunkStatus(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as! [Any]
        guard
            let taskId = args[0] as? String,
            let chunkTaskId = args[1] as? String,
            let statusRawvalue = args[2] as? Int,
            let parallelDownloadTask = ParallelDownloader.downloads[taskId]
        else {
            os_log("Could not process chunkStatusUpdate", log: log, type: .info)
            result(nil)
            return
        }
        let exceptionJson = args[3] as? String
        let exception = exceptionJson != nil ? taskException(jsonString: exceptionJson!) : nil
        let responseBody = args[4] as? String
        parallelDownloadTask.chunkStatusUpdate(chunkTaskId: chunkTaskId, status: TaskStatus.init(rawValue: statusRawvalue)!, taskException: exception, responseBody: responseBody)
        result(nil)
    }
    
    private func methodUpdateChunkProgress(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as! [Any]
        guard
            let taskId = args[0] as? String,
            let chunkTaskId = args[1] as? String,
            let progress = args[2] as? Double,
            let parallelDownloadTask = ParallelDownloader.downloads[taskId]
        else {
            result(nil)
            return
        }
        parallelDownloadTask.chunkProgressUpdate(chunkTaskId: chunkTaskId, progress: progress)
        result(nil)
    }

    
    /// Store or remove a configuration in shared preferences
    ///
    /// If the value is nil, the configuration is removed
    private func methodStoreConfig(key: String, value: Any?, result: @escaping FlutterResult) {
        let defaults = UserDefaults.standard
        if value != nil {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
        result(nil)
    }


    
    /// Sets or resets flag to force failing posting on background channel
    ///
    /// For testing only
    private func methodForceFailPostOnBackgroundChannel(call: FlutterMethodCall, result: @escaping FlutterResult) {
        Downloader.forceFailPostOnBackgroundChannel = call.arguments as! Bool
        result(nil)
    }
    
    /// Tests the content-disposition and url translation
    ///
    /// For testing only
    private func methodTestSuggestedFilename(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as! [Any]
        guard let taskJsonString = args[0] as? String,
              let contentDisposition = args[1] as? String,
              let task = taskFrom(jsonString: taskJsonString) else {
            result("")
            return
        }
        let resultTask = suggestedFilenameFromResponseHeaders(task: task, responseHeaders: ["Content-Disposition" : contentDisposition], unique: true)
        result(resultTask.filename)
    }

    
    
    //MARK: Helpers for Task and urlSessionTask
    
    
    /// Return all tasks in this urlSession
    private func getAllTasks() async -> [Task] {
        Downloader.urlSession = Downloader.urlSession ?? createUrlSession()
        guard let urlSessionTasks = await Downloader.urlSession?.allTasks else { return [] }
        return urlSessionTasks.map({ getTaskFrom(urlSessionTask: $0) }).filter({ $0 != nil }) as? [Task] ?? []
    }
    
    /// Return the active task with this taskId, or nil
    private func getTaskWithId(taskId: String) async -> Task? {
        return await getAllTasks().first(where: { $0.taskId == taskId })
    }
    
    /// Return all urlSessionsTasks in this urlSession
    private func getAllUrlSessionTasks(group: String? = nil) async -> [URLSessionTask] {
        Downloader.urlSession = Downloader.urlSession ?? createUrlSession()
        if (group == nil) {
            guard let urlSessionTasks = await Downloader.urlSession?.allTasks else { return [] }
            return urlSessionTasks
        }
        guard let urlSessionTasks = await Downloader.urlSession?.allTasks else { return [] }
        let urlSessionTasksInGroup = urlSessionTasks.filter({
            guard let task = getTaskFrom(urlSessionTask: $0) else { return false }
            return task.group == group
        })
        return urlSessionTasksInGroup
    }
    
    /// Return the urlSessionTask matching this taskId, or nil
    private func getUrlSessionTaskWithId(taskId: String) async -> URLSessionTask? {
        guard let urlSessionTask = await getAllUrlSessionTasks().first(where: {
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
        let multipartUploader = Downloader.uploaderForUrlSessionTaskIdentifier[task.taskIdentifier]
        if multipartUploader != nil {
            try? FileManager.default.removeItem(at: multipartUploader!.outputFileUrl())
            Downloader.uploaderForUrlSessionTaskIdentifier.removeValue(forKey: task.taskIdentifier)
        }
        let responseStatusCode = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        let responseStatusDescription = HTTPURLResponse.localizedString(forStatusCode: responseStatusCode)
        let notificationConfig = getNotificationConfigFrom(urlSessionTask: task)
        // from here on, task refers to "our" task, not a URLSessionTask
        guard let task = getTaskFrom(urlSessionTask: task) else {
            os_log("Could not find task related to urlSessionTask %d", log: log, type: .error, task.taskIdentifier)
            return
        }
        // clear storage related to this task
        Downloader.tasksWithSuggestedFilename.removeValue(forKey: task.taskId)
        Downloader.tasksWithContentLengthOverride.removeValue(forKey: task.taskId)
        let responseBody = getResponseBody(taskId: task.taskId)
        Downloader.responseBodyData.removeValue(forKey: task.taskId)
        Downloader.taskIdsThatCanResume.remove(task.taskId)
        let taskWasProgramaticallyCanceled: Bool = Downloader.taskIdsProgrammaticallyCancelled.remove(task.taskId) != nil
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
                        Downloader.progressInfo.removeValue(forKey: task.taskId) // ensure .running update on resume
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
        if Downloader.progressInfo[task.taskId] == nil {
            // first 'didWriteData' call
            let response = downloadTask.response as! HTTPURLResponse
            // get suggested filename if needed
            if task.filename == "?" {
                let newTask = suggestedFilenameFromResponseHeaders(task: task, responseHeaders: response.allHeaderFields)
                os_log("Suggested task filename for taskId %@ is %@", log: log, type: .info, newTask.taskId, newTask.filename)
                if newTask.filename != task.filename {
                    // store for future replacement, and replace now
                    Downloader.tasksWithSuggestedFilename[newTask.taskId] = newTask
                    task = newTask
                }
            }
            // obtain content length override, if needed and available
            if totalBytesExpectedToWrite == -1 {
                let contentLength = getContentLength(responseHeaders: response.allHeaderFields, task: task)
                if contentLength != -1 {
                    Downloader.tasksWithContentLengthOverride[task.taskId] = contentLength
                }
            }
            // Check if there is enough space
            if insufficientSpace(contentLength: totalBytesExpectedToWrite) {
                if !Downloader.taskIdsProgrammaticallyCancelled.contains(task.taskId) {
                    os_log("Error for taskId %@: Insufficient space to store the file to be downloaded", log: log, type: .error, task.taskId)
                    processStatusUpdate(task: task, status: .failed, taskException: TaskException(type: .fileSystem, httpResponseCode: -1, description: "Insufficient space to store the file to be downloaded for taskId \(task.taskId)"))
                    Downloader.taskIdsProgrammaticallyCancelled.insert(task.taskId)
                    downloadTask.cancel()
                }
                return
            }
            // Send 'running' status update and check if the task is resumable
            processStatusUpdate(task: task, status: TaskStatus.running)
            processProgressUpdate(task: task, progress: 0.0)
            Downloader.progressInfo[task.taskId] = (lastProgressUpdateTime: 0, lastProgressValue: 0.0, lastTotalBytesDone: 0, lastNetworkSpeed: -1.0)
            if task.allowPause {
                let acceptRangesHeader = (downloadTask.response as? HTTPURLResponse)?.allHeaderFields["Accept-Ranges"]
                let taskCanResume = acceptRangesHeader as? String == "bytes"
                processCanResume(task: task, taskCanResume: taskCanResume)
                if taskCanResume {
                    Downloader.taskIdsThatCanResume.insert(task.taskId)
                }
            }
            // notify if needed
            let notificationConfig = getNotificationConfigFrom(urlSessionTask: downloadTask)
            if (notificationConfig != nil) {
                updateNotification(task: task, notificationType: .running, notificationConfig: notificationConfig)
            }
        }
        let contentLength = totalBytesExpectedToWrite != -1 ? totalBytesExpectedToWrite : Downloader.tasksWithContentLengthOverride[task.taskId] ?? -1
        Downloader.remainingBytesToDownload[task.taskId] = contentLength - totalBytesWritten
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
        if Downloader.progressInfo[taskId] == nil {
            // first call to this method: send 'running' status update
            processStatusUpdate(task: task, status: TaskStatus.running)
            processProgressUpdate(task: task, progress: 0.0)
            Downloader.progressInfo[task.taskId] = (lastProgressUpdateTime: 0, lastProgressValue: 0.0, lastTotalBytesDone: 0, lastNetworkSpeed: -1.0)
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
        Downloader.tasksWithSuggestedFilename.removeValue(forKey: task.taskId)
        Downloader.tasksWithContentLengthOverride.removeValue(forKey: task.taskId)
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
            updateNotification(task: task, notificationType: .error, notificationConfig: notificationConfig)
            return
        }
        do {
            var finalStatus = TaskStatus.failed
            var taskException: TaskException? = nil
            defer {
                processStatusUpdate(task: task, status: finalStatus, taskException: taskException)
                updateNotification(task: task, notificationType: notificationTypeForTaskStatus(status: finalStatus), notificationConfig: notificationConfig)
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
        var dataList = Downloader.responseBodyData[task.taskId] ?? []
        dataList.append(data)
        Downloader.responseBodyData[task.taskId] = dataList
    }
    
    //MARK: URLSessionDelegate
    
    /// When the app restarts, recreate the urlSession if needed, and store the completion handler
    public func application(_ application: UIApplication,
                            handleEventsForBackgroundURLSession identifier: String,
                            completionHandler: @escaping () -> Void) -> Bool {
        if (identifier == Downloader.sessionIdentifier) {
            Downloader.backgroundCompletionHandler = completionHandler
            Downloader.urlSession = Downloader.urlSession ?? createUrlSession()
            return true
        }
        return false
    }
    
    /// Upon completion of download of all files, call the completion handler
    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            guard
                let handler = Downloader.backgroundCompletionHandler,
                session.configuration.identifier == Downloader.sessionIdentifier
            else {
                os_log("No handler or no identifier match in urlSessionDidFinishEvents", log: log, type: .info)
                return
            }
            handler()
        }
    }
    
    //MARK: UNUserNotificationCenterDelegate
    
    @MainActor
    public func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions
    {
        if ourCategories.contains(notification.request.content.categoryIdentifier) {
            if #available(iOS 14.0, *) {
                return UNNotificationPresentationOptions.list
            } else {
                return UNNotificationPresentationOptions.alert
            }
        }
        return []
    }
    
    /// Respond to notification actions (general tap and button taps)
    @MainActor
    public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async
    {
        if ourCategories.contains(response.notification.request.content.categoryIdentifier) {
            // only handle "our" categories, in case another plugin is a notification center delegate
            let userInfo = response.notification.request.content.userInfo
            guard
                let taskAsJsonString = userInfo["task"] as? String,
                let task = taskFrom(jsonString: taskAsJsonString)
            else {
                os_log("No task", log: log, type: .error)
                return
            }
            switch response.actionIdentifier {
            case "pause_action":
                guard let urlSessionTask = await getUrlSessionTaskWithId(taskId: task.taskId) as? URLSessionDownloadTask,
                      let resumeData = await urlSessionTask.cancelByProducingResumeData()
                else {
                    os_log("Could not pause task in response to notification action", log: log, type: .info)
                    return
                }
                _ = processResumeData(task: task, resumeData: resumeData)
                
            case "cancel_action":
                let urlSessionTaskToCancel = await getAllUrlSessionTasks().first(where: {
                    guard let taskInUrlSessionTask = getTaskFrom(urlSessionTask: $0) else { return false }
                    return taskInUrlSessionTask.taskId == task.taskId
                })
                urlSessionTaskToCancel?.cancel()
                
            case "cancel_inactive_action":
                processStatusUpdate(task: task, status: .canceled)
                
            case "resume_action":
                let resumeDataAsBase64String = Downloader.localResumeData[task.taskId] ?? ""
                if resumeDataAsBase64String.isEmpty {
                    os_log("Resume data for taskId %@ no longer available: restarting", log: log, type: .info)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.doEnqueue(taskJsonString: taskAsJsonString, notificationConfigJsonString: userInfo["notificationConfig"] as? String, resumeDataAsBase64String: resumeDataAsBase64String, result: nil)
                }
                
            case UNNotificationDefaultActionIdentifier:
                // general notification tap (no button)
                guard
                    let notificationType = userInfo["notificationType"] as? Int
                else {
                    os_log("No notificationType for notification tap", log: log, type: .info)
                    return
                }
                _ = postOnBackgroundChannel(method: "notificationTap", task: task, arg: notificationType)
                // check 'tapOpensfile'
                if notificationType == NotificationType.complete.rawValue {
                    guard let notificationConfigString = userInfo["notificationConfig"] as? String,
                          let notificationConfigData = notificationConfigString.data(using: .utf8),
                          let notificationConfig = try? JSONDecoder().decode(NotificationConfig.self, from: notificationConfigData),
                          let filePath = getFilePath(for: task)
                    else {
                        os_log("Could not extract filePath for notification tap on .complete", log: log, type: .info)
                        return
                    }
                    if notificationConfig.tapOpensFile {
                        if !doOpenFile(filePath: filePath, mimeType: nil)
                        {
                            os_log("Failed to open file on notification tap", log: log, type: .info)
                        }
                    }
                }
                // dismiss notification if it is a 'complete' or 'error' notification
                if notificationType == NotificationType.complete.rawValue || notificationType == NotificationType.error.rawValue {
                    UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [response.notification.request.identifier])
                }
                
            default:
                do {}
            }
        }
    }
    
    //MARK: helper methods
    
    /// Creates a urlSession
    ///
    /// Configues defaultResourceTimeout, defaultRequestTimeout and proxy based on configuration parameters,
    /// or defaults
    private func createUrlSession() -> URLSession {
        if Downloader.urlSession != nil {
            os_log("createUrlSession called with non-null urlSession", log: log, type: .error)
        }
        let config = URLSessionConfiguration.background(withIdentifier: Downloader.sessionIdentifier)
        let defaults = UserDefaults.standard
        let storedTimeoutIntervalForResource = defaults.double(forKey: Downloader.keyConfigResourceTimeout) // seconds
        let timeOutIntervalForResource = storedTimeoutIntervalForResource > 0 ? storedTimeoutIntervalForResource : Downloader.defaultResourceTimeout
        os_log("timeoutIntervalForResource = %d seconds", log: log, type: .info, Int(timeOutIntervalForResource))
        config.timeoutIntervalForResource = timeOutIntervalForResource
        let storedTimeoutIntervalForRequest = defaults.double(forKey: Downloader.keyConfigRequestTimeout) // seconds
        let timeoutIntervalForRequest = storedTimeoutIntervalForRequest > 0 ? storedTimeoutIntervalForRequest : Downloader.defaultRequestTimeout
        os_log("timeoutIntervalForRequest = %d seconds", log: log, type: .info, Int(timeoutIntervalForRequest))
        config.timeoutIntervalForRequest = timeoutIntervalForRequest
        let proxyAddress = defaults.string(forKey: Downloader.keyConfigProxyAdress)
        let proxyPort = defaults.integer(forKey: Downloader.keyConfigProxyPort)
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
        return URLSession(configuration: config, delegate: Downloader.instance, delegateQueue: nil)
    }
    
    
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
        guard let dataList = Downloader.responseBodyData[taskId] else {
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
}

//MARK: helpers

/// Extension to append a String to a mutable data object
extension NSMutableData {
    func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            self.append(data)
        }
    }
}
