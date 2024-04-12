//
//  Helpers.swift
//  background_downloader
//
//  Created by Bram on 12/31/23.
//

import Foundation

/// Uses .appending for iOS 16 and up, and .appendingPathComponent
/// for earlier versions
extension URL {
    func appendingPath(_ component: String, isDirectory: Bool = false) -> URL {
        if #available(iOS 16.0, *) {
            return appending(path: component, directoryHint: isDirectory ? .isDirectory : .notDirectory)
        } else {
            return appendingPathComponent(component, isDirectory: isDirectory)
        }
    }
}

/// Converts the [map] to a [String:String] map with lowercased keys
func lowerCasedStringStringMap(_ map: [AnyHashable: Any]?) -> [String: String]? {
    if map == nil {return nil}
    var result: [String: String] = [:]
    for (key, value) in map! {
        if let stringKey = key as? String, let stringValue = value as? String {
            result[stringKey.lowercased()] = stringValue
        }
    }
    return result
}

