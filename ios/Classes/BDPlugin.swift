import Flutter
import UIKit
import BackgroundTasks
import os.log
import MobileCoreServices

let log = OSLog.init(subsystem: "BackgroundDownloader", category: "Downloader")

/// Main Downloader plugin object, handles incoming methodCalls
public class BDPlugin: NSObject, FlutterPlugin, UNUserNotificationCenterDelegate {
    
    static let instance = BDPlugin()
    
    public static var defaultResourceTimeout = 4 * 60 * 60.0 // in seconds
    public static var defaultRequestTimeout = 60.0 // in seconds
    public static var keyResumeDataMap = "com.bbflight.background_downloader.resumeDataMap.v2"
    public static var keyStatusUpdateMap = "com.bbflight.background_downloader.statusUpdateMap.v2"
    public static var keyProgressUpdateMap = "com.bbflight.background_downloader.progressUpdateMap.v2"
    public static var keyConfigLocalize = "com.bbflight.background_downloader.config.localize"
    public static var keyConfigResourceTimeout = "com.bbflight.background_downloader.config.resourceTimeout"
    public static var keyConfigRequestTimeout = "com.bbflight.background_downloader.config.requestTimeout"
    public static var keyConfigProxyAdress = "com.bbflight.background_downloader.config.proxyAddress"
    public static var keyConfigProxyPort = "com.bbflight.background_downloader.config.proxyPort"
    public static var keyConfigCheckAvailableSpace = "com.bbflight.background_downloader.config.checkAvailableSpace"
    public static var keyConfigExcludeFromCloudBackup = "com.bbflight.background_downloader.config.excludeFromCloudBackup"
    public static var keyRequireWiFi = "com.bbflight.background_downloader.requireWiFi"
    public static var forceFailPostOnBackgroundChannel = false
    
    static var progressInfo = [String: (lastProgressUpdateTime: TimeInterval,
                                        lastProgressValue: Double,
                                        lastTotalBytesDone: Int64,
                                        lastNetworkSpeed: Double)]() // time, bytes, speed
    static var uploaderForUrlSessionTaskIdentifier = [Int:Uploader]() // maps from UrlSessionTask TaskIdentifier
    static var haveregisteredNotificationCategories = false
    static var requireWiFi = RequireWiFi.asSetByTask // global setting
    static var taskIdsThatCanResume = Set<String>() // taskIds that can resume
    static var taskIdsProgrammaticallyCancelled = Set<String>() // skips error handling for these tasks
    static var tasksToReEnqueue = Set<Task>() // for when WiFi requirement changes
    static var taskIdsRequiringWiFi = Set<String>() // ensures correctness when enqueueing task
    static var notificationConfigJsonStrings = [String:String]() // by taskId
    static var localResumeData = [String : String]() // locally stored to enable notification resume
    static var remainingBytesToDownload = [String : Int64]()  // keyed by taskId
    static var responseBodyData = [String: [Data]]() // list of Data objects received for this UploadTask id
    static var tasksWithSuggestedFilename = [String : Task]() // [taskId : Task with suggested filename]
    static var tasksWithContentLengthOverride = [String : Int64]() // [taskId : Content length]
    static var tasksWithTempUploadFile = [String : URL]() // [taskId : file URL]
    static var mimeTypes = [String : String]() // [taskId : mimeType]
    static var charSets = [String : String]() // [taskId : charSet]
    static var holdingQueue: HoldingQueue? = nil
    
    static var propertyLock: NSLock = NSLock() // used to synchronize access to static properties
    
