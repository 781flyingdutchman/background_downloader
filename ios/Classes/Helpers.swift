//
//  Helpers.swift
//  background_downloader
//
//  Created by Bram on 12/31/23.
//

import Foundation
import os.log

extension URL {
    /// Uses .appending for iOS 16 and up, and .appendingPathComponent
    /// for earlier versions
    func appendingPath(_ component: String, isDirectory: Bool = false) -> URL {
        if #available(iOS 16.0, *) {
            return appending(path: component, directoryHint: isDirectory ? .isDirectory : .notDirectory)
        } else {
            return appendingPathComponent(component, isDirectory: isDirectory)
        }
    }

    /// Excludes URL from backup
    mutating func setCloudBackup(exclude: Bool) throws {
            var resource = URLResourceValues()
            resource.isExcludedFromBackup = exclude
            try self.setResourceValues(resource)
        }
}

/// Returns the task's URL if it can be parsed, otherwise null
func validateUrl(_ task: Task) -> URL? {
    let url: URL?
    // encodingInvalidCharacters is only available when compiling with Xcode 15, which uses Swift version 5.9
#if swift(>=5.9)
    if #available(iOS 17.0, *) {
        url = URL(string: task.url, encodingInvalidCharacters: false)
    } else {
        url = URL(string: task.url)
    }
#else
    url = URL(string: task.url)
#endif
    return url
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

/// Create a temp file that contains a subset of the [fileURL] based on [start] and [contentLength]
///
/// Returns the URL of the temp file, or nil if there was a problem (problem is logged)
func createTempFileWithRange(from fileURL: URL, start: UInt64, contentLength: UInt64) -> URL? {
    if contentLength > UInt64(Int.max) {
        os_log("Content length for partial upload cannot exceed %d bytes", log: log, type: .info, Int.max)
        return nil
    }
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory
    let tempFileURL = tempDir.appendingPathComponent(UUID().uuidString) // Create a unique temporary file
    
    do {
        // Open the original file for reading
        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        
        // Move to the start position
        try fileHandle.seek(toOffset: start)
        
        // Read the contentLength number of bytes
        let data = fileHandle.readData(ofLength: Int(contentLength))
        
        // Create the temporary file
        fileManager.createFile(atPath: tempFileURL.path, contents: data, attributes: nil)
        
        // Close the file handle
        fileHandle.closeFile()
        
        // Return the URL to the temp file
        return tempFileURL
    } catch {
        os_log("Error processing file: %@", log: log, type: .info, error.localizedDescription)
        return nil
    }
}
