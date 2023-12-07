//
//  Permissions.swift
//  background_downloader
//
//  Created by Bram on 11/30/23.
//

import Foundation
import Photos
import os.log

public enum PermissionType: Int {
    case notifications,
         androidSharedStorage,
         iosAddToPhotoLibrary,
         iosChangePhotoLibrary
}

public enum PermissionStatus: Int {
    case undetermined,
         denied,
         granted,
         partial,
         requestError }

/// Get current permission status for this [request]
///
/// Unknown permissions resturn .granted
public func getPermissionStatus(for permissionType: PermissionType) async -> PermissionStatus {
    if permissionType == .notifications {
        let center = UNUserNotificationCenter.current()
        let status = (await center.notificationSettings()).authorizationStatus
        switch status {
            case .authorized:
                return .granted
                
            case .denied:
                return .denied
                
            case .notDetermined:
                return .undetermined
                
            default:
                return .partial
        }
    }
    if (permissionType == .iosAddToPhotoLibrary || permissionType == .iosChangePhotoLibrary) {
        let addOnly = permissionType == .iosAddToPhotoLibrary
        let status: PHAuthorizationStatus
        if #available(iOS 14, *) {
            status = PHPhotoLibrary.authorizationStatus(for: addOnly ? .addOnly : .readWrite)
        } else {
            status = PHPhotoLibrary.authorizationStatus()
        }
        switch status {
            case .authorized:
                return .granted
                
            case .denied:
                return .denied
                
            case .notDetermined:
                return .undetermined
                
            default:
                return .partial
        }
    }
    return .granted
}

/// Request permission from user and return the [PermissionResult]
///
/// Unknown permissions are granted
public func requestPermission(for permissionType: PermissionType) async -> PermissionStatus {
    if permissionType == .notifications {
        let center = UNUserNotificationCenter.current()
        guard let granted = try? await center.requestAuthorization(options: [.alert]) else {
            return .requestError
        }
        return granted ? .granted : .denied
    }
    if (permissionType == .iosAddToPhotoLibrary || permissionType == .iosChangePhotoLibrary) {
        let addOnly = permissionType == .iosAddToPhotoLibrary
        let status: PHAuthorizationStatus
        if #available(iOS 14, *) {
            status = await PHPhotoLibrary.requestAuthorization(for: addOnly ? .addOnly : .readWrite)
        } else {
            status = await withCheckedContinuation { continuation in
                PHPhotoLibrary.requestAuthorization {status in
                    continuation.resume(returning: status)
                }
            }
        }
        switch status {
            case .authorized:
                return .granted
                
            case .denied:
                return .denied
                
            case .notDetermined:
                return .undetermined
                
            default:
                return .partial
        }
    }
    return .granted
    
}
