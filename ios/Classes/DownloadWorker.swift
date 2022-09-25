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
func providesStatusUpdates(task: BackgroundDownloadTask) -> Bool {
  return task.progressUpdates == DownloadTaskProgressUpdates.statusChange.rawValue || task.progressUpdates == DownloadTaskProgressUpdates.statusChangeAndProgressUpdates.rawValue
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


    

public class DownloadWorker: NSObject, FlutterPlugin, FlutterApplicationLifeCycleDelegate, URLSessionDelegate, URLSessionDownloadDelegate {
  
  let log = OSLog.init(subsystem: "FileDownloaderPlugin", category: "DownloadWorker")
  
  private static var resourceTimeout = 60 * 60.0 // seconds
  public static var sessionIdentifier = "com.bbflight.file_downloader.DownloadWorker"
  private static var keyTaskMap = "com.bbflight.file_downloader.taskMap"
  private static var keyNativeMap = "com.bbflight.file_downloader.nativeMap"
  private static var keyTaskIdMap = "com.bbflight.file_downloader.taskIdMap"
  public static var flutterPluginRegistrantCallback: FlutterPluginRegistrantCallback?
  private static var backgroundChannel: FlutterMethodChannel?
  
  private final var userDefaultsLock = NSLock()
  private final var backgroundCompletionHandler: (() -> Void)?
  private final var urlSession: URLSession?
  private var statusUpdates  = [String: Bool]()
  private var progressUpdates  = [String: Bool]()
  
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "com.bbflight.file_downloader", binaryMessenger: registrar.messenger())
    backgroundChannel = FlutterMethodChannel(name: "com.bbflight.file_downloader.background", binaryMessenger: registrar.messenger())
    let instance = DownloadWorker()
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
    case "allTasks":
      methodAllTasks(call: call, result: result)
    case "cancelTasksWithIds":
      methodCancelTasksWithIds(call: call, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
  

  
  /// Starts the download for one task, passed as map of values representing a BackgroundDownloadTasks
  ///
  /// Returns true if successful, but will emit a status update that the background task is running
  private func methodEnqueue(call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as! [Any]
    let downloadTaskJsonMapString = args[0] as! String
    os_log("methodEnqueue with %@", log: log, downloadTaskJsonMapString)
    guard let backgroundDownloadTask = backgroundDownloadTaskFromJsonString(jsonString: downloadTaskJsonMapString)
    else {
      os_log("Could not decode %@ to downloadTask", log: log, downloadTaskJsonMapString)
      result(false)
      return
    }
    os_log("Starting task with id %@", log: log, backgroundDownloadTask.taskId)
    urlSession = urlSession ?? createUrlSession()
    let urlSessionDownloadTask = urlSession!.downloadTask(with: URL(string: backgroundDownloadTask.url)!)
    // update the map from urlSessionDownloadTask's taskIdentifier to the BackgroundDownloadTask's taskId
    // and store that map in UserDefaults
    userDefaultsLock.lock()
    defer {
      userDefaultsLock.unlock()
    }
    // store maps for taskId -> task, nativeId -> TaskId, taskId -> NativeId
    var taskMap = getTaskMap()
    let encoder = JSONEncoder()
    let jsonString = String(data: try! encoder.encode(backgroundDownloadTask), encoding: .utf8)
    taskMap[String(urlSessionDownloadTask.taskIdentifier)] = jsonString
    var nativeMap = getNativeMap()
    nativeMap[backgroundDownloadTask.taskId] = urlSessionDownloadTask.taskIdentifier
    var taskIdMap = getTaskIdMap()
    taskIdMap[String(urlSessionDownloadTask.taskIdentifier)] = backgroundDownloadTask.taskId
    UserDefaults.standard.set(taskMap, forKey: DownloadWorker.keyTaskMap)
    UserDefaults.standard.set(nativeMap, forKey: DownloadWorker.keyNativeMap)
    UserDefaults.standard.set(taskIdMap, forKey: DownloadWorker.keyTaskIdMap)
    // store locally whether task needs status and/or progress udpates
    statusUpdates[String(urlSessionDownloadTask.taskIdentifier)] = providesStatusUpdates(task: backgroundDownloadTask)
    progressUpdates[String(urlSessionDownloadTask.taskIdentifier)] = providesProgressUpdates(task: backgroundDownloadTask)
    
    // now start the task
    urlSessionDownloadTask.resume()
    sendStatusUpdate(task: backgroundDownloadTask, status: DownloadTaskStatus.running)
    result(true)
  }
  
  /// Resets the downloadworker by cancelling all ongoing download tasks
  ///
  /// Returns the number of tasks canceled
  private func methodReset(call: FlutterMethodCall, result: @escaping FlutterResult) {
    urlSession = urlSession ?? createUrlSession()
    urlSession?.getAllTasks(completionHandler: { tasks in
      for task in tasks {
        task.cancel()
      }
      os_log("methodReset removed %d unfinished tasks", log: self.log, tasks.count)
      if tasks.count == 0 {
        // remove all persistent storage if reset did not remove any outstanding tasks
        UserDefaults.standard.removeObject(forKey: DownloadWorker.keyTaskMap)
        UserDefaults.standard.removeObject(forKey: DownloadWorker.keyNativeMap)
        UserDefaults.standard.removeObject(forKey: DownloadWorker.keyTaskIdMap)
      }
      result(tasks.count)
    })
  }
  
  /// Returns a list with taskIds for all tasks in progress
  private func methodAllTasks(call: FlutterMethodCall, result: @escaping FlutterResult) {
    let taskIdMap = getTaskIdMap()
    var taskIds: [String] = []
    urlSession = urlSession ?? createUrlSession()
    urlSession?.getAllTasks(completionHandler: { tasks in
      os_log("Found %d tasks", log: self.log, tasks.count)
      for task in tasks {
        guard
          let taskId = taskIdMap[String(task.taskIdentifier)] else { continue }
        if task.state == URLSessionTask.State.running || task.state == URLSessionTask.State.suspended
        {
          taskIds.append(taskId)
        }
      }
      os_log("Returning %d unfinished tasks: %@", log: self.log,taskIds.count, taskIds)
      result(taskIds)
    })
  }
  
  /// Cancels ongoing tasks whose taskId is in the list provided with this call
  private func methodCancelTasksWithIds(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let taskIds = call.arguments as? [String] else {
      os_log("Invalid arguments", log: log)
      return
    }
    os_log("Canceling taskIds %@", log: log, taskIds)
    let taskIdMap = getTaskIdMap()
    urlSession = urlSession ?? createUrlSession()
    urlSession?.getAllTasks(completionHandler: { tasks in
      for task in tasks {
        guard let taskId = taskIdMap[String(task.taskIdentifier)],
              taskIds.contains(taskId)
        else {continue}
        task.cancel()
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
      // map the urlSessionDownloadTask taskidentifier to the original BackgroudnDownloadTask's taskId
      let taskIdMap = getTaskMap()
      guard let backgroundDownloadTaskJsonString = taskIdMap[String(task.taskIdentifier)] else {
        os_log("Could not map urlSessionDownloadTask identifier %d to a taskId", log: log, task.taskIdentifier)
        return
      }
      guard let backgroundDownloadTask = backgroundDownloadTaskFromJsonString(jsonString: backgroundDownloadTaskJsonString) else {return}
      if error!.localizedDescription.contains("cancelled") {
        sendStatusUpdate(task: backgroundDownloadTask, status: DownloadTaskStatus.canceled)
      }
      else {
        os_log("Error for download with error %@", log: self.log, error!.localizedDescription)
        sendStatusUpdate(task: backgroundDownloadTask, status: DownloadTaskStatus.failed)
      }
    }
  }

  
  /// Process end of downloadTask sent by the urlSession.
  ///
  /// If successful, (over)write file to final destination per BackgroundDownloadTask info
  public func urlSession(_ session: URLSession,
                         downloadTask: URLSessionDownloadTask,
                         didFinishDownloadingTo location: URL) {
    // os_log("Did finish download %@", log: self.log, downloadTask.taskIdentifier)
    // map the urlSessionDownloadTask taskidentifier to the original BackgroudnDownloadTask's taskId
    let taskIdMap = getTaskMap()
    guard let backgroundDownloadTaskJsonString = taskIdMap[String(downloadTask.taskIdentifier)] else {
      os_log("Could not map urlSessionDownloadTask identifier %d to a taskId", log: log, downloadTask.taskIdentifier)
      return
    }
    guard let backgroundDownloadTask = backgroundDownloadTaskFromJsonString(jsonString: backgroundDownloadTaskJsonString),
          let response = downloadTask.response as? HTTPURLResponse
    else {return}
    if response.statusCode == 404 {
      sendStatusUpdate(task: backgroundDownloadTask, status: DownloadTaskStatus.notFound)
      return
    }
    if !(200...299).contains(response.statusCode)   {
      sendStatusUpdate(task: backgroundDownloadTask, status: DownloadTaskStatus.failed)
      return
    }
    do {
      var success = DownloadTaskStatus.failed
      defer {
        sendStatusUpdate(task: backgroundDownloadTask, status: success)
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
  
  /// Get the task map from UserDefaults. Maps from the native id to a JSON String representing the DownloadTask.
  private func getTaskMap() -> [String:String] {
    return (UserDefaults.standard.object(forKey: DownloadWorker.keyTaskMap) ?? [:]) as! [String:String]
  }
  
  /// Get the native map from UserDefaults. Maps from taskId to native id
  private func getNativeMap() -> [String:Int] {
    return (UserDefaults.standard.object(forKey: DownloadWorker.keyNativeMap) ?? [:]) as! [String:Int]
  }
  
  /// Get the taskId map from TaskMap. Maps from the native id to the taskId of the DownloadTask.
  private func getTaskIdMap() -> [String:String] {
    return (UserDefaults.standard.object(forKey: DownloadWorker.keyTaskIdMap) ?? [:]) as! [String:String]
  }
  
  /// Returns a BackgroundDownloadTask from the supplied jsonString, or nil
  private func backgroundDownloadTaskFromJsonString(jsonString: String) -> BackgroundDownloadTask? {
    let decoder = JSONDecoder()
    let backgroundDownloadTasks: BackgroundDownloadTask? = try? decoder.decode(BackgroundDownloadTask.self, from: (jsonString).data(using: .utf8)!)
    return backgroundDownloadTasks
  }
  
  /// Returns a JSON string for this BackgroundDownloadTask
  private func jsonStringForBackgroundDownloadTask(task: BackgroundDownloadTask) -> String? {
    let jsonEncoder = JSONEncoder()
    guard let jsonResultData = try? jsonEncoder.encode(task)
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
    if (identifier == DownloadWorker.sessionIdentifier) {
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
        session.configuration.identifier == DownloadWorker.sessionIdentifier
      else {
        os_log("No handler or no identifier match", log: self.log)
        return
      }
      handler()
    }
  }
  
  
  
  /// Sends status update via the backgroudn channel to Flutter
  private func sendStatusUpdate(task: BackgroundDownloadTask, status: DownloadTaskStatus) {
    os_log("Sending status update", log: self.log)
    guard let channel = DownloadWorker.backgroundChannel else {
      os_log("Could not find background channel", log: self.log)
      return
    }
    if providesStatusUpdates(task: task) {
      let jsonString = jsonStringForBackgroundDownloadTask(task: task)
      if (jsonString != nil)
      {
        os_log("update %@ status %d", log: self.log, jsonString!, status.rawValue)
        DispatchQueue.main.async {
          channel.invokeMethod("statusUpdate", arguments: [jsonString!, status.rawValue])
        }
      }
    }
    // remove the task from the UserDefault maps and cached maps
    if status != DownloadTaskStatus.running && status != DownloadTaskStatus.enqueued {
      var taskIdMap = getTaskIdMap()
      var nativeMap = getNativeMap()
      let nativeId = nativeMap[task.taskId] ?? 0
      taskIdMap.removeValue(forKey: String(nativeId))
      nativeMap.removeValue(forKey: task.taskId)
      var taskMap = getTaskMap()
      taskMap.removeValue(forKey: String(nativeId))
      UserDefaults.standard.set(taskMap, forKey: DownloadWorker.keyTaskMap)
      UserDefaults.standard.set(nativeMap, forKey: DownloadWorker.keyNativeMap)
      UserDefaults.standard.set(taskIdMap, forKey: DownloadWorker.keyTaskIdMap)
      statusUpdates.removeValue(forKey: String(nativeId))
      progressUpdates.removeValue(forKey: String(nativeId))
    }
  }
  
  /// Creates a urlSession
  private func createUrlSession() -> URLSession {
    os_log("Recreating URLSession", log: log)
    if urlSession != nil {
      os_log("createUrlSession called with non-null urlSession")
    }
    let config = URLSessionConfiguration.background(withIdentifier: DownloadWorker.sessionIdentifier)
    config.timeoutIntervalForResource = DownloadWorker.resourceTimeout
    return URLSession(configuration: config, delegate: self, delegateQueue: nil)
  }
}


