import Flutter
import UIKit
import BackgroundTasks
import os.log


/// Partial version of the Dart side DownloadTask, only used for background loading
struct BackgroundDownloadTask : Codable {
  var taskId: String
  var url: String
  var filename: String
  var directory: String
  var baseDirectory: Int
  var group: String
  var progressUpdates: Int
}

/// Creates JSON map of the task
func jsonMapFromTask(task: BackgroundDownloadTask) -> [String: Any] {
  return
    ["taskId": task.taskId,
     "url": task.url,
     "filename": task.filename,
     "directory": task.directory,
     "baseDirectory": task.baseDirectory, // stored as Int
     "group": task.group,
     "progressUpdates": task.progressUpdates // stored as Int
    ]
  
}

/// Creates task from JsonMap
func taskFromJsonMap(map: [String: Any]) -> BackgroundDownloadTask {
  return BackgroundDownloadTask(taskId: map["taskId"] as! String, url: map["url"] as! String, filename: map["filename"] as! String, directory: map["directory"] as! String, baseDirectory: map["baseDirectory"] as! Int, group: map["group"] as! String, progressUpdates: map["progressUpdates"] as! Int)
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
  case undefined,
       enqueued,
       running,
       complete,
       notFound,
       failed,
       canceled
}


    

public class Downloader: NSObject, FlutterPlugin, FlutterApplicationLifeCycleDelegate, URLSessionDelegate, URLSessionDownloadDelegate {
  
  let log = OSLog.init(subsystem: "FileDownloaderPlugin", category: "DownloadWorker")
  
  private static var resourceTimeout = 60 * 60.0 // in seconds
  public static var sessionIdentifier = "com.bbflight.file_downloader.DownloadWorker"
  public static var flutterPluginRegistrantCallback: FlutterPluginRegistrantCallback?
  private static var backgroundChannel: FlutterMethodChannel?
  
