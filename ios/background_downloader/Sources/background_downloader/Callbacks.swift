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
private func invokeCallback(withMethod methodName: String, forTask task: Task) async -> Task? {
    return await withCheckedContinuation { continuation in
        BDPlugin.callbackChannel?.invokeMethod(methodName, arguments: jsonStringFor(task: task), result: { result in
            guard let taskJsonString = result as? String else {
                if let error = result as? FlutterError {
                    os_log("Error invoking %{public}@: %@", log: log, type: .error, methodName, error.message ?? "nil")
                }
                continuation.resume(returning: nil)
                return
            }
            continuation.resume(returning: taskFrom(jsonString: taskJsonString))
        })
    }
}

/// Invoke the onTaskStartCallback in Dart (via the method channel) and return the returned Task value or nil
func invokeOnTaskStartCallback(task: Task) async -> Task? {
    return await invokeCallback(withMethod: "onTaskStartCallback", forTask: task)
}

/// Invoke the onAuthCallback in Dart (via the method channel) and return the returned Task value or nil
func invokeOnAuthCallback(task: Task) async -> Task? {
    return await invokeCallback(withMethod: "onAuthCallback", forTask: task)
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
