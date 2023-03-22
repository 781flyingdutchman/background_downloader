//
//  Notifications.swift
//  background_downloader
//
//  Created on 3/19/23.
//

import Foundation
import os.log


/// NotificationContents
struct NotificationContents : Codable {
    let title: String
    let body: String
    
    init(json: [String:Any]) {
        title = json["title"] as! String
        body = json["body"] as! String
    }
}

struct NotificationConfig : Decodable {
    let running: NotificationContents?
    let complete: NotificationContents?
    let error: NotificationContents?
    let paused: NotificationContents?
    let progressBar: Bool
}

enum NotificationType : Int {
    case running,
        complete,
        error,
        paused
}

func updateNotification(task: Task, notificationType: NotificationType, notificationConfig: NotificationConfig?) {
    guard Downloader.haveNotificationPermission == true else { return }
    os_log("Have permission", log: log, type: .info)
    var notification: NotificationContents?
    switch notificationType {
    case .running:
        notification = notificationConfig?.running
    case .complete:
        notification = notificationConfig?.complete
    case .error:
        notification = notificationConfig?.error
    case .paused:
        notification = notificationConfig?.paused
    }
    if notification == nil {
        return
    }
    let content = UNMutableNotificationContent()
    content.title = replaceTokens(input: notification!.title, task: task)
    content.body = replaceTokens(input: notification!.body, task: task)
    let request = UNNotificationRequest(identifier: task.taskId,
                content: content, trigger: nil)
    let notificationCenter = UNUserNotificationCenter.current()
    notificationCenter.add(request) { (error) in
       if error != nil {
           os_log("Notification error %@", log: log, type: .info, error!.localizedDescription)
       }
    }
}

/// Returns the notificationType related to this [status]
func notificationTypeForTaskStatus(status: TaskStatus) -> NotificationType {
    switch status {
    case .enqueued, .running: return NotificationType.running
    case .complete: return NotificationType.complete
    case .paused: return NotificationType.paused
    default: return NotificationType.error
    }
}

let fileNameRegEx = try! NSRegularExpression(pattern: "\\{filename\\}", options: NSRegularExpression.Options.caseInsensitive)
let progressRegEx = try! NSRegularExpression(pattern: "\\{progress\\}", options: NSRegularExpression.Options.caseInsensitive)
let metaDataRegEx = try! NSRegularExpression(pattern: "\\{metadata\\}", options: NSRegularExpression.Options.caseInsensitive)

/// Replace special tokens {filename} and {metadata} with their respective values
func replaceTokens(input: String, task: Task) -> String {
    var inputString = NSMutableString()
    inputString.append(input)
    metaDataRegEx.replaceMatches(in: inputString, range: NSMakeRange(0, inputString.length), withTemplate: task.metaData)
    fileNameRegEx.replaceMatches(in: inputString, range: NSMakeRange(0, inputString.length), withTemplate: task.filename)
    progressRegEx.replaceMatches(in: inputString, range: NSMakeRange(0, inputString.length), withTemplate: "")
    return inputString as String
}

