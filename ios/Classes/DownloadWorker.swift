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
  
  private static var resourceTimeout = 5 * 60.0 // seconds
  public static var sessionIdentifier = "com.bbflight.file_downloader.DownloadWorker"
  private static var keyTaskMap = "com.bbflight.file_downloader.taskMap"
  private static var keyNativeMap = "com.bbflight.file_downloader.nativeMap"
  private static var keyTaskIdMap = "com.bbflight.file_downloader.taskIdMap"
  public static var flutterPluginRegistrantCallback: FlutterPluginRegistrantCallback?
  private static var backgroundChannel: FlutterMethodChannel?
  
  private final var userDefaultsLock = NSLock()
  private final var backgroundCompletionHandler: (() -> Void)?
  private final var urlSession: URLSession?
  
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
//    UserDefaults.standard.removeObject(forKey: keyNativeMap)
//    UserDefaults.standard.removeObject(forKey: keyTaskIdMap)
//    UserDefaults.standard.removeObject(forKey: keyTaskMap)
  }
  
  /// Handler for Flutter plugin method channel calls
  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "reset":
      methodReset(call: call, result: result)
    case "enqueueDownload":
      methodEnqueueDownload(call: call, result: result)
    case "allTasks":
      methodAllUnfinishedTasks(call: call, result: result)
    case "cancelTasksWithIds":
      methodCancelTasksWithIds(call: call, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
  
  /// Resets the downloadworker by cancelling all ongoing download tasks
  private func methodReset(call: FlutterMethodCall, result: @escaping FlutterResult) {
    os_log("Method reset", log: log)
    urlSession = urlSession ?? createUrlSession()
    os_log("removing all running tasks", log: log)
    urlSession?.getAllTasks(completionHandler: { tasks in
      for task in tasks {
        task.cancel()
      }
      result(nil)
    })
  }
  
  /// Starts the download worker. The argument is a JSON String representing a list of BackgroundDownloadTasks
  ///
  /// This method is called when the app switches to background. When the app switches back to foreground, the
  /// method getDownloadWorkerResult must be called to receive a list of failures and success of the background effort
  private func methodEnqueueDownload(call: FlutterMethodCall, result: @escaping FlutterResult) {
    let decoder = JSONDecoder()
    guard let backgroundDownloadTask: BackgroundDownloadTask = try? decoder.decode(BackgroundDownloadTask.self, from: (call.arguments as! String).data(using: .utf8)!)
    else {
      result(false)
      return
    }
    os_log("Received task with id %@", log: log, backgroundDownloadTask.taskId)
    urlSession = urlSession ?? createUrlSession()
    let urlSessionDownloadTask = urlSession!.downloadTask(with: URL(string: backgroundDownloadTask.url)!)
    // update the map from urlSessionDownloadTask's taskIdentifier to the BackgroundDownloadTask's taskId
    // and store that map in UserDefaults
    userDefaultsLock.lock()
    defer {
      userDefaultsLock.unlock()
    }
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
    // now start the task
    urlSessionDownloadTask.resume()
    sendStatusUpdate(task: backgroundDownloadTask, status: DownloadTaskStatus.running)
    result(true)
  }
  
  /// Returns a list with taskIds for all tasks in progress
  private func methodAllUnfinishedTasks(call: FlutterMethodCall, result: @escaping FlutterResult) {
    let taskIdMap = getTaskIdMap()
    var taskIds: [String] = []
    urlSession = urlSession ?? createUrlSession()
    urlSession?.getAllTasks(completionHandler: { tasks in
      os_log("Found %d tasks", log: self.log, tasks.count)
      for task in tasks {
        guard
          let taskId = taskIdMap[String(task.taskIdentifier)] else { continue }
        taskIds.append(taskId)
      }
      os_log("Found taskIds: %@", log: self.log, taskIds)
      result(taskIds)
    })
  }
  
  /// Cancels ongoing tasks whose taskId is in the list provided with this call
  private func methodCancelTasksWithIds(call: FlutterMethodCall, result: @escaping FlutterResult) {
    os_log("Method cancelTasksWithIds", log: log)
    guard let taskIds = call.arguments as? [String] else {
      os_log("Invalid arguments", log: log)
      return
    }
    let taskIdMap = getTaskIdMap()
    urlSession = urlSession ?? createUrlSession()
    urlSession?.getAllTasks(completionHandler: { tasks in
      for task in tasks {
        guard let taskId = taskIdMap[String(task.taskIdentifier)],
              taskIds.contains(taskId)
        else {continue}
        os_log("Canceling %@", log: self.log, taskId)
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
      os_log("Error for download with error %@", log: self.log, error!.localizedDescription)
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
      os_log("Full path=%@", log: log, directory.path)
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
  
  
  
  /// Records success or failure for this task
  ///
  /// If in foreground, calls the darCallbackFunction
  /// If in background, adds the taskId to the list in preferences, for later retrieval when returning to foreground
  private func sendStatusUpdate(task: BackgroundDownloadTask, status: DownloadTaskStatus) {
    os_log("sendStatusUpdate for taskId %@ with %d", log: self.log, task.taskId, status.rawValue)
    
    // app is in forground, so call back to Dart
    // get the handle to the dart function passed with the task
    guard let channel = DownloadWorker.backgroundChannel else {
      os_log("Could not find callback information", log: self.log)
      return
    }
    DispatchQueue.main.async {
      channel.invokeMethod("completion", arguments: [task.taskId, status.rawValue])
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


