//
//  Task.swift
//  background_downloader
//
//  Created on 3/4/23.
//

import Foundation


/// Partial version of the Dart side DownloadTask, only used for background loading
struct Task : Codable, Hashable {
    var taskId: String = "\(Int.random(in: 1..<(1 << 32)))"
    var url: String
    var urls: [String]? = []
    var filename: String
    var headers: [String:String] = [:]
    var httpRequestMethod: String = "GET"
    var chunks: Int? = 1
    var post: String?
    var fileField: String?
    var mimeType: String?
    var fields: [String:String]?
    var directory: String = ""
    var baseDirectory: Int
    var group: String
    var updates: Int
    var requiresWiFi: Bool = false
    var retries: Int = 0
    var retriesRemaining: Int = 0
    var allowPause: Bool = false
    var priority: Int = 5
    var metaData: String = ""
    var displayName: String = ""
    var creationTime: Int64 = Int64((Date().timeIntervalSince1970 * 1000.0).rounded())
    var taskType: String
}

extension Task {
    func copyWith(taskId: String? = nil,
                  url: String? = nil,
                  urls: [String]? = nil,
                  filename: String? = nil,
                  headers: [String:String]? = nil,
                  httpRequestMethod: String? = nil,
                  chunks: Int? = nil,
                  post: String? = nil,
                  fileField: String? = nil,
                  mimeType: String? = nil,
                  fields: [String:String]? = nil,
                  directory: String? = nil,
                  baseDirectory: Int? = nil,
                  group: String? = nil,
                  updates: Int? = nil,
                  requiresWiFi: Bool? = nil,
                  retries: Int? = nil,
                  retriesRemaining: Int? = nil,
                  allowPause: Bool? = nil,
                  priority: Int? = nil,
                  metaData: String? = nil,
                  displayName: String? = nil,
                  creationTime: Int64? = nil,
                  taskType: String? = nil) -> Task {
        
        var copiedTask = self
        
        if let taskId = taskId {
            copiedTask.taskId = taskId
        }
        
        if let url = url {
            copiedTask.url = url
        }
        
        if let urls = urls {
            copiedTask.urls = urls
        }
        
        if let filename = filename {
            copiedTask.filename = filename
        }
        
        if let headers = headers {
            copiedTask.headers = headers
        }
        
        if let httpRequestMethod = httpRequestMethod {
            copiedTask.httpRequestMethod = httpRequestMethod
        }
        
        if let chunks = chunks {
            copiedTask.chunks = chunks
        }
        
        if let post = post {
            copiedTask.post = post
        }
        
        if let fileField = fileField {
            copiedTask.fileField = fileField
        }
        
        if let mimeType = mimeType {
            copiedTask.mimeType = mimeType
        }
        
        if let fields = fields {
            copiedTask.fields = fields
        }
        
        if let directory = directory {
            copiedTask.directory = directory
        }
        
        if let baseDirectory = baseDirectory {
            copiedTask.baseDirectory = baseDirectory
        }
        
        if let group = group {
            copiedTask.group = group
        }
        
        if let updates = updates {
            copiedTask.updates = updates
        }
        
        if let requiresWiFi = requiresWiFi {
            copiedTask.requiresWiFi = requiresWiFi
        }
        
        if let retries = retries {
            copiedTask.retries = retries
        }
        
        if let retriesRemaining = retriesRemaining {
            copiedTask.retriesRemaining = retriesRemaining
        }
        
        if let allowPause = allowPause {
            copiedTask.allowPause = allowPause
        }
        
        if let priority = priority {
            copiedTask.priority = priority
        }
        
        if let metaData = metaData {
            copiedTask.metaData = metaData
        }
        
        if let displayName = displayName {
            copiedTask.displayName = displayName
        }
        
        if let creationTime = creationTime {
            copiedTask.creationTime = creationTime
        }
        
        if let taskType = taskType {
            copiedTask.taskType = taskType
        }
        
        return copiedTask
    }
}

/// Base directory in which files will be stored, based on their relative
/// path.
///
/// These correspond to the directories provided by the path_provider package
enum BaseDirectory: Int {
    case applicationDocuments, // getApplicationDocumentsDirectory()
         temporary, // getTemporaryDirectory()
         applicationSupport, // getApplicationSupportDirectory()
         applicationLibrary, // getLibraryDirectory()
         root // system root
}

/// Type of  updates requested for a group of downloads
enum Updates: Int {
    case none,  // no status or progress updates
         statusChange, // only calls upon change in DownloadTaskStatus
         progressUpdates, // only calls for progress
         statusChangeAndProgressUpdates // calls also for progress along the way
}

/// Defines a set of possible states which a [DownloadTask] can be in.
enum TaskStatus: Int, Codable {
    case enqueued,
         running,
         complete,
         notFound,
         failed,
         canceled,
         waitingToRetry,
         paused
}

/** Holds data associated with a task status update, for local storage */
struct TaskStatusUpdate: Encodable {
    var task: Task
    var taskStatus: TaskStatus
}

/** Holds data associated with a task progress update, for local storage */
struct TaskProgressUpdate: Encodable {
    var task: Task
    var progress: Double
    var expectedFileSize: Int64
}

/** Holds data associated with a resume, for local storage */
struct ResumeData: Encodable {
    var task: Task
    var data: String
}

/// The type of [TaskException]
enum ExceptionType: String {
    case
    
    // General error
    general = "TaskException",
    
    
    // Could not save or find file, or create directory
    fileSystem = "TaskFileSystemException",
    
    // URL incorrect
    url = "TaskUrlException",
    
    // Connection problem, eg host not found, timeout
    connection = "TaskConnectionException",
    
    // Could not resume or pause task
    resume = "TaskResumeException",
    
    // Invalid HTTP response
    httpResponse = "TaskHttpException"
}

/**
 * Contains error information associated with a failed [Task]
 *
 * The [type] categorizes the error
 * The [httpResponseCode] is only valid if >0 and may offer details about the
 * nature of the error
 * The [description] is typically taken from the platform-generated
 * error message, or from the plugin. The localization is undefined
 */
struct TaskException {
    var type: ExceptionType
    var httpResponseCode: Int = -1
    var description: String
}

func taskException(jsonString: String) -> TaskException {
    if let jsonMap = try! JSONSerialization.jsonObject(with: jsonString.data(using: .utf8)!, options: []) as? [String: Any] {
        return TaskException(type: ExceptionType(rawValue: jsonMap["type"] as! String) ?? ExceptionType.general
                             , httpResponseCode: jsonMap["httpResponseCode"] as? Int ?? -1, description:  jsonMap["description"] as! String  )
    }
    return TaskException(type: .general, description: "Unknown error")
}