  private final var backgroundCompletionHandler: (() -> Void)?
  private final var urlSession: URLSession?
  private var nativeToTaskMap  = [String: BackgroundDownloadTask]()
  private var lastProgressUpdate = [String:Double]()
  private var nextProgressUpdateTime = [String:Date]()
  
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "com.bbflight.file_downloader", binaryMessenger: registrar.messenger())
    backgroundChannel = FlutterMethodChannel(name: "com.bbflight.file_downloader.background", binaryMessenger: registrar.messenger())
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
    os_log("Method call %@", log: log, call.method)
    switch call.method {
    case "reset":
      methodReset(call: call, result: result)
    case "enqueue":
      methodEnqueue(call: call, result: result)
    case "allTaskIds":
      methodAllTaskIds(call: call, result: result)
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
    os_log("methodEnqueue with %@", log: log, jsonString)
    guard let backgroundDownloadTask = downloadTaskFrom(jsonString: jsonString)
    else {
      os_log("Could not decode %@ to downloadTask", log: log, jsonString)
      result(false)
      return
    }
    os_log("Starting task with id %@", log: log, backgroundDownloadTask.taskId)
    urlSession = urlSession ?? createUrlSession()
    let urlSessionDownloadTask = urlSession!.downloadTask(with: URL(string: backgroundDownloadTask.url)!)
    urlSessionDownloadTask.taskDescription = jsonString
    // store local maps related to progress updates
    lastProgressUpdate[backgroundDownloadTask.taskId] = 0.0
    nextProgressUpdateTime[backgroundDownloadTask.taskId] = Date(timeIntervalSince1970: 0)
    
    // now start the task
    urlSessionDownloadTask.resume()
    processStatusUpdate(backgroundDownloadTask: backgroundDownloadTask, status: DownloadTaskStatus.running)
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
        let backgroundDownloadTask = self.getTaskFrom(urlSessionDownloadTask: task)
        if backgroundDownloadTask?.group == group {
        task.cancel()
          counter += 1
        }
      }
      os_log("methodReset removed %d unfinished tasks", log: self.log, counter)
      result(counter)
    })
  }
  
  /// Returns a list with taskIds for all tasks in progress
  private func methodAllTaskIds(call: FlutterMethodCall, result: @escaping FlutterResult) {
    let group = call.arguments as! String
    var taskIds: [String] = []
    urlSession = urlSession ?? createUrlSession()
    urlSession?.getAllTasks(completionHandler: { tasks in
      for task in tasks {
        guard let backgroundDownloadTask = self.getTaskFrom(urlSessionDownloadTask: task)
        else { continue }
        if backgroundDownloadTask.group == group {
          if task.state == URLSessionTask.State.running || task.state == URLSessionTask.State.suspended
          {
            taskIds.append(backgroundDownloadTask.taskId)
          }
        }
      }
      os_log("Returning %d unfinished tasks: %@", log: self.log,taskIds.count, taskIds)
      result(taskIds)
    })
  }
  
  /// Cancels ongoing tasks whose taskId is in the list provided with this call
  ///
  /// Returns true if all cancellations were successful
  private func methodCancelTasksWithIds(call: FlutterMethodCall, result: @escaping FlutterResult) {
    let taskIds = call.arguments as! [String]
    os_log("Canceling taskIds %@", log: log, taskIds)
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
        os_log("Found taskId %@", log: self.log, backgroundDownloadTask.taskId)
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
        os_log("Error for download with error %@", log: self.log, error!.localizedDescription)
        processStatusUpdate(backgroundDownloadTask: backgroundDownloadTask, status: DownloadTaskStatus.failed)
      }
    }
  }
  
  //MARK: URLSessionDownloadTask delegate methods
  
  public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
    guard let backgroundDownloadTask = self.getTaskFrom(urlSessionDownloadTask: downloadTask) else {return}
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
      os_log("Could not find task associated with native id %d, or did not get HttpResponse", log: log, downloadTask.taskIdentifier)
      return}
    if response.statusCode == 404 {
      processStatusUpdate(backgroundDownloadTask: backgroundDownloadTask, status: DownloadTaskStatus.notFound)
      return
    }
    if !(200...299).contains(response.statusCode)   {
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
        os_log("Failed to create directory %@", log: log, directory.path)
        return
      }
      let filePath = directory.appendingPathComponent(backgroundDownloadTask.filename)
      if FileManager.default.fileExists(atPath: filePath.path) {
        try? FileManager.default.removeItem(at: filePath)
      }
      do {
        try FileManager.default.moveItem(at: location, to: filePath)
      } catch {
        os_log("Failed to move file from %@ to %@: %@", log: log, location.path, filePath.path, error.localizedDescription)
        return
      }
      success = DownloadTaskStatus.complete
    } catch {
      os_log("File download error for taskId %@ and file %@: %@", log: log, backgroundDownloadTask.taskId, backgroundDownloadTask.filename, error.localizedDescription)
    }
  }

  
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
    
  /// When the app restarts, recreate the urlSession if needed, and store the completion handler
  public func application(_ application: UIApplication,
                          handleEventsForBackgroundURLSession identifier: String,
                          completionHandler: @escaping () -> Void) -> Bool {
    os_log("In handleEventsForBackgroundURLSession with identifier %@", log: log, identifier)
    if (identifier == Downloader.sessionIdentifier) {
      backgroundCompletionHandler = completionHandler
      urlSession = urlSession ?? createUrlSession()
      return true
    }
    return false
  }
  
  /// Upon completion of download of all files, call the completion handler
  public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    os_log("In urlSessionDidFinishEvents, calling completionHandler", log: log)
    DispatchQueue.main.async {
      guard
        let handler = self.backgroundCompletionHandler,
        session.configuration.identifier == Downloader.sessionIdentifier
      else {
        os_log("No handler or no identifier match", log: self.log)
        return
      }
      handler()
    }
  }
  
  
  
  /// Processes a change in status for the task
  ///
  /// Sends status update via the background channel to Flutter, if requested, and if the task is finished,
  /// processes a final status update, then removes it from permanent storage
  private func processStatusUpdate(backgroundDownloadTask: BackgroundDownloadTask, status: DownloadTaskStatus) {
    guard let channel = Downloader.backgroundChannel else {
      os_log("Could not find background channel", log: self.log)
      return
    }
    if providesStatusUpdates(downloadTask: backgroundDownloadTask) {
      let jsonString = jsonStringFor(backgroundDownloadTask: backgroundDownloadTask)
      if (jsonString != nil)
      {
        DispatchQueue.main.async {
          channel.invokeMethod("statusUpdate", arguments: [jsonString!, status.rawValue])
        }
      }
    }
    // if task is in final state then process a final progressUpdate
    if status != DownloadTaskStatus.running && status != DownloadTaskStatus.enqueued {
      switch (status) {
      case .complete:
        processProgressUpdate(backgroundDownloadTask: backgroundDownloadTask, progress: 1.0)
      case .failed:
        processProgressUpdate(backgroundDownloadTask: backgroundDownloadTask, progress: -1.0)
      case .canceled:
        processProgressUpdate(backgroundDownloadTask: backgroundDownloadTask, progress: -2.0)
      case .notFound:
        processProgressUpdate(backgroundDownloadTask: backgroundDownloadTask, progress: -3.0)
      default:
        break
      }
    }
  }
  
  /// Processes a progress update for the task
  ///
  /// Sends progress update via the background channel to Flutter, if requested, and if the task is finished, removes
  /// it from the cache
  private func processProgressUpdate(backgroundDownloadTask: BackgroundDownloadTask, progress: Double) {
    guard let channel = Downloader.backgroundChannel else {
      os_log("Could not find background channel", log: self.log)
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
    // if this is a final progress update, remove from cache
    if progress == 1.0 || progress < 0 {
      nativeToTaskMap.removeValue(forKey: backgroundDownloadTask.taskId)
      lastProgressUpdate.removeValue(forKey: backgroundDownloadTask.taskId)
      nextProgressUpdateTime.removeValue(forKey: backgroundDownloadTask.taskId)
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
    os_log("Creating URLSession", log: log)
    if urlSession != nil {
      os_log("createUrlSession called with non-null urlSession")
    }
    let config = URLSessionConfiguration.background(withIdentifier: Downloader.sessionIdentifier)
    config.timeoutIntervalForResource = Downloader.resourceTimeout
    return URLSession(configuration: config, delegate: self, delegateQueue: nil)
  }
}


