//
//  Callbacks.swift
//  background_downloader
//
//  Created by Bram on 10/26/24.
//

import Foundation
import Flutter
import os.log

import UIKit


/// Invoke a callback in Dart (via the method channel) and return the returned Task value or nil
private func invokeCallback(withMethod methodName: String, forTask task: Task) async -> Any? {
    return await withCheckedContinuation { continuation in
        os_log("Invoking %{public}@ for taskId %@", log: log, type: .info, methodName, task.taskId)
        BDPlugin.callbackChannel?.invokeMethod(methodName, arguments: jsonStringFor(task: task), result: { result in
            guard let jsonString = result as? String else {
                if let error = result as? FlutterError {
                    os_log("Error invoking %{public}@: %@", log: log, type: .error, methodName, error.message ?? "nil")
                }
                continuation.resume(returning: nil)
                return
            }
            if methodName == "beforeTaskStartCallback" {
                continuation.resume(returning: try? JSONDecoder().decode(TaskStatusUpdate.self, from: (jsonString).data(using: .utf8)!))
            }
            else {
                continuation.resume(returning: taskFrom(jsonString: jsonString))
            }
        })
    }
}

/// Invoke the onTaskStartCallback in Dart (via the method channel) and return the returned Task value or nil
func invokeBeforeTaskStartCallback(task: Task) async -> TaskStatusUpdate? {
    return await invokeCallback(withMethod: "beforeTaskStartCallback", forTask: task) as? TaskStatusUpdate
}

/// Invoke the onTaskStartCallback in Dart (via the method channel) and return the returned Task value or nil
func invokeOnTaskStartCallback(task: Task) async -> Task? {
    return await invokeCallback(withMethod: "onTaskStartCallback", forTask: task) as? Task
}

/// Invoke the onAuthCallback in Dart (via the method channel) and return the returned Task value or nil
func invokeOnAuthCallback(task: Task) async -> Task? {
    return await invokeCallback(withMethod: "onAuthCallback", forTask: task) as? Task
}

/// Invoke the onTaskFinishedCallback in Dart (via the method channel) and return true if successful
func invokeOnTaskFinishedCallback(taskStatusUpdate: TaskStatusUpdate) async -> Bool {
    return await withCheckedContinuation { continuation in
        BDPlugin.callbackChannel?.invokeMethod("onTaskFinishedCallback", arguments: jsonStringFor(taskStatusUpdate: taskStatusUpdate), result: { result in
            if let error = result as? FlutterError {
                os_log("Error invoking onTaskFinishedCallback: %@", log: log, type: .error, error.message ?? "nil")
                continuation.resume(returning: false)
            }  else {
                continuation.resume(returning: true)
            }
        })
    }
}
