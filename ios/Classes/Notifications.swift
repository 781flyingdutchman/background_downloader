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
        title = json["title"] as? String ?? ""
        body = json["body"] as? String ?? ""
    }
}

struct NotificationConfig : Codable {
    let running: NotificationContents?
    let complete: NotificationContents?
    let error: NotificationContents?
    let paused: NotificationContents?
    let progressBar: Bool
    let tapOpensFile: Bool
}

enum NotificationType : Int {
    case running,
         complete,
         error,
         paused
}

enum NotificationCategory : String, CaseIterable {
    case runningWithPause = "running_with_pause";
    case runningWithoutPause = "running_without_pause";
    case paused = "paused"
    case complete = "complete"
    case error = "error"
}

/// List of all category identifiers
let ourCategories = NotificationCategory.allCases.map { $0.rawValue }

func updateNotification(task: Task, notificationType: NotificationType, notificationConfig: NotificationConfig?) {
    let center = UNUserNotificationCenter.current()
    center.getNotificationSettings { settings in
        guard (settings.authorizationStatus == .authorized) else { return }
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
        content.userInfo = [
            "task": jsonStringFor(task: task) ?? "",
            "notificationConfig": jsonStringFor(notificationConfig: notificationConfig!) ?? "",
            "notificationType": notificationType.rawValue
        ]
        addNotificationActions(task: task, notificationType: notificationType, content: content, notificationConfig: notificationConfig!)
        let request = UNNotificationRequest(identifier: task.taskId,
                                            content: content, trigger: nil)
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.add(request) { (error) in
            if error != nil {
                os_log("Notification error %@", log: log, type: .info, error!.localizedDescription)
            }
        }
    }
}

/// Add action buttons to the notification
///
/// Which button(s) depends on the [notificationType]. Action buttons are defined when defining the notification categories
func addNotificationActions(task: Task, notificationType: NotificationType, content: UNMutableNotificationContent, notificationConfig: NotificationConfig) {
    switch notificationType {
    case .running:
        content.categoryIdentifier = Downloader.taskIdsThatCanResume.contains(task.taskId) && notificationConfig.paused != nil ? NotificationCategory.runningWithPause.rawValue : NotificationCategory.runningWithoutPause.rawValue
    case .paused:
        content.categoryIdentifier = NotificationCategory.paused.rawValue
    case .complete:
        content.categoryIdentifier = NotificationCategory.complete.rawValue
    case .error:
        content.categoryIdentifier = NotificationCategory.error.rawValue
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

/// Registers notification categories and actions for the different notification types
func registerNotificationCategories() {
    // define the actions
    let cancelAction = UNNotificationAction(identifier: "cancel_action",
                                            title: "Cancel",
                                            options: [])
    let cancelInactiveAction = UNNotificationAction(identifier: "cancel_inactive_action",
                                                    title: "Cancel",
                                                    options: [])
    let pauseAction = UNNotificationAction(identifier: "pause_action",
                                           title: "Pause",
                                           options: [])
    let resumeAction = UNNotificationAction(identifier: "resume_action",
                                            title: "Resume",
                                            options: [])
    // Define the notification categories using these actions
    let runningWithPauseCategory =
    UNNotificationCategory(identifier: NotificationCategory.runningWithPause.rawValue,
                           actions: [cancelAction, pauseAction],
                           intentIdentifiers: [],
                           hiddenPreviewsBodyPlaceholder: "",
                           options: .customDismissAction)
    let runningWithoutPauseCategory =
    UNNotificationCategory(identifier: NotificationCategory.runningWithoutPause.rawValue,
                           actions: [cancelAction],
                           intentIdentifiers: [],
                           hiddenPreviewsBodyPlaceholder: "",
                           options: .customDismissAction)
    let pausedCategory =
    UNNotificationCategory(identifier: NotificationCategory.paused.rawValue,
                           actions: [cancelInactiveAction, resumeAction],
                           intentIdentifiers: [],
                           hiddenPreviewsBodyPlaceholder: "",
                           options: .customDismissAction)
    let completeCategory =
    UNNotificationCategory(identifier: NotificationCategory.complete.rawValue,
                           actions: [],
                           intentIdentifiers: [],
                           hiddenPreviewsBodyPlaceholder: "",
                           options: .customDismissAction)
    let errorCategory =
    UNNotificationCategory(identifier: NotificationCategory.error.rawValue,
                           actions: [],
                           intentIdentifiers: [],
                           hiddenPreviewsBodyPlaceholder: "",
                           options: .customDismissAction)
    // Register the notification type.
    let notificationCenter = UNUserNotificationCenter.current()
    notificationCenter.setNotificationCategories([runningWithPauseCategory, runningWithoutPauseCategory, pausedCategory, completeCategory, errorCategory])
}

/// Returns a JSON string for this NotificationConfig, or nil
func jsonStringFor(notificationConfig: NotificationConfig) -> String? {
    let jsonEncoder = JSONEncoder()
    guard let jsonResultData = try? jsonEncoder.encode(notificationConfig)
    else {
        return nil
    }
    return String(data: jsonResultData, encoding: .utf8)
    
}

/// Returns a NotificationConfig from the supplied jsonString, or nil
func notificationConfigFrom(jsonString: String) -> NotificationConfig? {
    let decoder = JSONDecoder()
    let notificationConfig: NotificationConfig? = try? decoder.decode(NotificationConfig.self, from: (jsonString).data(using: .utf8)!)
    return notificationConfig
}

