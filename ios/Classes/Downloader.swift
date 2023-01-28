import Flutter
import UIKit
import BackgroundTasks
import os.log


/// Partial version of the Dart side DownloadTask, only used for background loading
struct BackgroundDownloadTask : Codable {
    var taskId: String
    var url: String
    var filename: String
    var headers: [String:String]
    var post: String?
    var directory: String
    var baseDirectory: Int
    var group: String
    var progressUpdates: Int
    var requiresWiFi: Bool
    var retries: Int
    var retriesRemaining: Int
    var metaData: String
}

/// True if this task expects to provide progress updates
func providesProgressUpdates(task: BackgroundDownloadTask) -> Bool {
    return task.progressUpdates == DownloadTaskProgressUpdates.progressUpdates.rawValue || task.progressUpdates == DownloadTaskProgressUpdates.statusChangeAndProgressUpdates.rawValue
}

/// True if this task expects to provide status updates
func providesStatusUpdates(downloadTask: BackgroundDownloadTask) -> Bool {
    return downloadTask.progressUpdates == DownloadTaskProgressUpdates.statusChange.rawValue || downloadTask.progressUpdates == DownloadTaskProgressUpdates.statusChangeAndProgressUpdates.rawValue
}

/// Base directory in which files will be stored, based on their relative
/// path.
///
/// These correspond to the directories provided by the path_provider package
enum BaseDirectory: Int {
    case applicationDocuments, // getApplicationDocumentsDirectory()
         temporary, // getTemporaryDirectory()
         applicationSupport // getApplicationSupportDirectory()
}

/// Type of download updates requested for a group of downloads
enum DownloadTaskProgressUpdates: Int {
    case none,  // no status or progress updates
         statusChange, // only calls upon change in DownloadTaskStatus
         progressUpdates, // only calls for progress
         statusChangeAndProgressUpdates // calls also for progress along the way
}

/// Defines a set of possible states which a [DownloadTask] can be in.
enum DownloadTaskStatus: Int {
    case enqueued,
         running,
         complete,
         notFound,
         failed,
         canceled,
         waitingToRetry
}

private func isNotFinalState(status: DownloadTaskStatus) -> Bool {
    return status == .enqueued || status == .running || status == .waitingToRetry
}

private func isFinalState(status: DownloadTaskStatus) -> Bool {
    return !isNotFinalState(status: status)
}

public class Downloader: NSObject, FlutterPlugin, FlutterApplicationLifeCycleDelegate, URLSessionDelegate, URLSessionDownloadDelegate {

    let log = OSLog.init(subsystem: "FileDownloaderPlugin", category: "Downloader")
    
    private static var resourceTimeout = 4 * 60 * 60.0 // in seconds
    public static var sessionIdentifier = "com.bbflight.background_downloader.Downloader"
    public static var flutterPluginRegistrantCallback: FlutterPluginRegistrantCallback?
    private static var backgroundChannel: FlutterMethodChannel?
    
    private final var backgroundCompletionHandler: (() -> Void)?
    private final var urlSession: URLSession?
    private var nativeToTaskMap  = [String: BackgroundDownloadTask]()
    private var lastProgressUpdate = [String:Double]()
    private var nextProgressUpdateTime = [String:Date]()
    
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
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    
    
    /// Starts the download for one task, passed as map of values representing a BackgroundDownloadTasks
    ///
    /// Returns true if successful, but will emit a status update that the background task is running
    private func methodEnqueue(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as! [Any]
        let jsonString = args[0] as! String
        os_log("methodEnqueue with %@", log: log, type: .info, jsonString)
        guard let backgroundDownloadTask = downloadTaskFrom(jsonString: jsonString)
        else {
            os_log("Could not decode %@ to downloadTask", log: log, jsonString)
            result(false)
            return
        }
        os_log("Starting task with id %@", log: log, type: .info, backgroundDownloadTask.taskId)
        urlSession = urlSession ?? createUrlSession()
        var request = URLRequest(url: URL(string: backgroundDownloadTask.url)!)
        if backgroundDownloadTask.post != nil {
            request.httpMethod = "POST"
            request.httpBody = Data((backgroundDownloadTask.post ?? "").data(using: .utf8)!)
        }
        if backgroundDownloadTask.requiresWiFi {
            request.allowsCellularAccess = false
        }
        for (key, value) in backgroundDownloadTask.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let urlSessionDownloadTask = urlSession!.downloadTask(with: request)
        urlSessionDownloadTask.taskDescription = jsonString
        // now start the task
        urlSessionDownloadTask.resume()
        processStatusUpdate(backgroundDownloadTask: backgroundDownloadTask, status: DownloadTaskStatus.enqueued)
        result(true)
    }
    
