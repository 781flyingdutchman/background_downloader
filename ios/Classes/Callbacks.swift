//
//  Callbacks.swift
//  background_downloader
//
//  Created by Bram on 10/26/24.
//

import Foundation
import os.log

import UIKit

/// Invoke the onTaskStartCallback in Dart (via teh method channel) and return the returned Task value or nil
func invokeOnTaskStartCallback(task: Task) async -> Task? {
    return await withCheckedContinuation { continuation in
        BDPlugin.callbackChannel?.invokeMethod("onTaskStartCallback", arguments: jsonStringFor(task: task), result: { result in
            guard let taskJsonString = result as? String
            else {
                if let error = result as? FlutterError {
                    os_log("Error invoking onTaskStartCallback: %@", log: log, type: .error, error.message ?? "nil")
                }  else {
                    os_log("Did not receive taskJsonString back", log: log, type: .error)
                }
                continuation.resume(returning: nil)
                return
            }
            continuation.resume(returning: taskFrom(jsonString: taskJsonString))
        })
    }
}
