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
    

public class DownloadWorker: NSObject, FlutterPlugin, FlutterApplicationLifeCycleDelegate, URLSessionDelegate, URLSessionDownloadDelegate {
  
  let log = OSLog.init(subsystem: "FileDownloaderPlugin", category: "DownloadWorker")
  
  private static var resourceTimeout = 5 * 60.0 // seconds
  public static var sessionIdentifier = "com.bbflight.file_downloader.DownloadWorker"
  private static var keySuccess = "com.bbflight.file_downloader.success"
  private static var keyFailure = "com.bbflight.file_downloader.failure"
  private static var keyTaskIdMap = "com.bbflight.file_downloader.taskIdMap"
  public static var flutterPluginRegistrantCallback: FlutterPluginRegistrantCallback?
  private static var backgroundChannel: FlutterMethodChannel?
  
  private final var userDefaultsLock = NSLock()
  private final var backgroundCompletionHandler: (() -> Void)?
  private final var urlSession: URLSession?

  private var appIsInBackground = false
  
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
    switch call.method {
    case "reset":
      methodReset(call: call, result: result)
    case "enqueueDownload":
      methodEnqueueDownload(call: call, result: result)
    case "movingToBackground":
      methodMovingToBackground(call: call, result: result)
    case "movingToForeground":
      methodMovingToForeground(call: call, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
  
  /// Resets the downloadworker by cancelling all ongoing download tasks
  private func methodReset(call: FlutterMethodCall, result: @escaping FlutterResult) {
    os_log("Method reset", log: log)
    appIsInBackground = false
    urlSession = urlSession ?? createUrlSession()
    os_log("Invalidating urlSession", log: log)
    urlSession?.invalidateAndCancel()
    urlSession = nil;
    result(nil)
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
    var taskIdMap = getTaskIdMap()
    let encoder = JSONEncoder()
    let jsonString = String(data: try! encoder.encode(backgroundDownloadTask), encoding: .utf8)
    taskIdMap[String(urlSessionDownloadTask.taskIdentifier)] = jsonString
    UserDefaults.standard.set(taskIdMap, forKey: DownloadWorker.keyTaskIdMap)
    // now start the task
    urlSessionDownloadTask.resume()
    result(true)
  }
  
  /// Signals to the plugin that the main app is moving to background, and does not want to receive status updates
  ///
  /// From here on, completed tasks (success or failure) are recorded in UserDefaults and can be retrieved by the main
  /// app on resume, using the movingToForeground method call.  For reference, this method returns
  /// a list of successes and failures kept by the plugin (though they should have been collected through movingToForeground)
  private func methodMovingToBackground(call: FlutterMethodCall, result: @escaping FlutterResult) {
    appIsInBackground = true
    let success = UserDefaults.standard.object(forKey: DownloadWorker.keySuccess) as? [String] ?? []
    let failure = UserDefaults.standard.object(forKey: DownloadWorker.keyFailure) as? [String] ?? []
    // Clear list of successes and failures
    UserDefaults.standard.removeObject(forKey: DownloadWorker.keySuccess)
    UserDefaults.standard.removeObject(forKey: DownloadWorker.keyFailure)
    result(["success": success, "failure": failure])
  }
  
  /// Signals to the plugin that the main app is moving to the foreground, and wants to receive status updates again
  ///
  /// The return value is a map/dictionary with 'success' and 'failure', each containing the taskIds of the respective tasks
  private func methodMovingToForeground(call: FlutterMethodCall, result: @escaping FlutterResult) {
    appIsInBackground = false
    let success = UserDefaults.standard.object(forKey: DownloadWorker.keySuccess) as? [String] ?? []
    let failure = UserDefaults.standard.object(forKey: DownloadWorker.keyFailure) as? [String] ?? []
    // Clear list of successes and failures
    UserDefaults.standard.removeObject(forKey: DownloadWorker.keySuccess)
    UserDefaults.standard.removeObject(forKey: DownloadWorker.keyFailure)
    result(["success": success, "failure": failure])
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
      let taskIdMap = getTaskIdMap()
      guard let backgroundDownloadTaskJsonString = taskIdMap[String(task.taskIdentifier)] else {
        os_log("Could not map urlSessionDownloadTask identifier %d to a taskId", log: log, task.taskIdentifier)
        return
      }
      guard let backgroundDownloadTask = backgroundDownloadTaskFromJsonString(jsonString: backgroundDownloadTaskJsonString) else {return}
      recordSuccessOrFailure(task: backgroundDownloadTask, success: false)
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
    let taskIdMap = getTaskIdMap()
    guard let backgroundDownloadTaskJsonString = taskIdMap[String(downloadTask.taskIdentifier)] else {
      os_log("Could not map urlSessionDownloadTask identifier %d to a taskId", log: log, downloadTask.taskIdentifier)
      return
    }
    guard let backgroundDownloadTask = backgroundDownloadTaskFromJsonString(jsonString: backgroundDownloadTaskJsonString) else {return}
    guard
      let response = downloadTask.response as? HTTPURLResponse,
      (200...299).contains(response.statusCode)  else {
      recordSuccessOrFailure(task: backgroundDownloadTask, success: false)
      return
    }
    do {
      var success = false
      defer {
        recordSuccessOrFailure(task: backgroundDownloadTask, success: success)
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
      success = true
    } catch {
      os_log("File download error for taskId %@ and file %@: %@", log: log, backgroundDownloadTask.taskId, backgroundDownloadTask.filename, error.localizedDescription)
    }
  }
  
  /// Get the taskId map from UserDefaults. The values are still in JSON String format. Must surround with locks
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
  private func recordSuccessOrFailure(task: BackgroundDownloadTask, success: Bool) {
    os_log("recordSuccessOrFailure for taskId %@", log: self.log, task.taskId)
    if (appIsInBackground) {
      os_log("App is in background", log: self.log)
      userDefaultsLock.lock()  // Only one thread can access prefs at the same time
      defer {
        userDefaultsLock.unlock()
      }
      let prefsKey = (success ? DownloadWorker.keySuccess : DownloadWorker.keyFailure)
      var existing = UserDefaults.standard.object(forKey: prefsKey) as? [String] ?? []
      existing.append(task.taskId)
      UserDefaults.standard.set(existing, forKey: prefsKey)
      if (!success) {
        os_log(
          "Failed background download for taskId %@ from %@ to %@", log: self.log, task.taskId, task.url, task.filename
        )
      } else {
        os_log(
          "Successful background download for taskId %@ from %@ to %@", log: self.log, task.taskId, task.url, task.filename
        )
      }
    } else {
      os_log("App is in foreground", log: self.log)
      // app is in forground, so call back to Dart
      // get the handle to the dart function passed with the task
      guard let channel = DownloadWorker.backgroundChannel else {
        os_log("Could not find callback information", log: self.log)
        return
      }
      DispatchQueue.main.async {
        channel.invokeMethod("completion", arguments: [task.taskId, success])
      }
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