    /// Resets the downloadworker by cancelling all ongoing download tasks
    ///
    /// Returns the number of tasks canceled
    private func methodReset(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let group = call.arguments as! String
        urlSession = urlSession ?? createUrlSession()
        var counter = 0
        urlSession?.getAllTasks(completionHandler: { tasks in
            for task in tasks {
                guard let backgroundDownloadTask = self.getTaskFrom(urlSessionDownloadTask: task)
                else { continue }
                if backgroundDownloadTask.group == group {
                    task.cancel()
                    counter += 1
                }
            }
            os_log("methodReset removed %d unfinished tasks", log: self.log, type: .info, counter)
            result(counter)
        })
    }
    
    /// Returns a list with all tasks in progress, as a list of JSON strings
    private func methodAllTasks(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let group = call.arguments as! String
        var tasksAsListOfJsonStrings: [String] = []
        urlSession = urlSession ?? createUrlSession()
        urlSession?.getAllTasks(completionHandler: { tasks in
            for task in tasks {
                guard let backgroundDownloadTask = self.getTaskFrom(urlSessionDownloadTask: task)
                else { continue }
                if backgroundDownloadTask.group == group {
                    if task.state == URLSessionTask.State.running || task.state == URLSessionTask.State.suspended
                    {
                        let taskAsJsonString = self.jsonStringFor(backgroundDownloadTask: backgroundDownloadTask)
                        if taskAsJsonString != nil {
                            tasksAsListOfJsonStrings.append(taskAsJsonString!)
                        }
                    }
                }
            }
            os_log("Returning %d unfinished tasks", log: self.log, type: .info, tasksAsListOfJsonStrings.count)
            result(tasksAsListOfJsonStrings)
        })
    }
    
    
    /// Cancels ongoing tasks whose taskId is in the list provided with this call
    ///
    /// Returns true if all cancellations were successful
    private func methodCancelTasksWithIds(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let taskIds = call.arguments as! [String]
        os_log("Canceling taskIds %@", log: log, type: .info, taskIds)
        urlSession = urlSession ?? createUrlSession()
        urlSession?.getAllTasks(completionHandler: { tasks in
            for task in tasks {
                guard let backgroundDownloadTask = self.getTaskFrom(urlSessionDownloadTask: task)
                else { continue }
                if taskIds.contains(backgroundDownloadTask.taskId)
                {
                    task.cancel() }
            }
            result(true)
        })
    }
    
    /// Returns BackgroundDownloadTask for this taskId, or nil
    private func methodTaskForId(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let taskId = call.arguments as! String
        urlSession = urlSession ?? createUrlSession()
        urlSession?.getAllTasks(completionHandler: { tasks in
            for task in tasks {
                guard let backgroundDownloadTask = self.getTaskFrom(urlSessionDownloadTask: task)
                else { continue }
                os_log("Found taskId %@", log: self.log, type: .info, backgroundDownloadTask.taskId)
                if backgroundDownloadTask.taskId == taskId
                {
                    result(self.jsonStringFor(backgroundDownloadTask: backgroundDownloadTask))
                    return
                }
            }
            result(nil)
        })
    }
    