    public static var backgroundChannel: FlutterMethodChannel? // for native <-> plugin comms
    public static var callbackChannel: FlutterMethodChannel? // for native to trigger task callbacks
    public static var flutterPluginRegistrantCallback: FlutterPluginRegistrantCallback?
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "com.bbflight.background_downloader", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(instance, channel: channel)
        let callbackChannel = FlutterMethodChannel(name: "com.bbflight.background_downloader.callbacks", binaryMessenger: registrar.messenger())
        registrar.addApplicationDelegate(instance)
        if (backgroundChannel == nil) {
            // This nil check fixes dead locking when used from multiple isolates
            // by only tracking the primary isolate. This should in theory always
            // be the Flutter main isolate.
            // For full feature parity with Android see #382
            backgroundChannel = FlutterMethodChannel(name: "com.bbflight.background_downloader.background", binaryMessenger: registrar.messenger())
            BDPlugin.callbackChannel = callbackChannel
        }
        requireWiFi = RequireWiFi(rawValue: UserDefaults.standard.integer(forKey: BDPlugin.keyRequireWiFi))!
    }
    
    @objc
    public static func setPluginRegistrantCallback(_ callback: @escaping FlutterPluginRegistrantCallback) {
        flutterPluginRegistrantCallback = callback
    }
    
    
    /// Handler for Flutter plugin method channel calls
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        _Concurrency.Task { @MainActor () -> Void in
            // to allow async/await
            switch call.method {
                case "reset":
                    await methodReset(call: call, result: result)
                case "enqueue":
                    await methodEnqueue(call: call, result: result)
                case "allTasks":
                    await methodAllTasks(call: call, result: result)
                case "cancelTasksWithIds":
                    await methodCancelTasksWithIds(call: call, result: result)
                case "taskForId":
                    await methodTaskForId(call: call, result: result)
                case "pause":
                    await methodPause(call: call, result: result)
                case "updateNotification":
                    methodUpdateNotification(call: call, result: result)
                case "moveToSharedStorage":
                    await methodMoveToSharedStorage(call: call, result: result)
                case "pathInSharedStorage":
                    await methodPathInSharedStorage(call: call, result: result)
                case "openFile":
                    methodOpenFile(call: call, result: result)
                case "requireWiFi":
                    methodRequireWiFi(call: call, result: result)
                case "getRequireWiFiSetting":
                    methodGetRequireWiFiSetting(result: result)
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
                    /// Permissions
                case "permissionStatus":
                    await methodPermissionStatus(call: call, result: result)
                case "requestPermission":
                    await methodRequestPermission(call: call, result: result)
                    /// configuration
                case "configLocalize":
                    storeInUserDefaults(key: BDPlugin.keyConfigLocalize, value: call.arguments, result: result)
                case "configResourceTimeout":
                    storeInUserDefaults(key: BDPlugin.keyConfigResourceTimeout, value: call.arguments, result: result)
                case "configRequestTimeout":
                    storeInUserDefaults(key: BDPlugin.keyConfigRequestTimeout, value: call.arguments, result: result)
                case "configProxyAddress":
                    storeInUserDefaults(key: BDPlugin.keyConfigProxyAdress, value: call.arguments, result: result)
                case "configProxyPort":
                    storeInUserDefaults(key: BDPlugin.keyConfigProxyPort, value: call.arguments, result: result)
                case "configCheckAvailableSpace":
                    storeInUserDefaults(key: BDPlugin.keyConfigCheckAvailableSpace, value: call.arguments, result: result)
                case "configHoldingQueue":
                    methodConfigHoldingQueue(call: call, result: result)
                case "configExcludeFromCloudBackup":
                storeInUserDefaults(key: BDPlugin.keyConfigExcludeFromCloudBackup, value: call.arguments, result: result)
                case "platformVersion":
                    result(UIDevice.current.systemVersion)
                case "forceFailPostOnBackgroundChannel":
                    methodForceFailPostOnBackgroundChannel(call: call, result: result)
                case "testSuggestedFilename":
                    methodTestSuggestedFilename(call: call, result: result)
                default:
                    os_log("Invalid method: %@", log: log, type: .error, call.method)
                    result(FlutterMethodNotImplemented)
            }
        }
    }
    
    /// Starts the download for one task, passed as map of values representing a Task
    ///
    /// Returns true if successful, but will emit a status update that the background task is running
    private func methodEnqueue(call: FlutterMethodCall, result: @escaping FlutterResult) async {
        let args = call.arguments as! [Any]
        let taskJsonString = args[0] as! String
        let notificationConfigJsonString = args[1] as? String
        let isResume = args.count == 5
        let resumeDataAsBase64String = isResume
        ? args[2] as? String ?? ""
        : ""
        if BDPlugin.holdingQueue == nil {
            postResult(result: result, value: await doEnqueue(taskJsonString: taskJsonString, notificationConfigJsonString: notificationConfigJsonString, resumeDataAsBase64String: resumeDataAsBase64String))
        } else {
            // add entry for HoldingQueue, after checks
            guard let task = taskFrom(jsonString: taskJsonString)
            else {
                os_log("Could not decode %@ to Task", log: log, taskJsonString)
                postResult(result: result, value: false)
                return
            }
            guard validateUrl(task) != nil else
            {
                os_log("Invalid url: %@", log: log, type: .info, task.url)
                postResult(result: result, value: false)
                return
            }
            os_log("Enqueueing task with id %@ to the HoldingQueue", log: log, type: .info, task.taskId)
            await BDPlugin.holdingQueue?.add(item: EnqueueItem(task: task, notificationConfigJsonString: notificationConfigJsonString, resumeDataAsBase64String: resumeDataAsBase64String))
            processStatusUpdate(task: task, status: .enqueued)
            postResult(result: result, value: true)
        }
    }
    
    /// Do the actual enqueue as a URLSessionTask
    public func doEnqueue(taskJsonString: String, notificationConfigJsonString: String?, resumeDataAsBase64String: String) async -> Bool {
        let taskDescription = notificationConfigJsonString == nil ? taskJsonString : taskJsonString + separatorString + notificationConfigJsonString!
        var isResume = !resumeDataAsBase64String.isEmpty
        let resumeData = isResume ? Data(base64Encoded: resumeDataAsBase64String) : nil
        guard let task = taskFrom(jsonString: taskJsonString)
        else {
            os_log("Could not decode %@ to Task", log: log, taskJsonString)
            return false
        }
        if notificationConfigJsonString != nil {
            BDPlugin.propertyLock.withLock {
                BDPlugin.notificationConfigJsonStrings[task.taskId] = notificationConfigJsonString
            }
        }
        isResume = isParallelDownloadTask(task: task) ? isResume : isResume && resumeData != nil
        let verb = isResume ? "Enqueueing (to resume)" : "Enqueueing"
        os_log("%@ task with id %@", log: log, type: .info, verb, task.taskId)
        UrlSessionDelegate.createUrlSession()
        guard let url = validateUrl(task) else
        {
            os_log("Invalid url: %@", log: log, type: .info, task.url)
            return false
        }
        var baseRequest = URLRequest(url: url)
        baseRequest.httpMethod = task.httpRequestMethod
        for (key, value) in task.headers {
            // copy headers unless Range header in UploadTask
            if key != "Range" || task.taskType != "UploadTask" {
                baseRequest.setValue(value, forHTTPHeaderField: key)
            }
        }
        let requiresWiFi = taskRequiresWiFi(task: task)
        if requiresWiFi {
            baseRequest.allowsCellularAccess = false
            BDPlugin.propertyLock.withLock {
                _ = BDPlugin.taskIdsRequiringWiFi.insert(task.taskId)
            }
        }
        if isParallelDownloadTask(task: task) {
            // ParallelDownloadTask itself is not part of a urlSession, so handled separately
            baseRequest.httpMethod = "HEAD" // override
            return await scheduleParallelDownload(task: task, taskDescription: taskDescription, baseRequest: baseRequest, resumeData: resumeDataAsBase64String)
        } else if isDownloadTask(task: task) || isDataTask(task: task)
        {
            return await scheduleDownload(task: task, taskDescription: taskDescription, baseRequest: baseRequest, resumeData: resumeData, notificationConfigJsonString: notificationConfigJsonString)
        } else
        {
            return await scheduleUpload(task: task, taskDescription: taskDescription, baseRequest: baseRequest, notificationConfigJsonString: notificationConfigJsonString)
        }
    }

    
    /// Schedule a download task
    private func scheduleDownload(task: Task, taskDescription: String, baseRequest: URLRequest, resumeData: Data?, notificationConfigJsonString: String?) async -> Bool {
        var request = baseRequest
        if task.post != nil {
            request.httpBody = Data((task.post ?? "").data(using: .utf8)!)
        }
        let urlSessionDownloadTask = resumeData == nil ? UrlSessionDelegate.urlSession!.downloadTask(with: request) : UrlSessionDelegate.urlSession!.downloadTask(withResumeData: resumeData!)
        urlSessionDownloadTask.taskDescription = taskDescription
        urlSessionDownloadTask.priority = 1 - Float(task.priority) / 10
        urlSessionDownloadTask.resume()
        await postEnqueuedStatusIfNotAlreadyDone(task: task, notificationConfigJsonString: notificationConfigJsonString)
        return true
    }
    
    /// Schedule an upload task
    private func scheduleUpload(task: Task, taskDescription: String, baseRequest: URLRequest, notificationConfigJsonString: String?) async -> Bool  {
        var request = baseRequest
        if isBinaryUploadTask(task: task) {
            // binary post can use uploadTask fromFile method
            os_log("Binary file upload", log: log, type: .debug)
            guard let directory = try? directoryForTask(task: task) else {
                os_log("Could not find directory for taskId %@", log: log, type: .info, task.taskId)
                return false
            }
            let fileUrl = directory.appendingPath(task.filename)
            if !FileManager.default.fileExists(atPath: fileUrl.path) {
                os_log("Could not find file %@ for taskId %@", log: log, type: .info, fileUrl.absoluteString, task.taskId)
                return false
            }
            request.setValue(task.mimeType, forHTTPHeaderField: "Content-Type")
            if let encodedFilename = task.filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
                request.setValue("attachment; filename=\"\(encodedFilename)\"", forHTTPHeaderField: "Content-Disposition")
            } else {
                os_log("Could not encode task.fileName %@", log: log, type: .info, task.filename)
                return false
            }
            request.setValue("attachment; filename=\"\(task.filename)\"", forHTTPHeaderField: "Content-Disposition")
            var uploadFileUrl = fileUrl // if no range given
            if let rangeHeader = task.headers["Range"] {
                // determine the start and content length from the range header
                let regex = try? NSRegularExpression(pattern: #"bytes=(\d+)-(\d*)"#)
                let range = NSRange(rangeHeader.startIndex..<rangeHeader.endIndex, in: rangeHeader)
                if let match = regex?.firstMatch(in: rangeHeader, options: [], range: range) {
                    if let startRange = Range(match.range(at: 1), in: rangeHeader),
                       let start = UInt64(rangeHeader[startRange]) {
                        let contentLength: UInt64
                        if let endRange = Range(match.range(at: 2), in: rangeHeader),
                           let end = UInt64(rangeHeader[endRange]) {
                            contentLength = end - start + 1
                        } else {
                            // get file size to determine contentLength
                            do {
                                let attributes = try FileManager.default.attributesOfItem(atPath: fileUrl.path)
                                if let fileSize = attributes[.size] as? UInt64 {
                                    contentLength = fileSize - start
                                } else {
                                    os_log("Could not get file size", log: log, type: .info)
                                    return false
                                }
                            } catch {
                                os_log("Could not get file size", log: log, type: .info)
                                return false
                            }
                        }
                        // create the partial file for upload
                        if let tempFileUrl = createTempFileWithRange(from: fileUrl, start: start, contentLength: contentLength) {
                            BDPlugin.propertyLock.withLock({
                                BDPlugin.tasksWithTempUploadFile[task.taskId] = tempFileUrl
                            })
                            uploadFileUrl = tempFileUrl
                        }
                        else {
                            os_log("Could not create temp file for partial upload", log: log, type: .info)
                            return false
                        }
                    } else {
                        os_log("Invalid Range header %@", log: log, type: .info, rangeHeader)
                        return false
                    }
                } else {
                    os_log("Invalid Range header %@", log: log, type: .info, rangeHeader)
                    return false
                }
            }
            let urlSessionUploadTask = UrlSessionDelegate.urlSession!.uploadTask(with: request, fromFile: uploadFileUrl)
            urlSessionUploadTask.taskDescription = taskDescription
            urlSessionUploadTask.priority = 1 - Float(task.priority) / 10
            urlSessionUploadTask.resume()
        }
        else {
            // multi-part upload
            os_log("Multipart file upload", log: log, type: .debug)
            let uploader = Uploader(task: task)
            if !uploader.createMultipartFile() {
                return false
            }
            request.setValue("multipart/form-data; boundary=\(Uploader.boundary)", forHTTPHeaderField: "Content-Type")
            request.setValue("UTF-8", forHTTPHeaderField: "Accept-Charset")
            request.setValue("Keep-Alive", forHTTPHeaderField: "Connection")
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            let urlSessionUploadTask = UrlSessionDelegate.urlSession!.uploadTask(with: request, fromFile: uploader.outputFileUrl())
            urlSessionUploadTask.taskDescription = taskDescription
            urlSessionUploadTask.priority = 1 - Float(task.priority) / 10
            BDPlugin.uploaderForUrlSessionTaskIdentifier[urlSessionUploadTask.taskIdentifier] = uploader
            urlSessionUploadTask.resume()
        }
        await postEnqueuedStatusIfNotAlreadyDone(task: task, notificationConfigJsonString: notificationConfigJsonString)
        return true
    }
    
    /// Post [TaskStatus.enqueued] only if this was not already done when adding the task to the [holdingQueue]
    func postEnqueuedStatusIfNotAlreadyDone(task: Task, notificationConfigJsonString: String?) async {
        if BDPlugin.holdingQueue?.enqueuedTaskIds.contains(task.taskId) != true {
            processStatusUpdate(task: task, status: TaskStatus.enqueued)
        }
        // register the enqueue with the notification service (for accurate groupnotification count)
        await registerEnqueue(task: task, notificationConfigJsonString: notificationConfigJsonString, success: true)
    }
    
    /// Resets the downloadworker by cancelling all ongoing download tasks
    ///
    /// Returns the number of tasks canceled
    private func methodReset(call: FlutterMethodCall, result: @escaping FlutterResult) async {
        let group = call.arguments as! String
        await BDPlugin.holdingQueue?.stateLock.lock()
        var counter = BDPlugin.holdingQueue?.cancelAllTasks(group: group) ?? 0
        let tasksToCancel = await UrlSessionDelegate.getAllUrlSessionTasks(group: group)
        tasksToCancel.forEach({$0.cancel()})
        await BDPlugin.holdingQueue?.stateLock.unlock()
        counter += tasksToCancel.count
        os_log("reset removed %d unfinished tasks", log: log, type: .debug, counter)
        result(counter)
    }
    
    /// Returns a list with all tasks in progress, as a list of JSON strings, optionally filtered by [group]
    private func methodAllTasks(call: FlutterMethodCall, result: @escaping FlutterResult) async {
        let group = call.arguments as? String
        var tasksAsListOfJsonStrings = [String]()
        await BDPlugin.holdingQueue?.stateLock.lock()
        if let heldTasksJsonStrings = BDPlugin.holdingQueue?.allTasks(group: group).map({jsonStringFor(task: $0)}).filter({$0 != nil}).map({$0!}) {
            tasksAsListOfJsonStrings.append(contentsOf:  heldTasksJsonStrings)
        }
        UrlSessionDelegate.createUrlSession()
        if let urlSessionTasks = await UrlSessionDelegate.urlSession?.allTasks {
            tasksAsListOfJsonStrings.append(contentsOf: urlSessionTasks.filter({ $0.state == .running || $0.state == .suspended }).map({ getTaskFrom(urlSessionTask: $0)}).filter({group == nil || $0?.group == group }).map({ jsonStringFor(task: $0!) }).filter({ $0 != nil }).map({$0!}))
        }
        await BDPlugin.holdingQueue?.stateLock.unlock()
        os_log("Returning %d unfinished tasks", log: log, type: .debug, tasksAsListOfJsonStrings.count)
        result(tasksAsListOfJsonStrings)
        
    }
    
    /// Cancels ongoing tasks whose taskId is in the list provided with this call
    ///
    /// Returns true if all cancellations were successful
    private func methodCancelTasksWithIds(call: FlutterMethodCall, result: @escaping FlutterResult) async {
        let taskIds = call.arguments as! [String]
        os_log("Canceling taskIds %@", log: log, type: .info, taskIds)
        await BDPlugin.holdingQueue?.stateLock.lock()
        let taskIdsRemovedFromHoldingQueue = BDPlugin.holdingQueue?.cancelTasksWithIds(taskIds) ?? []
        let taskIdsRemaining = taskIds.filter({ !taskIdsRemovedFromHoldingQueue.contains($0) })
        let tasksToCancel = await UrlSessionDelegate.getAllUrlSessionTasks().filter({
            guard let task = getTaskFrom(urlSessionTask: $0) else { return false }
            return taskIdsRemaining.contains(task.taskId)
        })
        tasksToCancel.forEach({$0.cancel()})
        // cancel all ParallelDownloadTasks (they would not have shown up in tasksToCancel)
        taskIdsRemaining.forEach { ParallelDownloader.downloads[$0]?.cancelTask() }
        result(true)
        await BDPlugin.holdingQueue?.stateLock.unlock()
    }
    
    
    
    /// Returns Task for this taskId, or nil
    private func methodTaskForId(call: FlutterMethodCall, result: @escaping FlutterResult) async {
        let taskId = call.arguments as! String
        await BDPlugin.holdingQueue?.stateLock.lock()
        var foundTask = BDPlugin.holdingQueue?.taskForId(taskId)
        if (foundTask == nil) {
            foundTask = await UrlSessionDelegate.getTaskWithId(taskId: taskId)
        }
        result(foundTask == nil ? nil : jsonStringFor(task: foundTask!))
        await BDPlugin.holdingQueue?.stateLock.unlock()
    }
    
    /// Pauses Task for this taskId. Returns true of pause likely successful, false otherwise
    ///
    /// If pause is not successful, task will be canceled (attempted)
    private func methodPause(call: FlutterMethodCall, result: @escaping FlutterResult) async {
        let taskId = call.arguments as! String
        UrlSessionDelegate.createUrlSession()
        BDPlugin.propertyLock.withLock({
            _ = BDPlugin.taskIdsProgrammaticallyCancelled.insert(taskId)
        })
        guard let urlSessionTask = await UrlSessionDelegate.getUrlSessionTaskWithId(taskId: taskId) as? URLSessionDownloadTask,
              let task = await UrlSessionDelegate.getTaskWithId(taskId: taskId),
              let resumeData = await urlSessionTask.cancelByProducingResumeData()
        else {
            // no regular task found, return if there's no ParalleldownloadTask either
            BDPlugin.propertyLock.withLock({
                _ = BDPlugin.taskIdsProgrammaticallyCancelled.remove(taskId)
            })
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
    
    /// Update the notification for this task
    /// Args are:
    /// - task
    /// - notificationConfig - cannot be null
    /// - taskStatus as ordinal in TaskStatus enum. If null, delete the notification
    private func methodUpdateNotification(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as! [Any]
        let taskJsonString = args[0] as! String
        let notificationConfigJsonString = args[1] as! String
        let taskStatusOrdinal = args[2] as? Int
        guard let task = taskFrom(jsonString: taskJsonString),
              let notificationConfig = notificationConfigFrom(jsonString: notificationConfigJsonString)
        else {
            os_log("Cannot decode Task or NotificationConfig", log: log)
            return
        }
        if (taskStatusOrdinal == nil) {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [task.taskId])
        } else {
            let notificationType = notificationTypeForTaskStatus(status: TaskStatus(rawValue: taskStatusOrdinal!)!)
            updateNotification(task: task, notificationType: notificationType, notificationConfig: notificationConfig)
        }
    }
    
    
    /// Returns a JSON String of a map of [ResumeData], keyed by taskId, that has been stored
    /// in local shared preferences because they could not be delivered to the Dart side.
    /// Local storage of this map is then cleared
    private func methodPopResumeData(result: @escaping FlutterResult) {
        popLocalStorage(key: BDPlugin.keyResumeDataMap, result: result)
    }
    
    /// Returns a JSON String of a map of status updates, keyed by taskId, that has been stored
    /// in local shared preferences because they could not be delivered to the Dart side.
    /// Local storage of this map is then cleared
    private func methodPopStatusUpdates(result: @escaping FlutterResult) {
        popLocalStorage(key: BDPlugin.keyStatusUpdateMap, result: result)
    }
    
    /// Returns a JSON String of a map of progress updates, keyed by taskId, that has been stored
    /// in local shared preferences because they could not be delivered to the Dart side.
    /// Local storage of this map is then cleared
    private func methodPopProgressUpdates(result: @escaping FlutterResult) {
        popLocalStorage(key: BDPlugin.keyProgressUpdateMap, result: result)
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
    private func methodMoveToSharedStorage(call: FlutterMethodCall, result: @escaping FlutterResult) async {
        let args = call.arguments as! [Any]
        guard
            let filePath = args[0] as? String,
            let destination = SharedStorage.init(rawValue: args[1] as? Int ?? 0),
            let directory = args[2] as? String
        else {
            result(nil)
            return
        }
        result(await moveToSharedStorage(filePath: filePath, destination: destination, directory: directory))
    }
    
    /// Returns path to file in a SharedStorage destination, or null
    private func methodPathInSharedStorage(call: FlutterMethodCall, result: @escaping FlutterResult) async {
        let args = call.arguments as! [Any]
        guard
            let filePath = args[0] as? String,
            let destination = SharedStorage(rawValue: args[1] as? Int ?? 0),
            let directory = args[2] as? String
        else {
            result(nil)
            return
        }
        result(await pathInSharedStorage(filePath: filePath, destination: destination, directory: directory))
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
    
    /**
     * Set WiFi requirement globally, based on requirement.
     *
     * Affects future tasks and reschedules enqueued, inactive tasks
     * with the new setting.
     * Reschedules active tasks if rescheduleRunning is true,
     * otherwise leaves those running with their prior setting
     *
     * - requirement is first argument (enum)
     * - rescheduleRunning is second argument (bool)
     *
     * Returns true if successful
     */
    private func methodRequireWiFi(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as! [Any]
        guard let newRequireWiFi = RequireWiFi(rawValue: args[0] as? Int ?? 0) else {
            result(false)
            return
        }
        let rescheduleRunning = args[1] as? Bool ?? false
        WiFiQueue.shared.requireWiFiChange(requireWiFi: newRequireWiFi, rescheduleRunningTasks: rescheduleRunning)
        result(true)
    }
    
    /// Returns current globval setting for 'RequireWiFi' as an ordinal / rawValue
    private func methodGetRequireWiFiSetting(result: @escaping FlutterResult) {
        let defaults = UserDefaults.standard
        result(defaults.integer(forKey: BDPlugin.keyRequireWiFi))
    }
    
    /// Update the status of one chunk (part of a ParallelDownloadTask), and returns
    /// the status of the parent task based on the 'sum' of its children, or null
    /// if unchanged
    ///
    /// Arguments are the parent TaskId, chunk taskId, taskStatusOrdinal, exceptionJsonString, responseBody
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
        
    /// Return the authorization status of a permission, passed as the rawValue of the
    /// [Permissionequest] enum
    private func methodPermissionStatus(call: FlutterMethodCall, result: @escaping FlutterResult) async {
        let permissionType = PermissionType(rawValue: call.arguments as! Int)!
        let status = await getPermissionStatus(for: permissionType)
        result(status.rawValue)
    }
    
    /// Request this permission, passed as the rawValue of the [Permissionequest] enum
    private func methodRequestPermission(call: FlutterMethodCall, result: @escaping FlutterResult) async {
        let permissionType = PermissionType(rawValue: call.arguments as! Int)!
        let status = await requestPermission(for: permissionType)
        result(status.rawValue)
    }
    
    /// Store or remove a configuration in shared preferences
    ///
    /// If the value is nil, the configuration is removed
    private func storeInUserDefaults(key: String, value: Any?, result: @escaping FlutterResult) {
        let defaults = UserDefaults.standard
        if value != nil {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
        result(nil)
    }
    
    /// Configure the HoldingQueue (and create if necessary)
    private func methodConfigHoldingQueue(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as! [Any]
        BDPlugin.holdingQueue = BDPlugin.holdingQueue ?? HoldingQueue()
        BDPlugin.holdingQueue?.maxConcurrent = args[0] as! Int
        BDPlugin.holdingQueue?.maxConcurrentByHost = args[1] as! Int
        BDPlugin.holdingQueue?.maxConcurrentByGroup = args[2] as! Int
        result(nil)
    }

    /// Sets or resets flag to force failing posting on background channel
    ///
    /// For testing only
    private func methodForceFailPostOnBackgroundChannel(call: FlutterMethodCall, result: @escaping FlutterResult) {
        BDPlugin.forceFailPostOnBackgroundChannel = call.arguments as! Bool
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
    
    //MARK: UIApplicationDelegate
    
    /// When the app restarts, recreate the urlSession if needed, and store the completion handler
    public func application(_ application: UIApplication,
                            handleEventsForBackgroundURLSession identifier: String,
                            completionHandler: @escaping () -> Void) -> Bool {
        if (identifier == UrlSessionDelegate.sessionIdentifier) {
            os_log("Application asked to handleEventsForBackgroundURLSession", log: log, type: .info)
            UrlSessionDelegate.backgroundCompletionHandler = completionHandler
            UrlSessionDelegate.createUrlSession()
            return true
        }
        return false
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
                    guard let urlSessionTask = await UrlSessionDelegate.getUrlSessionTaskWithId(taskId: task.taskId) as? URLSessionDownloadTask,
                          let resumeData = await urlSessionTask.cancelByProducingResumeData()
                    else {
                        os_log("Could not pause task in response to notification action", log: log, type: .info)
                        return
                    }
                    _ = processResumeData(task: task, resumeData: resumeData)
                    
                case "cancel_action":
                    let urlSessionTaskToCancel = await UrlSessionDelegate.getAllUrlSessionTasks().first(where: {
                        guard let taskInUrlSessionTask = getTaskFrom(urlSessionTask: $0) else { return false }
                        return taskInUrlSessionTask.taskId == task.taskId
                    })
                    urlSessionTaskToCancel?.cancel()
                    
                case "cancel_inactive_action":
                    processStatusUpdate(task: task, status: .canceled)
                    
                case "resume_action":
                    var resumeDataAsBase64String = ""
                    BDPlugin.propertyLock.withLock {
                        resumeDataAsBase64String = BDPlugin.localResumeData[task.taskId] ?? ""
                    }
                    if resumeDataAsBase64String.isEmpty {
                        os_log("Resume data for taskId %@ no longer available: restarting", log: log, type: .info, task.taskId)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        _Concurrency.Task {
                            if await(BDPlugin.instance.doEnqueue(taskJsonString: taskAsJsonString, notificationConfigJsonString: userInfo["notificationConfig"] as? String, resumeDataAsBase64String: resumeDataAsBase64String)) == false {
                                os_log("Could not enqueue taskId %@ to resume", log: log, type: .info, task.taskId)
                                await BDPlugin.holdingQueue?.taskFinished(task)
                            }
                        }
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
}
