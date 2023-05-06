//
//  Task.swift
//  background_downloader
//
//  Created by Bram on 3/4/23.
//

import Foundation


/// Partial version of the Dart side DownloadTask, only used for background loading
struct Task : Codable {
    var taskId: String
    var url: String
    var filename: String
    var headers: [String:String]
    var httpRequestMethod: String
    var post: String?
    var fileField: String?
    var mimeType: String?
    var fields: [String:String]?
    var directory: String
    var baseDirectory: Int
    var group: String
    var updates: Int
    var requiresWiFi: Bool
    var retries: Int
    var retriesRemaining: Int
    var allowPause: Bool
    var metaData: String
    var creationTime: Int64
    var taskType: String
}

/// Base directory in which files will be stored, based on their relative
/// path.
///
/// These correspond to the directories provided by the path_provider package
enum BaseDirectory: Int {
    case applicationDocuments, // getApplicationDocumentsDirectory()
         temporary, // getTemporaryDirectory()
         applicationSupport, // getApplicationSupportDirectory()
         applicationLibrary // getLibraryDirectory()
}

/// Type of  updates requested for a group of downloads
enum Updates: Int {
    case none,  // no status or progress updates
         statusChange, // only calls upon change in DownloadTaskStatus
         progressUpdates, // only calls for progress
         statusChangeAndProgressUpdates // calls also for progress along the way
}

/// Defines a set of possible states which a [DownloadTask] can be in.
enum TaskStatus: Int {
    case enqueued,
         running,
         complete,
         notFound,
         failed,
         canceled,
         waitingToRetry,
         paused
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
    var httpResponseCode: Int
    var description: String
}