    /// Handle potential errors sent by the urlSession
    ///
    /// Notre that this is called frequently with error == nil, and can then be ignored
    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if error != nil {
            guard let backgroundDownloadTask = self.getTaskFrom(urlSessionDownloadTask: task) else {return}
            if error!.localizedDescription.contains("cancelled") {
                processStatusUpdate(backgroundDownloadTask: backgroundDownloadTask, status: DownloadTaskStatus.canceled)
            }
            else {
                os_log("Error for download with error %@", log: self.log, type: .error, error!.localizedDescription)
                processStatusUpdate(backgroundDownloadTask: backgroundDownloadTask, status: DownloadTaskStatus.failed)
            }
        }
    }
    
    //MARK: URLSessionDownloadTask delegate methods
    
    /// Process progress update
    ///
    /// If the task requires progress updates, provide these at some reasonable interval
    /// If this is the first update for this file, also emit a 'running' status update
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let backgroundDownloadTask = self.getTaskFrom(urlSessionDownloadTask: downloadTask) else {return}
        if lastProgressUpdate[backgroundDownloadTask.taskId] == nil {
            // send 'running' status update
            processStatusUpdate(backgroundDownloadTask: backgroundDownloadTask, status: DownloadTaskStatus.running)
            lastProgressUpdate[backgroundDownloadTask.taskId] = 0.0
        }
        if totalBytesExpectedToWrite != NSURLSessionTransferSizeUnknown && Date() > nextProgressUpdateTime[backgroundDownloadTask.taskId] ?? Date(timeIntervalSince1970: 0) {
            let progress = min(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 0.999)
            if progress - (lastProgressUpdate[backgroundDownloadTask.taskId] ?? 0.0) > 0.02 {
                processProgressUpdate(backgroundDownloadTask: backgroundDownloadTask, progress: progress)
                lastProgressUpdate[backgroundDownloadTask.taskId] = progress
                nextProgressUpdateTime[backgroundDownloadTask.taskId] = Date().addingTimeInterval(0.5)
            }
        }
    }
    
    /// Process end of downloadTask sent by the urlSession.
    ///
    /// If successful, (over)write file to final destination per BackgroundDownloadTask info
    public func urlSession(_ session: URLSession,
                           downloadTask: URLSessionDownloadTask,
                           didFinishDownloadingTo location: URL) {
        guard let backgroundDownloadTask = self.getTaskFrom(urlSessionDownloadTask: downloadTask),
              let response = downloadTask.response as? HTTPURLResponse
        else {
            os_log("Could not find task associated with native id %d, or did not get HttpResponse", log: log,  type: .info, downloadTask.taskIdentifier)
            return}
        if response.statusCode == 404 {
            processStatusUpdate(backgroundDownloadTask: backgroundDownloadTask, status: DownloadTaskStatus.notFound)
            return
        }
        if !(200...206).contains(response.statusCode)   {
            os_log("TaskId %@ returned response code %d", log: log,  type: .info, backgroundDownloadTask.taskId, response.statusCode)
            processStatusUpdate(backgroundDownloadTask: backgroundDownloadTask, status: DownloadTaskStatus.failed)
            return
        }
        do {
            var success = DownloadTaskStatus.failed
            defer {
                processStatusUpdate(backgroundDownloadTask: backgroundDownloadTask, status: success)
            }
            var dir: FileManager.SearchPathDirectory
            switch backgroundDownloadTask.baseDirectory {
            case 0:
                dir = .documentDirectory
            case 1:
                dir = .cachesDirectory
            case 2:
                dir = .libraryDirectory
            default:
                dir = .documentDirectory
            }
            let documentsURL = try
            FileManager.default.url(for: dir,
                                    in: .userDomainMask,
                                    appropriateFor: nil,
                                    create: false)
            let directory = documentsURL.appendingPathComponent(backgroundDownloadTask.directory)
            do
            {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories:  true)
            } catch {
                os_log("Failed to create directory %@", log: log, type: .error, directory.path)
                return
            }
            let filePath = directory.appendingPathComponent(backgroundDownloadTask.filename)
            if FileManager.default.fileExists(atPath: filePath.path) {
                try? FileManager.default.removeItem(at: filePath)
            }
            do {
                try FileManager.default.moveItem(at: location, to: filePath)
            } catch {
                os_log("Failed to move file from %@ to %@: %@", log: log, type: .error, location.path, filePath.path, error.localizedDescription)
                return
            }
            success = DownloadTaskStatus.complete
        } catch {
            os_log("File download error for taskId %@ and file %@: %@", log: log, type: .error, backgroundDownloadTask.taskId, backgroundDownloadTask.filename, error.localizedDescription)
        }
    }
    
    
    //MARK: URLSession delegate methods
    
    /// When the app restarts, recreate the urlSession if needed, and store the completion handler
    public func application(_ application: UIApplication,
                            handleEventsForBackgroundURLSession identifier: String,
                            completionHandler: @escaping () -> Void) -> Bool {
        os_log("In handleEventsForBackgroundURLSession with identifier %@", log: log, type: .debug, identifier)
        if (identifier == Downloader.sessionIdentifier) {
            backgroundCompletionHandler = completionHandler
            urlSession = urlSession ?? createUrlSession()
            return true
        }
        return false
    }
    
    /// Upon completion of download of all files, call the completion handler
    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        os_log("In urlSessionDidFinishEvents, calling completionHandler", log: log, type: .debug)
        DispatchQueue.main.async {
            guard
                let handler = self.backgroundCompletionHandler,
                session.configuration.identifier == Downloader.sessionIdentifier
            else {
                os_log("No handler or no identifier match", log: self.log, type: .info)
                return
            }
            handler()
        }
    }
    
    //MARK: helper methods
    
    /// Returns a BackgroundDownloadTask from the supplied jsonString, or nil
    private func downloadTaskFrom(jsonString: String) -> BackgroundDownloadTask? {
        let decoder = JSONDecoder()
        let backgroundDownloadTasks: BackgroundDownloadTask? = try? decoder.decode(BackgroundDownloadTask.self, from: (jsonString).data(using: .utf8)!)
        return backgroundDownloadTasks
    }
    
    /// Returns a JSON string for this BackgroundDownloadTask, or nil
    private func jsonStringFor(backgroundDownloadTask: BackgroundDownloadTask) -> String? {
        let jsonEncoder = JSONEncoder()
        guard let jsonResultData = try? jsonEncoder.encode(backgroundDownloadTask)
        else {
            return nil
        }
        return String(data: jsonResultData, encoding: .utf8)
    }
    
    
    /// Processes a change in status for the task
    ///
    /// Sends status update via the background channel to Flutter, if requested, and if the task is finished,
    /// processes a final status update, then removes it from permanent storage
    private func processStatusUpdate(backgroundDownloadTask: BackgroundDownloadTask, status: DownloadTaskStatus) {
        guard let channel = Downloader.backgroundChannel else {
            os_log("Could not find background channel", log: self.log, type: .error)
            return
        }
        // Post update if task expects one, or if failed and retry is needed
        let retryNeeded = status == DownloadTaskStatus.failed && backgroundDownloadTask.retriesRemaining > 0
        if providesStatusUpdates(downloadTask: backgroundDownloadTask) || retryNeeded {
            let jsonString = jsonStringFor(backgroundDownloadTask: backgroundDownloadTask)
            if (jsonString != nil)
            {
                DispatchQueue.main.async {
                    channel.invokeMethod("statusUpdate", arguments: [jsonString!, status.rawValue])
                }
            }
        }
        // if task is in final state, process a final progressUpdate and remove from
        // persistent storage. A 'failed' progress update is only provided if
        // a retry is not needed: if it is needed, a `waitingToRetry` progress update
        // will be generated on the Dart side
        if isFinalState(status: status) {
            switch (status) {
            case .complete:
                processProgressUpdate(backgroundDownloadTask: backgroundDownloadTask, progress: 1.0)
            case .failed:
                if !retryNeeded {
                    processProgressUpdate(backgroundDownloadTask: backgroundDownloadTask, progress: -1.0)
                }
            case .canceled:
                processProgressUpdate(backgroundDownloadTask: backgroundDownloadTask, progress: -2.0)
            case .notFound:
                processProgressUpdate(backgroundDownloadTask: backgroundDownloadTask, progress: -3.0)
            default:
                break
            }
            nativeToTaskMap.removeValue(forKey: backgroundDownloadTask.taskId)
            lastProgressUpdate.removeValue(forKey: backgroundDownloadTask.taskId)
            nextProgressUpdateTime.removeValue(forKey: backgroundDownloadTask.taskId)
        }
    }
    
    /// Processes a progress update for the task
    ///
    /// Sends progress update via the background channel to Flutter, if requested
    private func processProgressUpdate(backgroundDownloadTask: BackgroundDownloadTask, progress: Double) {
        guard let channel = Downloader.backgroundChannel else {
            os_log("Could not find background channel", log: self.log, type: .error)
            return
        }
        if providesProgressUpdates(task: backgroundDownloadTask) {
            let jsonString = jsonStringFor(backgroundDownloadTask: backgroundDownloadTask)
            if (jsonString != nil)
            {
                DispatchQueue.main.async {
                    channel.invokeMethod("progressUpdate", arguments: [jsonString!, progress])
                }
            }
        }
    }
    
    /// Return the task corresponding to the URLSessionTask, or nil if it cannot be matched
    private func getTaskFrom(urlSessionDownloadTask: URLSessionTask) -> BackgroundDownloadTask? {
        let decoder = JSONDecoder()
        guard let jsonData = urlSessionDownloadTask.taskDescription?.data(using: .utf8)
        else {
            return nil
        }
        return try? decoder.decode(BackgroundDownloadTask.self, from: jsonData)
    }
    
    /// Creates a urlSession
    private func createUrlSession() -> URLSession {
        os_log("Creating URLSession", log: log, type: .info)
        if urlSession != nil {
            os_log("createUrlSession called with non-null urlSession", log: log, type: .info)
        }
        let config = URLSessionConfiguration.background(withIdentifier: Downloader.sessionIdentifier)
        config.timeoutIntervalForResource = Downloader.resourceTimeout
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }
}


